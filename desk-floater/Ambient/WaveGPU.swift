import AppKit
import MetalKit

public struct AmbientConfiguration: Equatable {
    public let damping: Float
    public let dotSize: Float
    public let dotSpacing: Float

    public init(damping: Float, dotSize: Float, dotSpacing: Float) {
        self.damping = damping.isFinite ? min(2, max(0.01, damping)) : 1
        self.dotSize = dotSize.isFinite ? min(4, max(0.4, dotSize)) : 1
        self.dotSpacing = dotSpacing.isFinite ? min(10, max(1, dotSpacing)) : 3
    }
}

@MainActor
public protocol AmbientSurface: AnyObject {
    func configure(_ configuration: AmbientConfiguration)
    func start()
    func stop()
    func impulse(at point: CGPoint, strength: Float)
    func pointer(at point: CGPoint, velocity: CGVector)
}

@MainActor
public func makeAmbientSurface(configuration: AmbientConfiguration) -> (NSView & AmbientSurface)? {
    guard let device = MTLCreateSystemDefaultDevice() else { return nil }
    do { return try WavePoolView(device: device, configuration: configuration) }
    catch { NSLog("Optional ambient background unavailable: %@", String(describing: error)); return nil }
}

struct PoolParameters {
    var grid: SIMD2<UInt32>
    var size: SIMD2<Float>
    var visibleSize: SIMD2<Float>
    var renderGrid: SIMD2<UInt32>
    var dt: Float = 1 / 60
    var damping: Float
    var count: UInt32 = 0
    var dark: Float
    var dotSize: Float
    var dotSpacing: Float

    init(visibleSize: SIMD2<Float>, configuration: AmbientConfiguration, domainScale: Float = 2.5,
         grid: SIMD2<UInt32> = SIMD2(80, 70), dark: Float = 1) {
        self.grid = grid
        self.visibleSize = SIMD2(max(visibleSize.x, 32), max(visibleSize.y, 28))
        size = self.visibleSize * domainScale
        renderGrid = SIMD2(UInt32(ceil(self.visibleSize.x / configuration.dotSpacing)),
                           UInt32(ceil(self.visibleSize.y / configuration.dotSpacing)))
        damping = configuration.damping; dotSize = configuration.dotSize; dotSpacing = configuration.dotSpacing; self.dark = dark
    }
}

struct PoolImpulse {
    var center: SIMD2<Float>
    var radius: Float
    var strength: Float
}

/// Both integration and shading stay on the GPU; the CPU only queues inputs and commands.
@MainActor
final class WaveGPU {
    let device: MTLDevice
    let queue: MTLCommandQueue
    let stepPipeline: MTLComputePipelineState
    let levelPipeline: MTLComputePipelineState
    let totalsPipeline: MTLComputePipelineState
    let renderPipeline: MTLRenderPipelineState
    var current: MTLBuffer
    var other: MTLBuffer
    let energy: MTLBuffer
    let mean: MTLBuffer
    var gpuSeconds: TimeInterval = 0
    var frames = 0
    static let count = 80 * 70

    init(device: MTLDevice) throws {
        self.device = device
        guard let queue = device.makeCommandQueue(),
              let a = device.makeBuffer(length: Self.count * MemoryLayout<SIMD2<Float>>.stride, options: .storageModeShared),
              let b = device.makeBuffer(length: a.length, options: .storageModeShared),
              let energy = device.makeBuffer(length: MemoryLayout<Float>.size, options: .storageModeShared),
              let mean = device.makeBuffer(length: MemoryLayout<SIMD2<Float>>.stride, options: .storageModeShared)
        else { throw NSError(domain: "FloaterAmbient", code: 1) }
        self.queue = queue; current = a; other = b; self.energy = energy; self.mean = mean
        memset(a.contents(), 0, a.length); memset(b.contents(), 0, b.length)
        energy.contents().storeBytes(of: Float(0), as: Float.self)
        let library = try device.makeLibrary(source: WaveShaders.source, options: nil)
        guard let step = library.makeFunction(name: "waveStep"), let level = library.makeFunction(name: "levelPool"),
              let totals = library.makeFunction(name: "poolTotals"),
              let vertex = library.makeFunction(name: "lattice"), let fragment = library.makeFunction(name: "droplet")
        else { throw NSError(domain: "FloaterAmbient", code: 2) }
        stepPipeline = try device.makeComputePipelineState(function: step)
        levelPipeline = try device.makeComputePipelineState(function: level)
        totalsPipeline = try device.makeComputePipelineState(function: totals)
        guard totalsPipeline.maxTotalThreadsPerThreadgroup >= 256 else { throw NSError(domain: "FloaterAmbient", code: 3) }
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = vertex; descriptor.fragmentFunction = fragment
        let color = descriptor.colorAttachments[0]!
        color.pixelFormat = .bgra8Unorm
        color.isBlendingEnabled = true
        color.sourceRGBBlendFactor = .sourceAlpha; color.destinationRGBBlendFactor = .oneMinusSourceAlpha
        color.sourceAlphaBlendFactor = .one; color.destinationAlphaBlendFactor = .oneMinusSourceAlpha
        renderPipeline = try device.makeRenderPipelineState(descriptor: descriptor)
    }

    func clear() {
        guard let command = queue.makeCommandBuffer(), let blit = command.makeBlitCommandEncoder() else { return }
        blit.fill(buffer: current, range: 0..<current.length, value: 0)
        blit.fill(buffer: other, range: 0..<other.length, value: 0)
        blit.fill(buffer: energy, range: 0..<energy.length, value: 0)
        blit.fill(buffer: mean, range: 0..<mean.length, value: 0)
        blit.endEncoding(); command.commit()
    }

    func encodeStep(_ command: MTLCommandBuffer, parameters: PoolParameters, impulses: [PoolImpulse], duration: Float) {
        guard let encoder = command.makeComputeCommandEncoder() else { return }
        var p = parameters
        p.dt = min(max(duration, 0), 0.1) / 4
        let count = Int(p.grid.x * p.grid.y)
        encoder.setComputePipelineState(stepPipeline)
        // Metal requires a valid binding even on a frame without new impulses.
        let inputs = impulses.isEmpty ? [PoolImpulse(center: .zero, radius: 0, strength: 0)] : impulses
        inputs.withUnsafeBytes { encoder.setBytes($0.baseAddress!, length: $0.count, index: 3) }
        for substep in 0..<4 {
            p.count = substep == 0 ? UInt32(impulses.count) : 0
            encoder.setBuffer(current, offset: 0, index: 0); encoder.setBuffer(other, offset: 0, index: 1)
            encoder.setBytes(&p, length: MemoryLayout<PoolParameters>.stride, index: 2)
            encoder.dispatchThreads(MTLSize(width: count, height: 1, depth: 1),
                                    threadsPerThreadgroup: MTLSize(width: min(128, stepPipeline.maxTotalThreadsPerThreadgroup), height: 1, depth: 1))
            encoder.memoryBarrier(scope: .buffers)
            swap(&current, &other)
        }
        encoder.setComputePipelineState(totalsPipeline)
        encoder.setBuffer(current, offset: 0, index: 0)
        encoder.setBytes(&p, length: MemoryLayout<PoolParameters>.stride, index: 1)
        encoder.setBuffer(mean, offset: 0, index: 2)
        encoder.setBuffer(energy, offset: 0, index: 3)
        encoder.dispatchThreads(MTLSize(width: 256, height: 1, depth: 1), threadsPerThreadgroup: MTLSize(width: 256, height: 1, depth: 1))
        encoder.memoryBarrier(scope: .buffers)
        encoder.setComputePipelineState(levelPipeline)
        encoder.dispatchThreads(MTLSize(width: count, height: 1, depth: 1),
                                threadsPerThreadgroup: MTLSize(width: min(128, levelPipeline.maxTotalThreadsPerThreadgroup), height: 1, depth: 1))
        encoder.endEncoding()
    }

    func encodeRender(_ command: MTLCommandBuffer, pass: MTLRenderPassDescriptor, parameters: PoolParameters, scale: Float) {
        guard let encoder = command.makeRenderCommandEncoder(descriptor: pass) else { return }
        var p = parameters, scale = scale
        encoder.setRenderPipelineState(renderPipeline)
        encoder.setVertexBuffer(current, offset: 0, index: 0)
        encoder.setVertexBytes(&p, length: MemoryLayout<PoolParameters>.stride, index: 1)
        encoder.setVertexBytes(&scale, length: MemoryLayout<Float>.size, index: 2)
        encoder.drawPrimitives(type: .point, vertexStart: 0, vertexCount: Int(p.renderGrid.x * p.renderGrid.y))
        encoder.endEncoding()
    }
}

@MainActor
final class WavePoolView: MTKView, AmbientSurface, MTKViewDelegate {
    let gpu: WaveGPU
    private(set) var configuration: AmbientConfiguration
    private var enabled = false
    private var hasEnergy = false
    private var inFlight = false
    private var generation = 0
    private var pending: [PoolImpulse] = []
    private var previousPointer: (CGPoint, TimeInterval)?
    private var lastFrame = CACurrentMediaTime()
    private var screenAwake = true
    private var sessionAvailable = true
    private var locked = (CGSessionCopyCurrentDictionary() as? [String: Any])?["CGSSessionScreenIsLocked"] as? Bool == true
    var isAnimating: Bool { !isPaused }

    init(device: MTLDevice, configuration: AmbientConfiguration) throws {
        self.configuration = configuration
        gpu = try WaveGPU(device: device)
        super.init(frame: .zero, device: device)
        colorPixelFormat = .bgra8Unorm
        clearColor = MTLClearColorMake(0, 0, 0, 0)
        layer?.isOpaque = false
        preferredFramesPerSecond = 15
        isPaused = true; enableSetNeedsDisplay = true
        delegate = self
        for name in [NSWindow.didChangeOcclusionStateNotification, NSApplication.didHideNotification, NSApplication.didUnhideNotification] {
            NotificationCenter.default.addObserver(self, selector: #selector(refresh), name: name, object: nil)
        }
        for name in [NSWorkspace.screensDidSleepNotification, NSWorkspace.screensDidWakeNotification,
                     NSWorkspace.sessionDidResignActiveNotification, NSWorkspace.sessionDidBecomeActiveNotification] {
            NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(environmentChanged(_:)), name: name, object: nil)
        }
        for name in ["com.apple.screenIsLocked", "com.apple.screenIsUnlocked"] {
            DistributedNotificationCenter.default().addObserver(self, selector: #selector(environmentChanged(_:)), name: Notification.Name(name), object: nil)
        }
    }

    required init(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    deinit {
        NotificationCenter.default.removeObserver(self)
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        DistributedNotificationCenter.default().removeObserver(self)
    }
    override var isOpaque: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.acceptsMouseMovedEvents = true
        refresh(); needsDisplay = true
    }
    override func viewDidHide() { super.viewDidHide(); refresh() }
    override func viewDidUnhide() { super.viewDidUnhide(); refresh() }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); needsDisplay = true }

    func configure(_ configuration: AmbientConfiguration) {
        guard self.configuration != configuration else { return }
        self.configuration = configuration
        generation += 1 // Redraw after any in-flight old configuration, even while calm.
        // The vertex pass rebuilds its implicit lattice; the wave field is preserved.
        needsDisplay = true
    }
    var parameters: PoolParameters {
        PoolParameters(visibleSize: SIMD2(Float(bounds.width), Float(bounds.height)), configuration: configuration,
                       dark: effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? 1 : 0)
    }
    func start() { enabled = true; refresh() }
    func stop() {
        guard enabled else { return }
        enabled = false; hasEnergy = false; pending.removeAll(); generation += 1
        gpu.clear(); refresh(); needsDisplay = true
    }

    func impulse(at point: CGPoint, strength: Float) { push(at: point, radius: 18, strength: strength) }
    func pointer(at point: CGPoint, velocity: CGVector) {
        let speed = hypot(velocity.dx, velocity.dy)
        guard speed > 2 else { return }
        push(at: point, radius: 0, strength: Float(min(speed / 160, 3)))
    }
    private func push(at point: CGPoint, radius: Float, strength: Float) {
        guard enabled, (bounds.isEmpty || bounds.contains(point)),
              point.x.isFinite, point.y.isFinite, strength.isFinite else { return }
        if pending.count < 32 {
            pending.append(PoolImpulse(center: SIMD2(Float(point.x), Float(point.y)), radius: radius, strength: min(max(strength, -4), 4)))
        }
        hasEnergy = true
        refresh()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }
    override func mouseEntered(with event: NSEvent) { previousPointer = (convert(event.locationInWindow, from: nil), event.timestamp) }
    override func mouseExited(with event: NSEvent) { previousPointer = nil }
    override func mouseMoved(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        defer { previousPointer = (point, event.timestamp) }
        guard let (last, time) = previousPointer else { return }
        let dt = event.timestamp - time
        guard dt > 0, dt < 0.25 else { return }
        // Integrate speed over time so a higher event rate does not stir harder.
        let factor = min(dt, 0.08) * 15
        pointer(at: point, velocity: CGVector(dx: (point.x-last.x)/dt*factor, dy: (point.y-last.y)/dt*factor))
    }

    @objc func environmentChanged(_ notification: Notification) {
        switch notification.name {
        case NSWorkspace.screensDidSleepNotification: screenAwake = false
        case NSWorkspace.screensDidWakeNotification: screenAwake = true
        case NSWorkspace.sessionDidResignActiveNotification: sessionAvailable = false
        case NSWorkspace.sessionDidBecomeActiveNotification: sessionAvailable = true
        case Notification.Name("com.apple.screenIsLocked"): locked = true
        case Notification.Name("com.apple.screenIsUnlocked"): locked = false
        default: break
        }
        refresh()
    }
    @objc private func refresh() {
        let running = enabled && hasEnergy && screenAwake && sessionAvailable && !locked
            && window?.isVisible == true && window?.occlusionState.contains(.visible) == true
            && !isHiddenOrHasHiddenAncestor && !NSApp.isHidden
        if running && isPaused { lastFrame = CACurrentMediaTime() }
        isPaused = !running
        if !running { previousPointer = nil }
    }

    nonisolated func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}
    nonisolated func draw(in view: MTKView) { MainActor.assumeIsolated { drawFrame() } }
    private func drawFrame() {
        guard !inFlight, bounds.width > 1, bounds.height > 1,
              let pass = currentRenderPassDescriptor, let drawable = currentDrawable,
              let command = gpu.queue.makeCommandBuffer() else { return }
        inFlight = true
        let now = CACurrentMediaTime()
        let parameters = self.parameters
        let moving = enabled && hasEnergy
        if moving {
            gpu.encodeStep(command, parameters: parameters, impulses: pending, duration: Float(min(now-lastFrame, 0.1)))
            pending.removeAll(); lastFrame = now
        }
        gpu.encodeRender(command, pass: pass, parameters: parameters, scale: Float(drawableSize.width / bounds.width))
        let generation = generation
        command.present(drawable)
        command.addCompletedHandler { [weak self] command in
            let completed = command.status == .completed
            let seconds = max(0, command.gpuEndTime - command.gpuStartTime)
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.inFlight = false
                self.gpu.gpuSeconds += seconds; self.gpu.frames += 1
                guard generation == self.generation else { self.needsDisplay = true; return }
                let energy = completed ? self.gpu.energy.contents().load(as: Float.self) : 0
                if moving && energy < 0.003 && self.pending.isEmpty {
                    self.hasEnergy = false; self.gpu.clear(); self.needsDisplay = true
                }
                self.refresh()
            }
        }
        command.commit()
    }
}

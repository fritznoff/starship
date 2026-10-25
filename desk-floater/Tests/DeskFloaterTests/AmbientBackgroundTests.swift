import AppKit
import SwiftUI
import XCTest
@testable import DeskFloater
#if canImport(FloaterAmbient)
import MetalKit
@testable import FloaterAmbient

@MainActor
final class AmbientBackgroundTests: XCTestCase {
    private func renderer() throws -> WaveGPU {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("Metal unavailable; the app uses a plain plate") }
        return try WaveGPU(device: device)
    }

    private func advance(_ gpu: WaveGPU, frames: Int, parameters: PoolParameters = PoolParameters(size: SIMD2(74, 66)),
                         impulses: [PoolImpulse] = []) throws {
        let command = try XCTUnwrap(gpu.queue.makeCommandBuffer())
        for i in 0..<frames { gpu.encodeStep(command, parameters: parameters, impulses: i == 0 ? impulses : [], duration: 1 / 15) }
        command.commit(); command.waitUntilCompleted()
        XCTAssertEqual(command.status, .completed, "\(String(describing: command.error))")
    }

    private func state(_ gpu: WaveGPU) -> [SIMD2<Float>] {
        Array(UnsafeBufferPointer(start: gpu.current.contents().assumingMemoryBound(to: SIMD2<Float>.self), count: WaveGPU.count))
    }

    func testCalmStaysCalmAndARingPropagatesThenSettlesOnTheGPU() throws {
        let gpu = try renderer()
        try advance(gpu, frames: 4)
        XCTAssertTrue(state(gpu).allSatisfy { $0 == .zero })
        try advance(gpu, frames: 1, impulses: [PoolImpulse(center: SIMD2(37, 33), radius: 18, strength: 2.6)])
        let first = state(gpu)
        XCTAssertTrue(first.allSatisfy { $0.x.isFinite && $0.y.isFinite })
        XCTAssertGreaterThan(first.map { abs($0.x) }.max()!, 0.05)
        try advance(gpu, frames: 30)
        XCTAssertNotEqual(state(gpu), first)
        XCTAssertEqual(state(gpu).map(\.x).reduce(0, +), 0, accuracy: 0.0001, "pool volume stays constant")
        try advance(gpu, frames: 900)
        XCTAssertLessThan(gpu.energy.contents().load(as: Float.self), 0.003, "a damped pool must eventually stop drawing")
    }

    func testTheWallMatchesAMirroredPoolRatherThanWrappingOrAbsorbing() throws {
        let half = try renderer(), full = try renderer()
        let halfParameters = PoolParameters(grid: SIMD2(16, 28), size: SIMD2(32, 56))
        let fullParameters = PoolParameters(size: SIMD2(64, 56))
        try advance(half, frames: 30, parameters: halfParameters,
                    impulses: [PoolImpulse(center: SIMD2(13, 28), radius: 0, strength: 2)])
        try advance(full, frames: 30, parameters: fullParameters,
                    impulses: [PoolImpulse(center: SIMD2(45, 28), radius: 0, strength: 2),
                               PoolImpulse(center: SIMD2(19, 28), radius: 0, strength: 2)])
        let a = state(half), b = state(full)
        for y in 0..<28 { for x in 0..<16 {
            XCTAssertEqual(a[y*16+x].x, b[y*32+16+x].x, accuracy: 0.0001)
        } }
    }

    func testGPUPointRenderingCoversThePlateAndRefractsInsteadOfKeepingAFlatPalette() throws {
        let gpu = try renderer()
        let calm = try render(gpu)
        let first = try XCTUnwrap(calm.bitmapData)
        var left = 148, right = 0, bottom = 132, top = 0
        for y in 0..<132 { for x in 0..<148 where first[y*calm.bytesPerRow+x*4+3] > 0 {
            left = min(left, x); right = max(right, x); bottom = min(bottom, y); top = max(top, y)
        } }
        XCTAssertLessThan(left, 5); XCTAssertGreaterThan(right, 142)
        XCTAssertLessThan(bottom, 5); XCTAssertGreaterThan(top, 126)
        try advance(gpu, frames: 5, impulses: [PoolImpulse(center: SIMD2(24, 42), radius: 18, strength: 3)])
        let waves = try render(gpu)
        XCTAssertNotEqual(calm.representation(using: .png, properties: [:]), waves.representation(using: .png, properties: [:]))
        let pixels = try XCTUnwrap(waves.bitmapData)
        var colors = Set<Int>()
        for y in 0..<132 { for x in 0..<148 {
            let i = y*waves.bytesPerRow+x*4
            if pixels[i+3] > 60 {
                let maximum = max(1, Int(max(pixels[i], max(pixels[i+1], pixels[i+2]))))
                colors.insert(Int(pixels[i])*7/maximum*64 + Int(pixels[i+1])*7/maximum*8 + Int(pixels[i+2])*7/maximum)
            }
        } }
        XCTAssertGreaterThan(colors.count, 10, "surface normals must refract several hues, not just pulse one color")
    }

    func testPointerWakesThePoolAndCalmViewsDoNotRunAFrameLoop() throws {
        let (window, slow) = try visiblePool()
        defer { window.orderOut(nil) }
        XCTAssertFalse(slow.isAnimating)
        pump(0.2)
        let idleFrames = slow.gpu.frames
        pump(0.2)
        XCTAssertEqual(slow.gpu.frames, idleFrames)
        slow.pointer(at: CGPoint(x: 37, y: 33), velocity: CGVector(dx: 80, dy: 0))
        XCTAssertTrue(slow.isAnimating)
        pump(0.15)
        XCTAssertGreaterThan(slow.gpu.frames, idleFrames)
        slow.stop()
        XCTAssertFalse(slow.isAnimating)
        slow.pointer(at: CGPoint(x: 37, y: 33), velocity: CGVector(dx: 800, dy: 0))
        XCTAssertFalse(slow.isAnimating)
        slow.start()
        XCTAssertFalse(slow.isAnimating, "reenabling a calm pool must not create a perpetual loop")
        XCTAssertNil(slow.hitTest(CGPoint(x: 10, y: 10)))
    }

    func testHiddenOccludedLockedAndSleepingPoolsPause() throws {
        let (window, view) = try visiblePool()
        defer { window.orderOut(nil) }
        view.impulse(at: CGPoint(x: 24, y: 42), strength: 2.6)
        XCTAssertTrue(view.isAnimating)
        for (pause, resume) in [("com.apple.screenIsLocked", "com.apple.screenIsUnlocked"),
                               (NSWorkspace.screensDidSleepNotification.rawValue, NSWorkspace.screensDidWakeNotification.rawValue),
                               (NSWorkspace.sessionDidResignActiveNotification.rawValue, NSWorkspace.sessionDidBecomeActiveNotification.rawValue)] {
            view.environmentChanged(Notification(name: Notification.Name(pause)))
            XCTAssertFalse(view.isAnimating)
            view.environmentChanged(Notification(name: Notification.Name(resume)))
            XCTAssertTrue(view.isAnimating)
        }
        let cover = NSWindow(contentRect: window.frame.insetBy(dx: -20, dy: -20), styleMask: [.borderless], backing: .buffered, defer: false)
        cover.isReleasedWhenClosed = false
        cover.level = NSWindow.Level(rawValue: window.level.rawValue + 1)
        cover.backgroundColor = .black; cover.isOpaque = true
        cover.orderFrontRegardless()
        defer { cover.orderOut(nil) }
        pump(0.3)
        XCTAssertFalse(view.isAnimating)
        cover.orderOut(nil); pump(0.2)
        XCTAssertTrue(view.isAnimating)
        view.isHidden = true; XCTAssertFalse(view.isAnimating)
        view.isHidden = false; XCTAssertTrue(view.isAnimating)
        window.orderOut(nil); pump(0.1); XCTAssertFalse(view.isAnimating)
    }

    func testSettingsRemoveTheModuleAndMotionBridgeFreezesItWithoutResizingControls() throws {
        let app = NSApplication.shared; app.setActivationPolicy(.accessory); app.finishLaunching()
        let suite = "ambient-setting-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = FloaterModel(repoRoot: "/nonexistent", fmHome: "/nonexistent")
        model.keysTrusted = true
        let mover = WindowMover()
        let root = FloaterView(model: model, mover: mover).defaultAppStorage(defaults)
        let host = NSHostingView(rootView: AnyView(root))
        // A type-erased XCTest host has no intrinsic size before a real app run loop.
        host.sizingOptions = []; host.frame = NSRect(x: 0, y: 0, width: 74, height: 66)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.level = .floating
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        window.setContentSize(host.frame.size)
        mover.window = window
        window.center(); window.orderFrontRegardless()
        defer { window.orderOut(nil) }
        for _ in 0..<20 { pump(0.1); if window.occlusionState.contains(.visible) { break } }
        guard window.occlusionState.contains(.visible) else { throw XCTSkip("requires an unobscured macOS window session") }
        let originalSize = host.frame.size
        let pool = try XCTUnwrap(findPool(host))
        XCTAssertFalse(pool.isAnimating, "launch is calm")
        model.mode = .starting; pump(0.2)
        XCTAssertTrue(try XCTUnwrap(findPool(host)).isAnimating, "a recording-button rising edge pushes a ring, including a newly laid-out background")
        defaults.set(false, forKey: AmbientSettings.defaultsKey); pump(0.2)
        XCTAssertNil(findPool(host), "off must remove the module, not merely pause its drawing")
        XCTAssertEqual(host.frame.size, originalSize)
        defaults.set(true, forKey: AmbientSettings.defaultsKey)
        model.mode = .idle; pump(0.2)
        XCTAssertNotNil(findPool(host))
        host.rootView = AnyView(AmbientHost(active: true, center: CGPoint(x: 24, y: 42), reduceMotion: true))
        pump(0.2)
        XCTAssertFalse(try XCTUnwrap(findPool(host)).isAnimating)
        XCTAssertTrue(state(try XCTUnwrap(findPool(host)).gpu).allSatisfy { $0 == .zero })
    }

    private func visiblePool() throws -> (NSWindow, WavePoolView) {
        let app = NSApplication.shared; app.setActivationPolicy(.accessory); app.finishLaunching()
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("Metal unavailable") }
        let view = try WavePoolView(device: device)
        view.frame = NSRect(x: 0, y: 0, width: 74, height: 66)
        let window = NSWindow(contentRect: view.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.level = .floating; window.contentView = view
        window.center(); window.orderFrontRegardless(); view.start()
        for _ in 0..<20 { pump(0.1); if window.occlusionState.contains(.visible) { break } }
        guard window.occlusionState.contains(.visible) else { window.orderOut(nil); throw XCTSkip("requires a visible macOS session") }
        return (window, view)
    }

    private func findPool(_ view: NSView) -> WavePoolView? {
        if let pool = view as? WavePoolView { return pool }
        for child in view.subviews { if let found = findPool(child) { return found } }
        return nil
    }

    private func pump(_ seconds: TimeInterval) {
        let until = Date().addingTimeInterval(seconds)
        while Date() < until {
            if let event = NSApp.nextEvent(matching: .any, until: Date().addingTimeInterval(0.01), inMode: .default, dequeue: true) {
                NSApp.sendEvent(event)
            }
        }
    }

    private func render(_ gpu: WaveGPU) throws -> NSBitmapImageRep {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: 148, height: 132, mipmapped: false)
        descriptor.storageMode = .shared; descriptor.usage = .renderTarget
        let texture = try XCTUnwrap(gpu.device.makeTexture(descriptor: descriptor))
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = texture
        pass.colorAttachments[0].loadAction = .clear; pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 0)
        let command = try XCTUnwrap(gpu.queue.makeCommandBuffer())
        gpu.encodeRender(command, pass: pass, parameters: PoolParameters(size: SIMD2(74, 66)), scale: 2)
        command.commit(); command.waitUntilCompleted()
        XCTAssertEqual(command.status, .completed, "\(String(describing: command.error))")
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 148, pixelsHigh: 132, bitsPerSample: 8,
                                  samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                  bytesPerRow: 148*4, bitsPerPixel: 32)!
        texture.getBytes(rep.bitmapData!, bytesPerRow: rep.bytesPerRow, from: MTLRegionMake2D(0, 0, 148, 132), mipmapLevel: 0)
        // Texture bytes are BGRA; AppKit's bitmap representation is RGBA.
        let bytes = rep.bitmapData!
        for i in stride(from: 0, to: rep.bytesPerRow*132, by: 4) { let b = bytes[i]; bytes[i] = bytes[i+2]; bytes[i+2] = b }
        return rep
    }
}
#endif

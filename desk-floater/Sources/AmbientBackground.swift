import AppKit
import SwiftUI
#if canImport(FloaterAmbient)
import FloaterAmbient
#endif

enum AmbientSettings {
    static let defaultsKey = "animatedBackground"
    static let dampingKey = "ambientDamping"
    static let dotSizeKey = "ambientDotSize"
    static let dotSpacingKey = "ambientDotSpacing"
    static let damping = 0.12
    static let dotSize = 1.35
    static let dotSpacing = 2.5
    static let dampingRange = 0.04...0.8
    static let dotSizeRange = 0.7...2.2
    static let dotSpacingRange = 2.0...6.0

    static func resetSliders(in defaults: UserDefaults = .standard) {
        defaults.set(damping, forKey: dampingKey)
        defaults.set(dotSize, forKey: dotSizeKey)
        defaults.set(dotSpacing, forKey: dotSpacingKey)
    }
}

/// The main app only supplies settings and a rising recording-button edge.
struct AmbientBackground: View {
    let active: Bool
    let center: CGPoint
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage(AmbientSettings.dampingKey) private var damping = AmbientSettings.damping
    @AppStorage(AmbientSettings.dotSizeKey) private var dotSize = AmbientSettings.dotSize
    @AppStorage(AmbientSettings.dotSpacingKey) private var dotSpacing = AmbientSettings.dotSpacing

    var body: some View {
        #if canImport(FloaterAmbient)
        AmbientHost(active: active, center: center, reduceMotion: reduceMotion,
                    configuration: AmbientConfiguration(damping: Float(damping), dotSize: Float(dotSize), dotSpacing: Float(dotSpacing)))
        #else
        EmptyView()
        #endif
    }
}

#if canImport(FloaterAmbient)
struct AmbientHost: NSViewRepresentable {
    let active: Bool
    let center: CGPoint
    let reduceMotion: Bool
    let configuration: AmbientConfiguration
    final class Coordinator { var active = false }
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> NSView { makeAmbientSurface(configuration: configuration) ?? NSView() }
    func updateNSView(_ view: NSView, context: Context) {
        guard let surface = view as? AmbientSurface else { return }
        surface.configure(configuration)
        if reduceMotion { surface.stop() } else { surface.start() }
        if active && !context.coordinator.active && !reduceMotion { surface.impulse(at: center, strength: 2.6) }
        context.coordinator.active = active
    }
    static func dismantleNSView(_ view: NSView, coordinator: Coordinator) { (view as? AmbientSurface)?.stop() }
}
#endif

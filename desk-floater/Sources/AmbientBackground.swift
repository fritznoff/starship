import AppKit
import SwiftUI
#if canImport(FloaterAmbient)
import FloaterAmbient
#endif

enum AmbientSettings {
    static let defaultsKey = "animatedBackground"
}

/// The main app only supplies settings and a rising recording-button edge.
struct AmbientBackground: View {
    let active: Bool
    let center: CGPoint
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        #if canImport(FloaterAmbient)
        AmbientHost(active: active, center: center, reduceMotion: reduceMotion)
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
    final class Coordinator { var active = false }
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> NSView { makeAmbientSurface() ?? NSView() }
    func updateNSView(_ view: NSView, context: Context) {
        guard let surface = view as? AmbientSurface else { return }
        if reduceMotion { surface.stop() } else { surface.start() }
        if active && !context.coordinator.active && !reduceMotion { surface.impulse(at: center, strength: 2.6) }
        context.coordinator.active = active
    }
    static func dismantleNSView(_ view: NSView, coordinator: Coordinator) { (view as? AmbientSurface)?.stop() }
}
#endif

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
    static let dotBrightnessKey = "ambientDotBrightness"
    static let damping = 0.12
    static let dotSize = 1.35
    static let dotSpacing = 2.5
    static let dotBrightness = 1.0
    static let dampingRange = 0.04...0.8
    static let dotSizeRange = 0.7...2.2
    static let dotSpacingRange = 2.0...6.0
    static let dotBrightnessRange = 0.2...2.0

    static func resetSliders(in defaults: UserDefaults = .standard) {
        defaults.set(damping, forKey: dampingKey)
        defaults.set(dotSize, forKey: dotSizeKey)
        defaults.set(dotSpacing, forKey: dotSpacingKey)
        defaults.set(dotBrightness, forKey: dotBrightnessKey)
    }
}

struct AmbientSpeechRipple {
    static let minimumAmplitude = 0.08
    static let minimumInterval: TimeInterval = 0.12
    static let minimumStrength: Float = 0.08
    static let maximumStrength: Float = 1.0
    // SpeechLevel maps -55...-10 dB to 0...1; keep ripple strength linear in dB.
    private static let meterFloorDB = -55.0
    private static let meterRangeDB = 45.0
    private static let loudCeilingDB = -10.0

    private var lastImpulseAt: TimeInterval? = nil

    init() {}

    static func strength(for amplitude: Double) -> Float? {
        guard amplitude.isFinite else { return nil }
        let decibels = meterFloorDB + min(1, max(0, amplitude)) * meterRangeDB
        let floorDB = meterFloorDB + minimumAmplitude * meterRangeDB
        guard decibels > floorDB else { return nil }
        let normalizedDB = min(1, (decibels - floorDB) / (loudCeilingDB - floorDB))
        return minimumStrength + Float(normalizedDB) * (maximumStrength - minimumStrength)
    }

    mutating func nextStrength(amplitude: Double, recording: Bool, reduceMotion: Bool, at time: TimeInterval) -> Float? {
        guard recording, !reduceMotion, time.isFinite,
              let strength = Self.strength(for: amplitude),
              lastImpulseAt.map({ time - $0 >= Self.minimumInterval }) ?? true else { return nil }
        lastImpulseAt = time
        return strength
    }
}

/// The main app only supplies settings, recording level, and a rising button edge.
struct AmbientBackground: View {
    let active: Bool
    let recording: Bool
    let amplitude: Double
    let center: CGPoint
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage(AmbientSettings.dampingKey) private var damping = AmbientSettings.damping
    @AppStorage(AmbientSettings.dotSizeKey) private var dotSize = AmbientSettings.dotSize
    @AppStorage(AmbientSettings.dotSpacingKey) private var dotSpacing = AmbientSettings.dotSpacing
    @AppStorage(AmbientSettings.dotBrightnessKey) private var dotBrightness = AmbientSettings.dotBrightness

    var body: some View {
        #if canImport(FloaterAmbient)
        AmbientHost(active: active, recording: recording, amplitude: amplitude, center: center, reduceMotion: reduceMotion,
                    configuration: AmbientConfiguration(damping: Float(damping), dotSize: Float(dotSize), dotSpacing: Float(dotSpacing), dotBrightness: Float(dotBrightness)))
        #else
        EmptyView()
        #endif
    }
}

#if canImport(FloaterAmbient)
struct AmbientHost: NSViewRepresentable {
    let active: Bool
    let recording: Bool
    let amplitude: Double
    let center: CGPoint
    let reduceMotion: Bool
    let configuration: AmbientConfiguration
    final class Coordinator {
        var active = false
        var speechRipple = AmbientSpeechRipple()
    }
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> NSView { makeAmbientSurface(configuration: configuration) ?? NSView() }
    func updateNSView(_ view: NSView, context: Context) {
        guard let surface = view as? AmbientSurface else { return }
        surface.configure(configuration)
        if reduceMotion { surface.stop() } else { surface.start() }
        if active && !context.coordinator.active && !reduceMotion { surface.impulse(at: center, strength: 2.6) }
        if let strength = context.coordinator.speechRipple.nextStrength(
            amplitude: amplitude, recording: recording, reduceMotion: reduceMotion,
            at: ProcessInfo.processInfo.systemUptime) {
            surface.impulse(at: center, strength: strength)
        }
        context.coordinator.active = active
    }
    static func dismantleNSView(_ view: NSView, coordinator: Coordinator) { (view as? AmbientSurface)?.stop() }
}
#endif

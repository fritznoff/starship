import AppKit
import SwiftUI

/// Device-dependent flags distinguish both sides of each supported modifier.
struct ActivationShortcut: Equatable {
    static let choices: [(name: String, bit: UInt)] = [
        ("Left Command", 0x08), ("Right Command", 0x10),
        ("Left Option", 0x20), ("Right Option", 0x40),
        ("Left Shift", 0x02), ("Right Shift", 0x04),
        ("Left Control", 0x01), ("Right Control", 0x2000)
    ]
    static let defaultBits: UInt = 0x10 | 0x40 | 0x04
    static let defaultsKey = "activationShortcut"
    let bits: UInt

    init?(bits: UInt) {
        let supported = Self.choices.reduce(UInt(0)) { $0 | $1.bit }
        guard bits & ~supported == 0, bits.nonzeroBitCount >= 2 else { return nil }
        self.bits = bits
    }

    /// Persist decimal device flags, never generic Command/Option flags.
    init?(stored: String) {
        guard let bits = UInt(stored) else { return nil }
        self.init(bits: bits)
    }

    static func load(from defaults: UserDefaults = .standard) -> Self {
        defaults.string(forKey: defaultsKey).flatMap(Self.init(stored:))
            ?? Self(bits: defaultBits)!
    }

    func save(to defaults: UserDefaults = .standard) {
        defaults.set(String(bits), forKey: Self.defaultsKey)
    }

    var name: String {
        Self.choices.filter { bits & $0.bit != 0 }.map(\.name).joined(separator: " + ")
    }

    var warning: String? {
        bits & Self.defaultBits == 0 ? nil
            : "Shares keys with talk, dictation or screenshot hotkeys. Completing the chord cancels a capture those keys just began."
    }
}

@MainActor
final class ActivationSettingsWindow {
    private var window: NSWindow?

    var isVisible: Bool { window?.isVisible == true }

    func show(shortcut: ActivationShortcut, apply: @escaping (ActivationShortcut) -> Void) {
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 440, height: 330),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Activation Shortcut"
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: ActivationSettingsView(bits: shortcut.bits, apply: apply))
        window.center()
        self.window = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

private struct ActivationSettingsView: View {
    @State var bits: UInt
    @AppStorage(AmbientSettings.defaultsKey) private var animatedBackground = true
    let apply: (ActivationShortcut) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Activation shortcut").font(.headline)
            Text("Pick at least two modifier keys. Left and right are distinct.")
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], alignment: .leading) {
                ForEach(ActivationShortcut.choices, id: \.bit) { choice in
                    Toggle(choice.name, isOn: Binding(
                        get: { bits & choice.bit != 0 },
                        set: { bits = $0 ? bits | choice.bit : bits & ~choice.bit }
                    ))
                }
            }
            if let shortcut = ActivationShortcut(bits: bits) {
                Text(shortcut.name).font(.callout)
                if let warning = shortcut.warning {
                    Text(warning).font(.caption).foregroundStyle(.orange)
                }
            } else {
                Text("Choose at least two modifier keys.").foregroundStyle(.red)
            }
            Text("Shows or hides the floater; never sends a recording. Changes apply immediately.")
                .font(.caption)
            Toggle("Animated background", isOn: $animatedBackground)
                .toggleStyle(.switch)
        }
        .padding(20)
        .frame(width: 440)
        .onChange(of: bits) { _, bits in
            guard let shortcut = ActivationShortcut(bits: bits) else { return }
            apply(shortcut)
        }
    }
}

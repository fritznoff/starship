import AppKit
import ApplicationServices
import AVFoundation
import Carbon
import SwiftUI

/// A query must never prompt or confuse an unavailable target with a denied grant.
enum PermissionState: Equatable {
    case granted, missing, notDetermined, unavailable

    var label: String {
        switch self {
        case .granted: return "Granted"
        case .missing: return "Missing"
        case .notDetermined: return "Not requested"
        case .unavailable: return "Open Terminal to check"
        }
    }

    static func microphone(_ status: AVAuthorizationStatus) -> Self {
        switch status {
        case .authorized: return .granted
        case .notDetermined: return .notDetermined
        default: return .missing
        }
    }

    static func automation(_ status: OSStatus) -> Self {
        switch status {
        case noErr: return .granted
        case OSStatus(errAEEventWouldRequireUserConsent): return .notDetermined
        case OSStatus(errAEEventNotPermitted): return .missing
        default: return .unavailable
        }
    }
}

enum FloaterPermission: String, CaseIterable, Identifiable {
    case microphone, accessibility, screenRecording, automation
    var id: Self { self }

    var title: String {
        switch self {
        case .microphone: return "Microphone"
        case .accessibility: return "Accessibility"
        case .screenRecording: return "Screen & System Audio Recording"
        case .automation: return "Control Terminal (Optional)"
        }
    }

    var why: String {
        switch self {
        case .microphone: return "Records your voice only when you ask to talk or dictate."
        case .accessibility: return "Reads the activation chord and hotkeys, and pastes dictation."
        case .screenRecording: return "Takes screenshots only when you ask. System audio is not captured."
        case .automation: return "Only for dictation into Apple Terminal's Firstmate tab"
        }
    }

    var settingsURL: URL {
        let pane: String
        switch self {
        case .microphone: pane = "Privacy_Microphone"
        case .accessibility: pane = "Privacy_Accessibility"
        case .screenRecording: pane = "Privacy_ScreenCapture"
        case .automation: pane = "Privacy_Automation"
        }
        return URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)")!
    }

    var isRequired: Bool { self != .automation }

    static func visible(terminalInstalled: Bool) -> [Self] {
        allCases.filter { $0 != .automation || terminalInstalled }
    }

    static func needsSetup(_ states: [Self: PermissionState]) -> Bool {
        allCases.contains { $0.isRequired && states[$0] != .granted }
    }

    var supportsAppDrop: Bool { self == .accessibility || self == .screenRecording }

    func state() -> PermissionState {
        switch self {
        case .microphone: return .microphone(AVCaptureDevice.authorizationStatus(for: .audio))
        case .accessibility: return AXIsProcessTrusted() ? .granted : .missing
        case .screenRecording: return CGPreflightScreenCaptureAccess() ? .granted : .missing
        case .automation: return .automation(Self.terminalAccess(prompt: false))
        }
    }

    /// The bundle-ID target avoids sending any actual event or executing an AppleScript.
    static func terminalAccess(prompt: Bool) -> OSStatus {
        var target = AEAddressDesc()
        let identifier = Array("com.apple.Terminal".utf8)
        let result = identifier.withUnsafeBytes {
            AECreateDesc(DescType(typeApplicationBundleID), $0.baseAddress, $0.count, &target)
        }
        guard result == noErr else { return OSStatus(result) }
        defer { AEDisposeDesc(&target) }
        return AEDeterminePermissionToAutomateTarget(&target, AEEventClass(typeWildCard), AEEventID(typeWildCard), prompt)
    }
}

@MainActor
final class PermissionsController: NSObject, ObservableObject, NSWindowDelegate {
    static var appName: String {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
            ?? (Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String)
            ?? Bundle.main.bundleURL.deletingPathExtension().lastPathComponent
    }

    @Published private(set) var states: [FloaterPermission: PermissionState] = [:]
    var visiblePermissions: [FloaterPermission] {
        FloaterPermission.visible(terminalInstalled:
            NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Terminal") != nil)
    }

    @Published private(set) var requesting = false
    @Published private(set) var error: String?
    private var window: NSWindow?
    private var helper: NSPanel?
    private var selected: FloaterPermission?
    private var sawSettingsWindow = false
    private var timer: Timer?
    private var statusItem: NSStatusItem?

    func start() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "mic.circle", accessibilityDescription: Self.appName)
        let menu = NSMenu()
        let permissions = menu.addItem(withTitle: "Permissions…", action: #selector(show), keyEquivalent: ",")
        permissions.target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit \(Self.appName)", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        item.menu = menu
        statusItem = item
        NotificationCenter.default.addObserver(self, selector: #selector(refresh),
                                               name: NSApplication.didBecomeActiveNotification, object: nil)
        refresh()
        if FloaterPermission.needsSetup(states) { show() }
    }

    @objc func show() {
        if window == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 590, height: 490),
                                  styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.title = "\(Self.appName) Permissions"
            window.isReleasedWhenClosed = false
            window.delegate = self
            let content = NSHostingView(rootView: PermissionsView(controller: self))
            window.contentView = content
            window.setContentSize(content.fittingSize)
            window.center()
            self.window = window
        }
        refresh()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        if timer == nil {
            timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.refresh()
                    self?.positionHelper()
                }
            }
        }
    }

    @objc private func refresh() {
        states = Dictionary(uniqueKeysWithValues: visiblePermissions.map { ($0, $0.state()) })
    }

    func windowWillClose(_ notification: Notification) {
        if notification.object as? NSWindow === helper {
            selected = nil
            return
        }
        timer?.invalidate()
        timer = nil
        helper?.orderOut(nil)
        selected = nil
    }

    func open(_ permission: FloaterPermission) {
        guard !requesting else { return }
        requesting = true
        error = nil
        Task {
            switch permission {
            case .microphone:
                if permission.state() == .notDetermined {
                    _ = await AVCaptureDevice.requestAccess(for: .audio)
                }
            case .automation:
                // A stopped Terminal cannot answer the permission query. Only this explicit
                // button may launch it, never the periodic status refresh.
                if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Terminal") {
                    do {
                        let config = NSWorkspace.OpenConfiguration()
                        config.activates = false
                        _ = try await NSWorkspace.shared.openApplication(at: url, configuration: config)
                    } catch {
                        self.error = "Could not open Terminal. Open it yourself, then try again."
                    }
                }
                if permission.state() == .notDetermined {
                    _ = await Task.detached { FloaterPermission.terminalAccess(prompt: true) }.value
                }
            case .accessibility:
                let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
                _ = AXIsProcessTrustedWithOptions(options)
            case .screenRecording:
                if permission.state() != .granted { _ = CGRequestScreenCaptureAccess() }
            }
            requesting = false
            refresh()
            guard NSWorkspace.shared.open(permission.settingsURL) else {
                error = "Could not open System Settings. Open Privacy & Security manually."
                return
            }
            showHelper(for: permission)
        }
    }

    private func showHelper(for permission: FloaterPermission) {
        selected = permission
        sawSettingsWindow = false
        if helper == nil {
            let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 420, height: 100),
                                styleMask: [.titled, .closable, .nonactivatingPanel], backing: .buffered, defer: false)
            panel.title = "Permission helper"
            panel.isReleasedWhenClosed = false
            panel.delegate = self
            panel.level = .floating
            panel.hidesOnDeactivate = false
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            helper = panel
        }
        helper?.contentView = NSHostingView(rootView: PermissionDragView(permission: permission))
        positionHelper()
    }

    private func positionHelper() {
        guard selected != nil, let helper else { return }
        // Do not leave a floating helper over unrelated apps or after Settings closes.
        guard NSWorkspace.shared.frontmostApplication?.bundleIdentifier == "com.apple.systempreferences" else {
            helper.orderOut(nil)
            return
        }
        let settingsFrame = Self.settingsWindowFrame()
        if settingsFrame != nil {
            sawSettingsWindow = true
        } else if sawSettingsWindow {
            helper.orderOut(nil)
            return
        }
        let screen = settingsFrame.flatMap { frame in
            NSScreen.screens.max { $0.frame.intersection(frame).area < $1.frame.intersection(frame).area }
        } ?? NSScreen.main
        guard let screen else { return }
        let frame = PermissionPanelPlacement.frame(settings: settingsFrame, visible: screen.visibleFrame, size: helper.frame.size)
        helper.setFrame(frame, display: true)
        helper.orderFrontRegardless()
    }

    private static func settingsWindowFrame() -> CGRect? {
        guard let pid = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.systempreferences")
            .first?.processIdentifier,
              let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]], let top = NSScreen.screens.first?.frame.maxY else { return nil }
        return windows.compactMap { window -> CGRect? in
            guard window[kCGWindowOwnerPID as String] as? pid_t == pid,
                  window[kCGWindowLayer as String] as? Int == 0,
                  let bounds = window[kCGWindowBounds as String] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: bounds), rect.width > 300, rect.height > 200 else { return nil }
            return CGRect(x: rect.minX, y: top - rect.maxY, width: rect.width, height: rect.height)
        }.max { $0.area < $1.area }
    }
}

private extension CGRect {
    var area: CGFloat { isNull ? 0 : width * height }
}

enum PermissionPanelPlacement {
    static func frame(settings: CGRect?, visible: CGRect, size: CGSize) -> CGRect {
        let x = (settings?.midX ?? visible.midX) - size.width / 2
        let y = settings.map { $0.minY - size.height - 8 } ?? (visible.minY + 40)
        return CGRect(x: max(visible.minX, min(x, visible.maxX - size.width)),
                      y: max(visible.minY, min(y, visible.maxY - size.height)),
                      width: size.width, height: size.height)
    }
}

private struct PermissionsView: View {
    @ObservedObject var controller: PermissionsController

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Set up \(PermissionsController.appName)").font(.title2.bold())
            Text("Choose a permission to open its Privacy & Security page. You stay in control of every grant.")
                .foregroundStyle(.secondary)
            ForEach(controller.visiblePermissions) { permission in
                let state = controller.states[permission] ?? .unavailable
                HStack(spacing: 12) {
                    Image(systemName: state == .granted ? "checkmark.circle.fill"
                          : permission.isRequired ? "exclamationmark.circle.fill" : "info.circle")
                        .foregroundStyle(state == .granted ? Color.green
                                         : permission.isRequired ? Color.orange : Color.secondary)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(permission.title).font(.headline)
                        Text(permission.why).font(.caption).foregroundStyle(.secondary)
                        Text(!permission.isRequired && state != .granted ? "Optional - not enabled" : state.label)
                            .font(.caption.bold())
                    }
                    Spacer()
                    Button("Open Settings") { controller.open(permission) }
                        .disabled(controller.requesting)
                        .accessibilityLabel("Open \(permission.title) settings")
                }
            }
            Text("If Screen Recording still shows missing after enabling it, macOS may require Quit & Reopen.")
                .font(.caption).foregroundStyle(.secondary)
            if let error = controller.error { Text(error).font(.caption).foregroundStyle(.red) }
        }
        .padding(24)
        .frame(width: 590)
        .fixedSize(horizontal: false, vertical: true)
    }
}

private struct PermissionDragView: View {
    let permission: FloaterPermission

    var body: some View {
        HStack(spacing: 12) {
            HStack {
                Image(nsImage: NSWorkspace.shared.icon(forFile: Bundle.main.bundlePath))
                    .resizable().frame(width: 36, height: 36)
                Text(PermissionsController.appName).font(.headline)
            }
            .padding(6)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
            .onDrag { NSItemProvider(object: Bundle.main.bundleURL as NSURL) }
            .accessibilityLabel("Drag \(PermissionsController.appName) app into the permission list")
            Text(permission.supportsAppDrop
                 ? "Drag the app into the list above, then switch it on."
                 : "Use the Allow prompt or the existing switch. This page does not accept app drops.")
                .font(.caption)
        }
        .padding(12)
        .frame(width: 420, height: 100)
    }
}

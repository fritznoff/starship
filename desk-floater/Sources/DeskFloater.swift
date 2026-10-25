import AppKit
import ApplicationServices
import Carbon
import AVFoundation
import SwiftUI

@main
enum DeskFloaterApp {
    @MainActor
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        // AppKit owns the floater and the explicit permissions window; no placeholder scene.
        withExtendedLifetime(delegate) {
            app.run()
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var panel: FloaterPanel?
    private var hotkeys: HotkeyMonitor?
    private var screen: ScreenAccess?
    private let activationSettings = ActivationSettingsWindow()
    private let permissions = PermissionsController()

    @MainActor
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        guard let hotkeys else { return false }
        hotkeys.resetHotkeys()
        activationSettings.show(shortcut: hotkeys.activationShortcut) { [weak hotkeys] shortcut in
            shortcut.save()
            hotkeys?.activationShortcut = shortcut
        }
        return false
    }

    @MainActor
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        guard let location = HomeLocation.resolve(
            environment: ProcessInfo.processInfo.environment,
            bundlePath: Bundle.main.bundlePath,
            currentDirectory: FileManager.default.currentDirectoryPath,
            settings: HomeLocation.savedSettings(),
            isCodeRoot: HomeLocation.isCodeRoot
        ) else {
            NSApp.activate(ignoringOtherApps: true)
            let alert = NSAlert()
            alert.messageText = "Starship Floater cannot find its Firstmate home"
            alert.informativeText = "Start it with bin/fm-desk-floater.sh in your Firstmate folder, or configure ~/Library/Application Support/Firstmate/desk-floater.json as described in docs/desk-floater.md."
            alert.runModal()
            NSApp.terminate(nil)
            return
        }
        let model = FloaterModel(repoRoot: location.root, fmHome: location.home)
        let panel = FloaterPanel(model: model)
        self.panel = panel

        let hotkeys = HotkeyMonitor()
        hotkeys.settingsVisible = { [weak self] in self?.activationSettings.isVisible == true }
        model.activationShortcut = hotkeys.activationShortcut
        hotkeys.onShortcutChanged = { [weak model] in model?.activationShortcut = $0 }
        hotkeys.onTalkDown = { [weak model] in model?.hotkeyTalkBegan() }
        hotkeys.onTalkUp = { [weak model] in model?.hotkeyTalkEnded() }
        hotkeys.onTalkChord = { [weak model] in model?.hotkeyTalkChorded() }
        hotkeys.onEscape = { [weak model] in model?.cancelPending() }
        hotkeys.onDictateTap = { [weak model] in model?.toggleDictation() }
        hotkeys.onShotTap = { [weak model] in model?.takeShot() }
        hotkeys.onChord = { [weak model] in model?.toggleActive() }
        hotkeys.onTrustChanged = { [weak model] trusted in model?.keysTrusted = trusted }
        model.onFixKeys = { [weak self] in self?.permissions.show() }
        hotkeys.start()
        self.hotkeys = hotkeys
        // The floater starts out of sight: only the activation chord, or a
        // missing Accessibility grant that leaves the chord unreadable, shows it.
        model.onActiveChanged = { [weak hotkeys] active in hotkeys?.hotkeysEnabled = active }
        model.onShownChanged = { [weak panel] shown in
            if shown {
                panel?.orderFrontRegardless()
            } else {
                TipWindow.shared.hide()
                panel?.orderOut(nil)
            }
        }
        model.refreshShown()

        let screen = ScreenAccess()
        screen.onChanged = { [weak model] granted in model?.screenTrusted = granted }
        model.onFixScreen = { [weak self] in self?.permissions.show() }
        screen.start()
        self.screen = screen
        model.refreshMute()
        model.recoverRecordings()
        permissions.start()
    }
}

/// Launcher environment and in-repo bundles take precedence over Finder settings.
enum HomeLocation {
    static func resolve(
        environment: [String: String],
        bundlePath: String,
        currentDirectory: String,
        settings: [String: String] = [:],
        isCodeRoot: (String) -> Bool
    ) -> (root: String, home: String)? {
        var root = nonEmpty(environment["FM_DESK_FLOATER_ROOT"])
        if root == nil {
            let build = URL(fileURLWithPath: bundlePath).standardizedFileURL.deletingLastPathComponent()
            let package = build.deletingLastPathComponent()
            let candidate = package.deletingLastPathComponent().path
            if build.lastPathComponent == ".build" && package.lastPathComponent == "desk-floater"
                && isCodeRoot(candidate) {
                root = candidate
            }
        }
        if root == nil && isCodeRoot(currentDirectory) {
            root = currentDirectory
        }
        var home = nonEmpty(environment["FM_HOME"])
        if root == nil, let home, isCodeRoot(home) {
            root = home
        }
        if root == nil, let savedRoot = settings["root"], savedRoot.hasPrefix("/"),
           isCodeRoot(savedRoot) {
            root = savedRoot
            home = home ?? nonEmpty(settings["home"])
        }
        guard let root, isCodeRoot(root) else { return nil }
        if let home, !home.hasPrefix("/") { return nil }
        return (root, home ?? root)
    }

    static func savedSettings(at file: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Firstmate/desk-floater.json")) -> [String: String] {
        guard let data = try? Data(contentsOf: file),
              let settings = try? JSONDecoder().decode([String: String].self, from: data)
        else { return [:] }
        return settings
    }

    /// A Firstmate code root holds the scripts the floater runs.
    static func isCodeRoot(_ path: String) -> Bool {
        FileManager.default.isExecutableFile(
            atPath: (path as NSString).appendingPathComponent("bin/fm-desk-voice.sh"))
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        return value
    }
}

final class FloaterPanel: NSPanel {
    private weak var model: FloaterModel?

    @MainActor
    init(model: FloaterModel) {
        let mover = WindowMover()
        let view = FloaterView(model: model, mover: mover)
        let hosting = NSHostingView(rootView: view)
        // WindowMover sizes the window: left to itself the hosting view would
        // grow it from the top-left corner and push the controls off-screen.
        hosting.sizingOptions = []
        hosting.frame = NSRect(origin: .zero, size: hosting.fittingSize)
        super.init(
            contentRect: hosting.frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        self.model = model
        self.contentView = hosting
        self.isFloatingPanel = true
        // Clicking a control must never take keyboard focus from the app the
        // captain is typing in: dictation pastes into whatever has the cursor.
        self.becomesKeyOnlyIfNeeded = true
        self.level = .floating
        self.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        self.backgroundColor = .clear
        self.isOpaque = false
        self.hasShadow = true
        if let screen = NSScreen.main {
            let f = screen.visibleFrame
            self.setFrameOrigin(NSPoint(x: f.maxX - hosting.frame.width - 24, y: f.midY))
        }
        // Only once the panel is placed, so the first fit anchors to where the
        // captain sees it rather than to the origin it was created at.
        mover.window = self
    }

    override var canBecomeKey: Bool { true }

    /// A click anywhere on the floater counts as using it.
    override func sendEvent(_ event: NSEvent) {
        switch event.type {
        case .leftMouseDown, .rightMouseDown, .otherMouseDown:
            model?.noteUse()
            TipWindow.shared.hide()
        default:
            break
        }
        super.sendEvent(event)
    }
}

/// Moves the floater with the pointer while its backing plate is dragged, and
/// resizes it when the recent-replies list opens or closes. The top-right
/// corner stays put, so the controls do not jump and the list drops down and
/// to the left of them.
final class WindowMover {
    weak var window: NSWindow?
    private var startOrigin: NSPoint?
    private var startMouse: NSPoint?
    private var anchor: NSPoint?
    private var fitted: NSRect?

    func drag() {
        guard let window else { return }
        let mouse = NSEvent.mouseLocation
        if startOrigin == nil {
            startOrigin = window.frame.origin
            startMouse = mouse
        }
        guard let origin = startOrigin, let start = startMouse else { return }
        window.setFrameOrigin(NSPoint(x: origin.x + mouse.x - start.x, y: origin.y + mouse.y - start.y))
    }

    func fit(_ size: CGSize) {
        guard let window, size.width > 0, size.height > 0 else { return }
        let frame = window.frame
        let corner = (frame == fitted ? anchor : nil) ?? NSPoint(x: frame.maxX, y: frame.maxY)
        anchor = corner
        var rect = NSRect(x: corner.x - size.width, y: corner.y - size.height, width: size.width, height: size.height)
        if let visible = (window.screen ?? NSScreen.main)?.visibleFrame {
            rect.origin.x = max(min(rect.origin.x, visible.maxX - rect.width), visible.minX)
            rect.origin.y = max(min(rect.origin.y, visible.maxY - rect.height), visible.minY)
        }
        if rect != frame {
            window.setFrame(rect, display: true)
            window.invalidateShadow()
        }
        fitted = window.frame
    }

    func end() {
        startOrigin = nil
        startMouse = nil
    }
}

/// A modifier key that acts on a lone tap: pressed and released within the tap
/// limit, with no other key, click or modifier used while it was down. A key
/// with a typing guard also leaves taps close to typing alone: pressed within
/// `quiet` of the last key, or followed by a key within `settle` of its
/// release, it was a Shift brushed while typing rather than a tap.
struct TapKey {
    let keyCode: UInt16
    // Device-dependent modifier bit that tells the right-hand key from the left.
    let bit: UInt
    let flag: NSEvent.ModifierFlags
    let quiet: TimeInterval
    let settle: TimeInterval
    private var downAt: Date?
    private var chorded = false
    private var lastKeyAt: Date?
    // A tap waiting out `settle`.
    private var pending: Date?

    init(keyCode: UInt16, bit: UInt, flag: NSEvent.ModifierFlags,
         quiet: TimeInterval = 0, settle: TimeInterval = 0) {
        self.keyCode = keyCode
        self.bit = bit
        self.flag = flag
        self.quiet = quiet
        self.settle = settle
    }

    static let rightCommand = TapKey(keyCode: 54, bit: 0x10, flag: .command)
    static let rightShift = TapKey(keyCode: 60, bit: 0x04, flag: .shift, quiet: 1.5, settle: 0.5)

    /// A click while this key is down makes it part of a shortcut.
    mutating func chord() {
        if downAt != nil {
            chorded = true
        }
    }

    /// A key press: part of a shortcut while this key is down, and typing
    /// that a tap close to it belongs to.
    mutating func keyPressed(at now: Date) {
        lastKeyAt = max(lastKeyAt ?? now, now)
        if let tap = pending, now >= tap, now.timeIntervalSince(tap) < settle {
            pending = nil
        }
        chord()
    }

    /// Feeds one modifier change; true when it completes a lone tap. Modifiers
    /// in `allowed` may already be held without making the press a shortcut.
    mutating func update(keyCode: UInt16, flags: NSEvent.ModifierFlags, at now: Date,
                         allowed: NSEvent.ModifierFlags, limit: TimeInterval) -> Bool {
        guard keyCode == self.keyCode else {
            chord()
            return false
        }
        if flags.rawValue & bit != 0 {
            let others = NSEvent.ModifierFlags([.shift, .control, .option, .command, .function])
                .subtracting(flag)
                .subtracting(allowed)
            downAt = now
            chorded = !flags.intersection(others).isEmpty || typed(within: quiet, before: now)
            return false
        }
        guard let started = downAt else { return false }
        downAt = nil
        guard !chorded && now.timeIntervalSince(started) < limit else { return false }
        if settle > 0 {
            pending = now
        }
        return true
    }

    /// Called `settle` after a tap released at `tap`: true when it still
    /// stands, with no key pressed in between and no later tap replacing it.
    mutating func takeSettled(tap: Date) -> Bool {
        guard pending == tap else { return false }
        pending = nil
        return true
    }

    private func typed(within interval: TimeInterval, before now: Date) -> Bool {
        guard interval > 0, let last = lastKeyAt else { return false }
        return now.timeIntervalSince(last) < interval
    }

    /// When an event happened, from its own timestamp (seconds since the Mac
    /// started), so events delivered in a late burst keep their real spacing.
    static func time(of event: NSEvent) -> Date {
        Date(timeIntervalSinceNow: event.timestamp - ProcessInfo.processInfo.systemUptime)
    }
}

/// Right Option held is push-to-talk. A key or click in the first moment of the
/// hold makes it a shortcut instead (Option-letter types a character,
/// Option-click is a click) and drops the hold. After that the captain is
/// talking: a key or a click, such as one that opens a menu, leaves the
/// recording running, and releasing the key still sends it.
struct TalkKey {
    enum Action: Equatable {
        case begin, deliver, drop
    }

    static let keyCode: UInt16 = 61
    static let bit: UInt = 0x40
    let shortcutWindow: TimeInterval
    private var downAt: Date?

    init(shortcutWindow: TimeInterval = 0.3) {
        self.shortcutWindow = shortcutWindow
    }

    var isDown: Bool { downAt != nil }

    /// Feeds a change of Right Option's own flag.
    mutating func update(down: Bool, at now: Date) -> Action? {
        if down && downAt == nil {
            downAt = now
            return .begin
        }
        if !down && downAt != nil {
            downAt = nil
            return .deliver
        }
        return nil
    }

    /// A key press or click while the key may be down.
    mutating func chord(at now: Date) -> Action? {
        guard let started = downAt, now.timeIntervalSince(started) < shortcutWindow else { return nil }
        downAt = nil
        return .drop
    }
}

/// The configured side-specific modifiers toggle activation once per press.
struct ActivationChord {
    let bits: UInt
    private(set) var held = false

    init(bits: UInt = ActivationShortcut.defaultBits) {
        self.bits = bits
    }

    /// Suppress all hotkeys until every selected modifier has been released.
    mutating func update(flags: UInt) -> Bool {
        let down = flags & bits
        if down == 0 {
            held = false
        } else if down == bits && !held {
            held = true
            return true
        }
        return false
    }
}

/// Whether the floater is active: out of sight and ignoring every hotkey until
/// the chord, and back to that after `idleLimit` without use. A capture or a
/// message waiting to go counts as use, so it never switches off under them.
struct Activation {
    static let idleLimit: TimeInterval = 120

    private(set) var isActive = false
    private var lastUse = Date.distantPast

    /// The chord: the new state.
    mutating func toggle(at now: Date) -> Bool {
        isActive.toggle()
        lastUse = now
        return isActive
    }

    mutating func used(at now: Date) {
        guard isActive else { return }
        lastUse = max(lastUse, now)
    }

    /// Checks the idle time; true when it just switched the floater off. While
    /// `busy` the wait restarts, so it begins once the work has finished.
    mutating func tick(at now: Date, busy: Bool) -> Bool {
        guard isActive else { return false }
        if busy {
            lastUse = max(lastUse, now)
            return false
        }
        guard now.timeIntervalSince(lastUse) >= Self.idleLimit else { return false }
        isActive = false
        return true
    }
}

/// Global keys: Right Option held is push-to-talk to Firstmate, a lone tap of
/// Right Command starts or finishes dictation, and a lone tap of Right Shift
/// away from typing takes a screenshot, but only while `hotkeysEnabled`: the
/// configured activation modifiers together switch that on and off. Watching keys in other apps, and typing the dictated text
/// into them, both need the Accessibility permission. macOS ties that grant to
/// the app's signature; the permissions window guides grants and the keys-off
/// badge reopens it on demand.
@MainActor
final class HotkeyMonitor {
    var onTalkDown: (() -> Void)?
    var onTalkUp: (() -> Void)?
    var onTalkChord: (() -> Void)?
    var onEscape: (() -> Void)?
    var onDictateTap: (() -> Void)?
    var onShotTap: (() -> Void)?
    var onChord: (() -> Void)?
    var onTrustChanged: ((Bool) -> Void)?
    /// The hotkeys act only while this is on; the activation chord always does.
    var hotkeysEnabled = false

    private let tapLimit: TimeInterval = 0.5

    private var monitors: [Any] = []
    private var trustTimer: Timer?
    private var trusted = false
    private var talkKey = TalkKey()
    private var dictateKey = TapKey.rightCommand
    private var shotKey = TapKey.rightShift
    var settingsVisible: (() -> Bool)?
    var onShortcutChanged: ((ActivationShortcut) -> Void)?
    var activationShortcut = ActivationShortcut.load() {
        didSet {
            chord = ActivationChord(bits: activationShortcut.bits)
            onShortcutChanged?(activationShortcut)
            resetHotkeys()
        }
    }

    func resetHotkeys() {
        talkKey = TalkKey()
        dictateKey = TapKey.rightCommand
        shotKey = TapKey.rightShift
        onTalkChord?()
    }

    private var chord = ActivationChord(bits: ActivationShortcut.load().bits)

    func start() {
        checkTrust()
        trustTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkTrust() }
        }
    }

    private func checkTrust() {
        let now = AXIsProcessTrusted()
        guard now != trusted || (now && monitors.isEmpty) else { return }
        trusted = now
        onTrustChanged?(now)
        removeMonitors()
        if now {
            installMonitors()
        }
    }

    private func installMonitors() {
        let mask: NSEvent.EventTypeMask = [.flagsChanged, .keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown]
        if let global = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] event in
            MainActor.assumeIsolated { self?.handle(event) }
        }) {
            monitors.append(global)
        }
        if let local = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { [weak self] event in
            MainActor.assumeIsolated { self?.handle(event) }
            return event
        }) {
            monitors.append(local)
        }
    }

    private func removeMonitors() {
        for monitor in monitors {
            NSEvent.removeMonitor(monitor)
        }
        monitors.removeAll()
    }

    func handle(_ event: NSEvent) {
        if event.type == .keyDown && event.keyCode == 53 {
            talkKey = TalkKey()
            dictateKey = TapKey.rightCommand
            shotKey = TapKey.rightShift
            onEscape?()
            return
        }
        guard settingsVisible?() != true else { return }
        if event.type == .flagsChanged && chord.update(flags: event.modifierFlags.rawValue) {
            // Whatever the first keys of the chord began is dropped with it.
            resetHotkeys()
            onChord?()
            return
        }
        guard hotkeysEnabled, !chord.held else { return }
        let at = TapKey.time(of: event)
        if event.type != .flagsChanged {
            // A key or click while a hotkey is held makes it a shortcut, not a
            // hotkey: Option-letter types a character, Command-click opens a link.
            // Right Option is a shortcut only in the first moment of its hold,
            // and that cancels the capture without sending anything.
            if talkKey.chord(at: at) == .drop {
                onTalkChord?()
            }
            if event.type == .keyDown {
                dictateKey.keyPressed(at: at)
                shotKey.keyPressed(at: at)
            } else {
                dictateKey.chord()
                shotKey.chord()
            }
            return
        }
        if event.keyCode == TalkKey.keyCode {
            let down = event.modifierFlags.rawValue & TalkKey.bit != 0
            switch talkKey.update(down: down, at: at) {
            case .begin:
                onTalkDown?()
            case .deliver:
                onTalkUp?()
            case .drop, nil:
                break
            }
        }
        if dictateKey.update(keyCode: event.keyCode, flags: event.modifierFlags, at: at,
                             allowed: [], limit: tapLimit) {
            onDictateTap?()
        }
        // Screenshots taken while Right Option is held join that voice message.
        if shotKey.update(keyCode: event.keyCode, flags: event.modifierFlags, at: at,
                          allowed: talkKey.isDown ? .option : [], limit: tapLimit) {
            shotTapped(at: at)
        }
    }

    /// A Right Shift tap becomes a screenshot only once typing has not resumed
    /// right after it. While secure typing is on (a password field, or a
    /// terminal's Secure Keyboard Entry) macOS hides key presses from the
    /// floater, so a capital letter would read as a lone Shift tap: no shot then.
    private func shotTapped(at tap: Date) {
        guard !IsSecureEventInputEnabled() else { return }
        Timer.scheduledTimer(withTimeInterval: shotKey.settle, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.shotKey.takeSettled(tap: tap) else { return }
                self.onShotTap?()
            }
        }
    }
}

/// The Screen Recording permission screenshots need. Like Accessibility, macOS
/// ties it to the app's signature. It is checked every few seconds; the camera
/// badge opens the permissions window when a grant is missing.
@MainActor
final class ScreenAccess {
    var onChanged: ((Bool) -> Void)?

    private var timer: Timer?
    private var granted: Bool?

    func start() {
        check()
        timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.check() }
        }
    }

    private func check() {
        let now = CGPreflightScreenCaptureAccess()
        guard now != granted else { return }
        granted = now
        onChanged?(now)
    }

    /// screencapture's number (from 1, the main display first) for the display
    /// under the mouse pointer, or nil to let it take the main display.
    static func displayUnderPointer() -> Int? {
        guard let point = CGEvent(source: nil)?.location else { return nil }
        var hit: CGDirectDisplayID = 0
        var hits: UInt32 = 0
        guard CGGetDisplaysWithPoint(point, 1, &hit, &hits) == .success, hits > 0 else { return nil }
        var displays = [CGDirectDisplayID](repeating: 0, count: 16)
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(16, &displays, &count) == .success else { return nil }
        return displays.prefix(Int(count)).firstIndex(of: hit).map { $0 + 1 }
    }
}

/// Types text into whatever has the cursor by pasting it: the text goes on the
/// clipboard, Command-V goes to the focused app, and the clipboard the captain
/// had before is put back.
enum Paster {
    private static let concealed = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")
    private static let transient = NSPasteboard.PasteboardType("org.nspasteboard.TransientType")

    static func paste(_ text: String) -> Bool {
        let board = NSPasteboard.general
        let saved: [[(NSPasteboard.PasteboardType, Data)]] = (board.pasteboardItems ?? [])
            .filter { item in !item.types.contains(concealed) && !item.types.contains(transient) }
            .map { item in
                item.types.compactMap { type in item.data(forType: type).map { (type, $0) } }
            }
        board.clearContents()
        let item = NSPasteboardItem()
        item.setString(text, forType: .string)
        item.setData(Data(), forType: transient)
        board.writeObjects([item])
        guard AXIsProcessTrusted() else {
            // Without the permission no keystroke can be sent, so the text is
            // left on the clipboard for the captain to paste by hand.
            return false
        }
        let ours = board.changeCount
        let source = CGEventSource(stateID: .combinedSessionState)
        let vKey: CGKeyCode = 9
        let down = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: true)
        let up = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: false)
        down?.flags = .maskCommand
        up?.flags = .maskCommand
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            // Something else copied in the meantime: leave its contents alone.
            guard board.changeCount == ours else { return }
            board.clearContents()
            let items: [NSPasteboardItem] = saved.map { pairs in
                let item = NSPasteboardItem()
                for (type, data) in pairs {
                    item.setData(data, forType: type)
                }
                return item
            }
            if !items.isEmpty {
                board.writeObjects(items)
            }
        }
        return true
    }
}

/// The terminal device of the frontmost tab of a terminal app, asked of the app
/// itself over Apple Events (the Automation permission). Only apps whose answer
/// has been checked against the real app are listed; any other app has no tab
/// to report, so dictation there is only pasted.
enum FrontTab {
    enum Answer {
        case tty(String)
        case denied
        case none
    }

    private static let scripts: [String: String] = [
        "com.apple.Terminal": "tell application id \"com.apple.Terminal\" to get tty of selected tab of front window",
    ]

    static func tty(of app: NSRunningApplication) -> Answer {
        guard let id = app.bundleIdentifier, let script = scripts[id] else { return .none }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        proc.arguments = ["-e", "with timeout of 3 seconds", "-e", script, "-e", "end timeout"]
        let out = Pipe()
        let err = Pipe()
        proc.standardOutput = out
        proc.standardError = err
        do {
            try proc.run()
        } catch {
            return .none
        }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        let errText = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        proc.waitUntilExit()
        // -1743: the captain has not allowed the floater to control the app.
        if errText.contains("-1743") {
            return .denied
        }
        guard proc.terminationStatus == 0,
              let tty = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              tty.hasPrefix("/dev/") else {
            return .none
        }
        return .tty(tty)
    }
}

/// Screenshots waiting to go to Firstmate, and the talk-to-Firstmate words held
/// to go with them. They go as one message once `window` has passed since the
/// last shot or the end of the last talk, so each new one restarts the wait.
struct ShotStack {
    static let window: TimeInterval = 3

    private(set) var shots: [String] = []
    private(set) var inFlight = 0
    private(set) var transcript: String?
    private var lastActivity: Date?

    /// Shots taken and not yet sent, counting any still being captured.
    var count: Int { shots.count + inFlight }
    var isEmpty: Bool { transcript == nil && count == 0 }
    /// When the stack may go, unless a capture or a talk is still under way.
    var dueAt: Date { (lastActivity ?? .distantPast).addingTimeInterval(Self.window) }

    mutating func shotStarted(at now: Date) {
        inFlight += 1
        touch(now)
    }

    /// A capture finished: its image path, or nil when it failed.
    mutating func shotFinished(_ path: String?, at now: Date) {
        inFlight -= 1
        if let path {
            shots.append(path)
            touch(now)
        }
    }

    mutating func talkEnded(at now: Date) {
        touch(now)
    }

    /// Holds a transcript to go with the stack, after any words already held.
    /// False when nothing is stacked, so the words should go at once instead.
    mutating func hold(_ text: String) -> Bool {
        if let held = transcript {
            transcript = held + " " + text
            return true
        }
        guard count > 0 else { return false }
        transcript = text
        return true
    }

    func ready(at now: Date) -> Bool {
        !isEmpty && inFlight == 0 && now >= dueAt
    }

    /// Empties the stack, returning the message it held.
    mutating func take() -> (text: String?, images: [String]) {
        defer {
            transcript = nil
            shots = []
        }
        return (transcript, shots)
    }

    private mutating func touch(_ now: Date) {
        lastActivity = max(lastActivity ?? now, now)
    }
}

/// The spoken voice's level, as `bin/fm-speak.sh --volume` keeps it: a whole
/// percentage of the Mac's own output volume, where 100 is as loud as
/// everything else and anything above it is extra gain for the voice alone.
enum VoiceVolume {
    static let range = 0...200
    static let standard = 100

    static func clamp(_ level: Int) -> Int {
        min(max(level, range.lowerBound), range.upperBound)
    }

    /// Reads `--volume`'s output; anything else is not a level.
    static func parse(_ out: String?) -> Int? {
        guard let text = out?.trimmingCharacters(in: .whitespacesAndNewlines),
              let level = Int(text), range.contains(level) else {
            return nil
        }
        return level
    }
}

/// A small tip beside the pointer, shown once it has rested on a control for
/// `delay`. macOS's own tooltips need the app to be active, which this
/// floater, a non-activating panel, never is, so it draws its own.
@MainActor
final class TipWindow {
    static let shared = TipWindow()
    static let delay: TimeInterval = 0.7

    private let panel: NSPanel
    private let label: NSTextField
    private var generation = 0

    private init() {
        label = NSTextField(wrappingLabelWithString: "")
        label.font = .systemFont(ofSize: 11)
        label.textColor = .white
        label.preferredMaxLayoutWidth = 220
        let box = NSView()
        box.wantsLayer = true
        box.layer?.backgroundColor = NSColor(white: 0.1, alpha: 0.94).cgColor
        box.layer?.cornerRadius = 5
        box.addSubview(label)
        panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: true)
        panel.contentView = box
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    }

    /// The pointer entered (`inside`) or left a control whose tip is `text`.
    func hover(_ text: String, inside: Bool) {
        hide()
        guard inside else { return }
        let mine = generation
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.delay) { [self] in
            if generation == mine {
                show(text)
            }
        }
    }

    /// Hides the tip and cancels one still waiting: on a click, or when the
    /// floater goes out of sight.
    func hide() {
        generation += 1
        panel.orderOut(nil)
    }

    private func show(_ text: String) {
        label.stringValue = text
        let size = label.fittingSize
        let inset: CGFloat = 6
        label.frame = NSRect(x: inset, y: inset, width: size.width, height: size.height)
        let box = NSSize(width: size.width + inset * 2, height: size.height + inset * 2)
        let mouse = NSEvent.mouseLocation
        let visible = NSScreen.screens.first { $0.frame.contains(mouse) }?.visibleFrame
            ?? NSScreen.main?.visibleFrame ?? .zero
        var origin = NSPoint(x: mouse.x - box.width / 2, y: mouse.y - box.height - 18)
        if origin.y < visible.minY {
            origin.y = mouse.y + 18
        }
        origin.x = max(min(origin.x, visible.maxX - box.width), visible.minX)
        panel.setFrame(NSRect(origin: origin, size: box), display: true)
        panel.orderFrontRegardless()
    }
}

extension View {
    /// A tip after the pointer rests here (see TipWindow).
    func tip(_ text: String) -> some View {
        onHover { inside in
            TipWindow.shared.hover(text, inside: inside)
        }
    }
}

/// Moves the floater when dragged, shows the four-way move cursor and a tip.
/// Every other part of the floater also drags it; this is the spot that is
/// only for that, away from the buttons.
final class GripView: NSView {
    var mover: WindowMover?
    static let help = "Drag to move the floater"

    /// The system's four-way arrows symbol drawn as a cursor, black with a white
    /// edge so it shows on any background; the open hand if the symbol is missing.
    static let cursor: NSCursor = {
        let name = "arrow.up.and.down.and.arrow.left.and.right"
        let config = NSImage.SymbolConfiguration(pointSize: 18, weight: .bold)
        func tinted(_ color: NSColor) -> NSImage? {
            NSImage(systemSymbolName: name, accessibilityDescription: nil)?
                .withSymbolConfiguration(config.applying(.init(paletteColors: [color])))
        }
        guard let black = tinted(.black), let white = tinted(.white) else { return .openHand }
        let size = NSSize(width: black.size.width + 4, height: black.size.height + 4)
        let image = NSImage(size: size, flipped: false) { _ in
            let spot = NSRect(x: 2, y: 2, width: black.size.width, height: black.size.height)
            for (dx, dy) in [(-1.0, 0.0), (1, 0), (0, -1), (0, 1), (-1, -1), (1, 1), (-1, 1), (1, -1)] {
                white.draw(in: spot.offsetBy(dx: dx, dy: dy))
            }
            black.draw(in: spot)
            return true
        }
        return NSCursor(image: image, hotSpot: NSPoint(x: size.width / 2, y: size.height / 2))
    }()

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas {
            removeTrackingArea(area)
        }
        addTrackingArea(NSTrackingArea(
            rect: .zero, options: [.cursorUpdate, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self, userInfo: nil))
    }

    override func cursorUpdate(with event: NSEvent) {
        Self.cursor.set()
    }

    override func mouseEntered(with event: NSEvent) {
        Self.cursor.set()
        TipWindow.shared.hover(Self.help, inside: true)
    }

    override func mouseExited(with event: NSEvent) {
        NSCursor.arrow.set()
        TipWindow.shared.hover(Self.help, inside: false)
    }

    override func mouseDown(with event: NSEvent) {
        TipWindow.shared.hide()
    }

    override func mouseDragged(with event: NSEvent) {
        Self.cursor.set()
        mover?.drag()
    }

    override func mouseUp(with event: NSEvent) {
        mover?.end()
    }
}

struct GripCatcher: NSViewRepresentable {
    let mover: WindowMover

    func makeNSView(context: Context) -> GripView {
        GripView()
    }

    func updateNSView(_ view: GripView, context: Context) {
        view.mover = mover
    }
}

/// What a click on the speaker button does: a plain click mutes or unmutes,
/// while a right-click or a Control-click - the Mac's secondary click - opens
/// the voice-volume control.
enum SpeakerClick: Equatable {
    case mute
    case volume

    static func route(_ type: NSEvent.EventType, modifiers: NSEvent.ModifierFlags) -> SpeakerClick? {
        switch type {
        case .rightMouseDown:
            return .volume
        case .leftMouseDown:
            return modifiers.contains(.control) ? .volume : .mute
        default:
            return nil
        }
    }
}

/// Takes the speaker button's clicks in AppKit, because SwiftUI has no
/// secondary-click gesture: every click is routed through SpeakerClick, so a
/// Control-click opens the volume control instead of also muting.
final class SpeakerClickView: NSView {
    var onMute: (() -> Void)?
    var onVolume: (() -> Void)?
    var help = ""

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas {
            removeTrackingArea(area)
        }
        addTrackingArea(NSTrackingArea(
            rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self, userInfo: nil))
    }

    override func mouseEntered(with event: NSEvent) {
        TipWindow.shared.hover(help, inside: true)
    }

    override func mouseExited(with event: NSEvent) {
        TipWindow.shared.hover(help, inside: false)
    }

    override func mouseDown(with event: NSEvent) {
        dispatch(event)
    }

    override func rightMouseDown(with event: NSEvent) {
        dispatch(event)
    }

    private func dispatch(_ event: NSEvent) {
        switch SpeakerClick.route(event.type, modifiers: event.modifierFlags) {
        case .mute: onMute?()
        case .volume: onVolume?()
        case nil: break
        }
    }
}

struct SpeakerClickCatcher: NSViewRepresentable {
    let help: String
    let onMute: () -> Void
    let onVolume: () -> Void

    func makeNSView(context: Context) -> SpeakerClickView {
        let view = SpeakerClickView()
        updateNSView(view, context: context)
        return view
    }

    func updateNSView(_ view: SpeakerClickView, context: Context) {
        view.onMute = onMute
        view.onVolume = onVolume
        view.help = help
    }
}

/// One reply from the speak-out history, as `bin/fm-speak.sh --history` lists it.
struct RecentReply: Identifiable, Equatable {
    let id: Int
    let time: Date
    let text: String
}

@MainActor
final class FloaterModel: ObservableObject {
    enum Mode {
        case idle
        case starting
        case recording
        case busy
    }

    /// Where a capture's transcript goes: to Firstmate, or typed into the
    /// focused text box. Dictated text reaches Firstmate only when that text
    /// box is Firstmate's own chat.
    enum Purpose {
        case firstmate
        case dictate
    }

    @Published var mode: Mode = .idle {
        didSet { if mode != oldValue { refreshMeter() } }
    }
    @Published var microphoneLevel: Double = 0
    @Published var activationShortcut = ActivationShortcut.load()

    var talkHint: String { ActivationShortcut.glyphs(for: TalkKey.bit) }
    var dictationHint: String { ActivationShortcut.glyphs(for: TapKey.rightCommand.bit) }
    var shotHint: String { ActivationShortcut.glyphs(for: TapKey.rightShift.bit) }
    var shortcutHelp: String {
        "Talk: hold \(talkHint)\nDictate: tap \(dictationHint)\nShow / hide: \(activationShortcut.glyphs)"
    }
    @Published var purpose: Purpose = .firstmate
    @Published var status: String = ""
    @Published var voiceOutAvailable = false
    @Published var muted = false
    /// The spoken voice's level as a percentage of the system volume.
    @Published var voiceVolume = VoiceVolume.standard
    @Published var showingVolume = false
    @Published var recent: [RecentReply] = []
    @Published var showingRecent = false
    @Published var keysTrusted = false {
        didSet {
            if mode == .idle {
                status = idleStatus
            }
            refreshShown()
        }
    }
    @Published var screenTrusted = false
    /// Screenshots taken and not yet sent, counting any still being captured.
    @Published var shotCount = 0

    let repoRoot: String
    let fmHome: String
    /// Captures are recorded here, in the home's private state, so a recording
    /// outlives a floater that stops before sending it.
    let recordingDir: String
    // Echo-cancelled, so a reply playing on the speakers stays out of the
    // message while it keeps playing. See VoiceCapture.
    private let capture = VoiceCapture()
    private var recordURL: URL?
    private var pressStartedAt: Date?
    private var latched = false
    private var fromHotkey = false
    private let tapWindow: TimeInterval = 0.3
    private var muteTimer: Timer?
    private var meterTimer: Timer?
    private var meter = SpeechLevel()
    private var meterAt: TimeInterval = 0

    private func refreshMeter() {
        meterTimer?.invalidate()
        meterTimer = nil
        meter = SpeechLevel()
        microphoneLevel = 0
        guard mode == .recording else { return }
        meterAt = ProcessInfo.processInfo.systemUptime
        meterTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 45, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let now = ProcessInfo.processInfo.systemUptime
                self.microphoneLevel = self.meter.update(target: self.capture.microphoneLevel,
                                                         elapsed: now - self.meterAt)
                self.meterAt = now
            }
        }
    }

    private var activation = Activation()
    private var idleTimer: Timer?
    private var shown = false
    // Messages sent to Firstmate and not yet answered by the send script.
    private var deliveries = 0

    // Screenshots stack until the captain stops taking them, then go to
    // Firstmate as one message. A talk-to-Firstmate message recorded or
    // transcribed meanwhile takes them along instead, so the two arrive as one.
    private var stack = ShotStack()
    private var shotTimer: Timer?
    // The recordings of the words held in the stack, kept until they are sent.
    private var heldAudio: [URL] = []
    static let sendGrace: TimeInterval = 2
    private var cancelGeneration = 0
    private var pendingAudio: Set<URL> = []

    /// Escape is observation only; delivery already begun cannot be recalled.
    func cancelPending() {
        guard mode == .starting || mode == .recording || !pendingAudio.isEmpty || !stack.isEmpty else { return }
        cancelGeneration += 1
        shotTimer?.invalidate()
        shotTimer = nil
        let images = stack.shots
        stack = ShotStack()
        for path in images { try? FileManager.default.removeItem(atPath: path) }
        for url in pendingAudio.union(heldAudio) { try? FileManager.default.removeItem(at: url) }
        pendingAudio.removeAll()
        heldAudio = []
        cancelCapture()
        shotsChanged()
        flash("Cancelled")
    }

    private func waitToSend(generation: Int) async -> Bool {
        guard generation == cancelGeneration else { return false }
        status = "Sending in 2s - Esc to cancel"
        try? await Task.sleep(nanoseconds: UInt64(Self.sendGrace * 1_000_000_000))
        return generation == cancelGeneration
    }

    // Saved talk-to-Firstmate recordings waiting for an automatic retry, by
    // path, with the attempts each has had. See Recording.
    private(set) var retrying: [String: Int] = [:]

    init(repoRoot: String, fmHome: String) {
        self.repoRoot = repoRoot
        self.fmHome = fmHome
        recordingDir = (fmHome as NSString).appendingPathComponent("state/desk-voice/recording")
        muteTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.refreshMute()
                if self?.showingRecent == true {
                    self?.refreshRecent()
                }
            }
        }
    }

    // MARK: activation

    /// Called when the hotkeys are switched on or off.
    var onActiveChanged: ((Bool) -> Void)?
    /// Called when the floater should appear or disappear.
    var onShownChanged: ((Bool) -> Void)?

    /// Without the Accessibility permission the chord cannot be read, so the
    /// floater stays in sight for the captain to grant it.
    private var wantsShown: Bool {
        activation.isActive || !keysTrusted
    }

    func refreshShown() {
        let now = wantsShown
        guard now != shown else { return }
        shown = now
        onShownChanged?(now)
        if now {
            // The capture engine is built when the floater appears rather than
            // at launch, so the first words after the chord are still kept.
            DispatchQueue.main.async { self.warmMicrophone() }
        }
    }

    func toggleActive() {
        let active = activation.toggle(at: Date())
        if active {
            idleTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.idleTick() }
            }
        } else {
            deactivated()
        }
        onActiveChanged?(active)
        refreshShown()
    }

    /// Any use of the floater restarts the idle wait.
    func noteUse() {
        activation.used(at: Date())
    }

    private func idleTick() {
        guard activation.tick(at: Date(), busy: isBusy) else { return }
        deactivated()
        onActiveChanged?(false)
        refreshShown()
    }

    /// Something is still under way that the floater must not switch off under.
    private var isBusy: Bool {
        mode != .idle || !stack.isEmpty || deliveries > 0 || !retrying.isEmpty
    }

    private func deactivated() {
        idleTimer?.invalidate()
        idleTimer = nil
        if mode == .starting || mode == .recording {
            cancelCapture()
        }
    }

    static let savedRetrying = "Saved - retrying"
    static let micSilent = "Mic silent - not sent"

    var idleStatus: String {
        if stack.transcript != nil {
            return "Adding shots - Esc to cancel"
        }
        if shotCount > 0 {
            return shotCount == 1 ? "1 shot stacked - Esc to cancel" : "\(shotCount) shots stacked - Esc to cancel"
        }
        if !retrying.isEmpty {
            return Self.savedRetrying
        }
        return ""
    }

    /// Opens permission guidance from the keys-off badge.
    var onFixKeys: (() -> Void)?

    func fixKeys() {
        onFixKeys?()
    }

    /// Opens permission guidance from the camera badge.
    var onFixScreen: (() -> Void)?

    // MARK: screenshots (camera button, or a tap of the screenshot key)

    func shotButton() {
        if screenTrusted {
            takeShot()
        } else {
            onFixScreen?()
        }
    }

    /// Captures the display under the pointer and adds it to the stack.
    func takeShot() {
        noteUse()
        guard screenTrusted else {
            flash("Screen off - click !")
            return
        }
        let generation = cancelGeneration
        let display = ScreenAccess.displayUnderPointer()
        stack.shotStarted(at: Date())
        shotsChanged()
        Task.detached(priority: .userInitiated) { [repoRoot, fmHome] in
            let path = Self.shoot(repoRoot: repoRoot, fmHome: fmHome, display: display)
            await MainActor.run {
                guard generation == self.cancelGeneration else {
                    if let path { try? FileManager.default.removeItem(atPath: path) }
                    return
                }
                self.stack.shotFinished(path, at: Date())
                self.shotsChanged()
                if path == nil {
                    self.flash("Shot failed")
                }
                self.scheduleFlush()
            }
        }
    }

    /// A talk-to-Firstmate message is being recorded or transcribed, so stacked
    /// shots wait to go with it.
    private var voiceInProgress: Bool {
        purpose == .firstmate && mode != .idle
    }

    private func shotsChanged() {
        shotCount = stack.count
        if mode == .idle {
            status = idleStatus
        }
    }

    private func scheduleFlush() {
        shotTimer?.invalidate()
        let delay = max(0.1, stack.dueAt.timeIntervalSinceNow)
        shotTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.flushShots() }
        }
    }

    private func flushShots() {
        shotTimer = nil
        guard !stack.isEmpty else { return }
        if voiceInProgress || !stack.ready(at: Date()) {
            // A capture is still being written, the stack is waiting for a voice
            // message, or the window has not passed: look again shortly.
            shotTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated { self?.flushShots() }
            }
            return
        }
        let (text, images) = stack.take()
        let audio = heldAudio
        heldAudio = []
        shotsChanged()
        if mode == .idle {
            status = ""
        }
        deliveries += 1
        Task.detached(priority: .userInitiated) { [repoRoot, fmHome] in
            let outcome = Self.deliver(repoRoot: repoRoot, fmHome: fmHome, text: text, images: images)
            await MainActor.run {
                self.delivered(outcome, audio: audio)
            }
        }
    }

    /// After a talk-to-Firstmate message went (or failed to go): its recordings
    /// are removed once the words are delivered, and kept to be tried again
    /// when they were not.
    private func delivered(_ outcome: String?, audio: [URL], finishing: Bool = false) {
        deliveries -= 1
        noteUse()
        guard outcome != nil || audio.isEmpty else {
            for url in audio {
                keepForRetry(url, purpose: .firstmate, reason: "delivery failed", finishing: finishing)
            }
            return
        }
        for url in audio {
            try? FileManager.default.removeItem(at: url)
        }
        let status = outcome ?? "Deliver failed"
        if finishing {
            finish(status: status)
        } else {
            flash(status)
        }
    }

    /// A transcribed talk-to-Firstmate message: sent at once when nothing is
    /// stacked, otherwise held until the stack window closes and sent with the
    /// shots. The floater is free meanwhile, so another talk joins the same message.
    private func voiceTranscribed(_ text: String, audio: URL) {
        guard stack.hold(text) else {
            status = ""
            deliveries += 1
            Task.detached(priority: .userInitiated) { [repoRoot, fmHome] in
                let outcome = Self.deliver(repoRoot: repoRoot, fmHome: fmHome, text: text, images: [])
                await MainActor.run {
                    self.delivered(outcome, audio: [audio], finishing: true)
                }
            }
            return
        }
        heldAudio.append(audio)
        mode = .idle
        purpose = .firstmate
        status = idleStatus
        scheduleFlush()
    }

    // MARK: main button (talk to Firstmate)

    func toggle() {
        switch mode {
        case .idle:
            pressBegan()
            latched = true
        case .recording where purpose == .firstmate:
            stopAndDeliver()
        case .starting, .recording, .busy:
            break
        }
    }

    func pressBegan() {
        switch mode {
        case .idle:
            begin(.firstmate)
            pressStartedAt = Date()
        case .recording where latched && purpose == .firstmate && !fromHotkey:
            stopAndDeliver()
        case .starting, .recording, .busy:
            break
        }
    }

    func pressEnded() {
        guard purpose == .firstmate, !fromHotkey else { return }
        let quick = pressStartedAt.map { Date().timeIntervalSince($0) < tapWindow } ?? false
        pressStartedAt = nil
        switch mode {
        case .starting:
            if quick {
                latched = true
            } else {
                cancelCapture()
            }
        case .recording:
            if latched {
                break
            }
            if quick {
                latched = true
                status = ""
            } else {
                stopAndDeliver()
            }
        case .idle, .busy:
            break
        }
    }

    // MARK: Right Option (hold to talk to Firstmate)

    func hotkeyTalkBegan() {
        noteUse()
        guard mode == .idle else { return }
        begin(.firstmate)
        fromHotkey = true
        pressStartedAt = Date()
    }

    func hotkeyTalkEnded() {
        noteUse()
        guard fromHotkey else { return }
        let quick = pressStartedAt.map { Date().timeIntervalSince($0) < tapWindow } ?? true
        switch mode {
        case .starting:
            cancelCapture()
        case .recording:
            // A brush of the key is not a message: nothing is sent for it.
            if quick {
                cancelCapture()
            } else {
                stopAndDeliver()
            }
        case .idle, .busy:
            break
        }
    }

    func hotkeyTalkChorded() {
        guard fromHotkey, mode == .starting || mode == .recording else { return }
        cancelCapture()
    }

    // MARK: dictation (a tap of Right Command)

    func toggleDictation() {
        noteUse()
        switch mode {
        case .idle:
            begin(.dictate)
            latched = true
        case .starting where purpose == .dictate:
            cancelCapture()
        case .recording where purpose == .dictate:
            stopAndDeliver()
        case .starting, .recording, .busy:
            break
        }
    }

    // MARK: voice-out controls

    func stopTalking() {
        runSpeak(["--stop"]) { ok in ok ? "" : "Stop failed" }
    }

    func repeatLast() {
        guard !muted else {
            if mode == .idle {
                finish(status: "Voice muted")
            }
            return
        }
        runSpeak(["--repeat"]) { ok in ok ? "" : "Nothing to repeat" }
    }

    func toggleRecent() {
        showingRecent.toggle()
        if showingRecent {
            refreshRecent()
        }
    }

    /// Speaks one reply from the recent list again; stays silent while muted,
    /// exactly like Repeat.
    func replay(_ reply: RecentReply) {
        guard !muted else {
            if mode == .idle {
                finish(status: "Voice muted")
            }
            return
        }
        runSpeak(["--replay", String(reply.id)]) { ok in ok ? "" : "No longer kept" }
    }

    func refreshRecent() {
        Task.detached(priority: .userInitiated) { [repoRoot, fmHome] in
            let out = Self.speak(repoRoot: repoRoot, fmHome: fmHome, args: ["--history"]) ?? ""
            let replies = Self.parseHistory(out)
            await MainActor.run {
                if self.recent != replies {
                    self.recent = replies
                }
            }
        }
    }

    /// Reads `<number> TAB <epoch> TAB <text>` lines, newest first.
    nonisolated private static func parseHistory(_ out: String) -> [RecentReply] {
        out.split(separator: "\n").compactMap { line in
            let cols = line.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false)
            guard cols.count == 3, let id = Int(cols[0]), let epoch = TimeInterval(cols[1]) else {
                return nil
            }
            return RecentReply(id: id, time: Date(timeIntervalSince1970: epoch), text: String(cols[2]))
        }
    }

    func toggleMute() {
        let wasMuted = muted
        muted.toggle()
        runSpeak([wasMuted ? "--unmute" : "--mute"]) { ok in
            ok ? "" : "Mute failed"
        }
    }

    /// Opens or closes the voice-volume control (right-click or Control-click
    /// on the speaker button).
    func toggleVolume() {
        showingVolume.toggle()
        if showingVolume {
            refreshVolume()
        }
    }

    func refreshVolume() {
        Task.detached(priority: .userInitiated) { [repoRoot, fmHome] in
            let level = VoiceVolume.parse(Self.speak(repoRoot: repoRoot, fmHome: fmHome, args: ["--volume"]))
            await MainActor.run {
                if let level, self.voiceVolume != level {
                    self.voiceVolume = level
                }
            }
        }
    }

    /// Keeps the level for the next spoken line; the system volume is never
    /// touched.
    func setVoiceVolume(_ level: Int) {
        let level = VoiceVolume.clamp(level)
        voiceVolume = level
        runSpeak(["--volume", String(level)]) { ok in
            ok ? "" : "Volume not saved"
        }
    }

    func refreshMute() {
        Task.detached(priority: .utility) { [repoRoot, fmHome] in
            let available = Self.speak(repoRoot: repoRoot, fmHome: fmHome, args: ["--available"])?
                .trimmingCharacters(in: .whitespacesAndNewlines) == "available"
            let out = available ? Self.speak(repoRoot: repoRoot, fmHome: fmHome, args: ["--muted"]) : nil
            let muted = out?.trimmingCharacters(in: .whitespacesAndNewlines) == "muted"
            await MainActor.run {
                self.voiceOutAvailable = available
                self.muted = muted
                if !available {
                    self.showingVolume = false
                    self.showingRecent = false
                }
            }
        }
    }

    private func runSpeak(_ args: [String], status message: @escaping @Sendable (Bool) -> String) {
        Task.detached(priority: .userInitiated) { [repoRoot, fmHome] in
            let ok = Self.speak(repoRoot: repoRoot, fmHome: fmHome, args: args) != nil
            await MainActor.run {
                if self.mode == .idle {
                    self.finish(status: message(ok))
                }
                self.refreshMute()
                if self.showingRecent {
                    self.refreshRecent()
                }
            }
        }
    }

    // MARK: capture

    private func begin(_ purpose: Purpose) {
        self.purpose = purpose
        mode = .starting
        status = ""
        latched = false
        fromHotkey = false
        pressStartedAt = nil
        startRecording()
    }

    private func startRecording() {
        let generation = cancelGeneration
        Task {
            let ok = await requestMic()
            guard generation == cancelGeneration, mode == .starting else { return }
            guard ok else {
                finish(status: "Mic denied", for: 6)
                onFixKeys?()
                return
            }
            let url = URL(fileURLWithPath: recordingDir)
                .appendingPathComponent(Recording.fileName(purpose: purpose == .dictate ? "dictate" : "firstmate"))
            do {
                try FileManager.default.createDirectory(
                    atPath: recordingDir, withIntermediateDirectories: true,
                    attributes: [.posixPermissions: 0o700])
                try capture.start(writingTo: url)
            } catch {
                try? FileManager.default.removeItem(at: url)
                finish(status: "Record error", for: 6)
                return
            }
            guard mode == .starting else {
                capture.stop()
                try? FileManager.default.removeItem(at: url)
                return
            }
            recordURL = url
            mode = .recording
            status = ""
        }
    }

    private func cancelCapture() {
        latched = false
        fromHotkey = false
        pressStartedAt = nil
        capture.stop()
        if let url = recordURL {
            try? FileManager.default.removeItem(at: url)
        }
        recordURL = nil
        mode = .idle
        purpose = .firstmate
        status = idleStatus
    }

    private func stopAndDeliver() {
        let purpose = self.purpose
        if purpose == .firstmate {
            stack.talkEnded(at: Date())
        }
        latched = false
        fromHotkey = false
        pressStartedAt = nil
        guard let url = recordURL else {
            capture.stop()
            mode = .idle
            self.purpose = .firstmate
            status = idleStatus
            return
        }
        recordURL = nil
        pendingAudio.insert(url)
        let generation = cancelGeneration
        mode = .busy
        status = "Transcribing - Esc to cancel"
        // The last words are still arriving as the key comes up; the capture
        // keeps recording for a moment before the file is closed.
        capture.finish { [self] in
            guard generation == cancelGeneration else { return }
            transcribeAndDeliver(url, purpose: purpose)
        }
    }

    func transcribeAndDeliver(_ url: URL, purpose: Purpose) {
        pendingAudio.insert(url)
        let generation = cancelGeneration
        mode = .busy
        status = "Transcribing - Esc to cancel"
        Task.detached(priority: .userInitiated) { [repoRoot, fmHome] in
            // Near silence holds no words to send or to retry: say so at once
            // rather than saving it and retrying it.
            if Recording.isSilent(url) {
                try? FileManager.default.removeItem(at: url)
                await MainActor.run {
                    guard generation == self.cancelGeneration else { return }
                    self.pendingAudio.remove(url)
                    self.finish(status: Self.micSilent, for: 6)
                }
                return
            }
            let transcript = Self.transcribe(repoRoot: repoRoot, fmHome: fmHome, audio: url)
            let text = transcript?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !text.isEmpty else {
                // Nothing came back. The audio stays until its words are
                // delivered, unless it is too short to hold any.
                let failed = transcript == nil
                if Recording.keep(failed: failed, duration: Recording.duration(of: url)) {
                    await MainActor.run {
                        guard generation == self.cancelGeneration else { return }
                        self.pendingAudio.remove(url)
                        self.keepForRetry(url, purpose: purpose,
                                          reason: failed ? "transcription failed" : "no speech heard",
                                          finishing: true)
                    }
                } else {
                    try? FileManager.default.removeItem(at: url)
                    await MainActor.run {
                        guard generation == self.cancelGeneration else { return }
                        self.pendingAudio.remove(url)
                        self.finish(status: failed ? "Transcribe failed" : "No speech")
                    }
                }
                return
            }
            guard await self.waitToSend(generation: generation) else { return }
            let committed = await MainActor.run {
                guard generation == self.cancelGeneration else { return false }
                self.pendingAudio.remove(url)
                if purpose == .firstmate {
                    self.voiceTranscribed(text, audio: url)
                } else {
                    self.status = "Delivering…"
                }
                return true
            }
            guard committed, purpose == .dictate else { return }
            // Dictation is committed now; the audio is no longer needed.
            try? FileManager.default.removeItem(at: url)
            // Dictating into Firstmate's own chat sends it, as talking to
            // Firstmate does; anywhere else the text is only pasted.
            let front = await MainActor.run { NSWorkspace.shared.frontmostApplication }
            var denied = false
            if let front {
                switch FrontTab.tty(of: front) {
                case .tty(let tty):
                    if let sent = Self.sendIfInFront(repoRoot: repoRoot, fmHome: fmHome, text: text,
                                                     app: front.processIdentifier, tty: tty) {
                        await MainActor.run {
                            self.finish(status: sent)
                        }
                        return
                    }
                case .denied:
                    denied = true
                case .none:
                    break
                }
            }
            await MainActor.run { [denied] in
                let typed = Paster.paste(text)
                if !typed {
                    self.finish(status: "Copied - press ⌘V")
                } else {
                    self.finish(status: denied ? "Typed, not sent - allow Terminal" : "Typed")
                }
            }
        }
    }

    // MARK: recordings kept until delivered

    /// Saves a recording whose words did not reach their destination to the
    /// home's unsent folder and, for talk to Firstmate, retries it on
    /// Recording.retryDelays. A dictation stays saved for a manual retry with
    /// `bin/fm-desk-voice.sh retry`. Should the save itself fail, the audio
    /// stays in the recording folder, where the next launch finds it.
    private func keepForRetry(_ url: URL, purpose: Purpose, reason: String, finishing: Bool) {
        let name = purpose == .dictate ? "dictate" : "firstmate"
        let retries = purpose == .firstmate
        let message = retries ? Self.savedRetrying : "Saved, not sent"
        if finishing {
            finish(status: message, for: 6)
        } else {
            flash(message, for: 6)
        }
        Task.detached(priority: .userInitiated) { [repoRoot, fmHome] in
            let saved = Self.keep(repoRoot: repoRoot, fmHome: fmHome, audio: url, purpose: name, reason: reason)
            await MainActor.run {
                guard let saved, retries else {
                    self.flash("Saved, not sent", for: 6)
                    return
                }
                self.scheduleRetry(saved, attempts: 1)
            }
        }
    }

    private func scheduleRetry(_ path: String, attempts: Int, after wait: TimeInterval? = nil) {
        guard let delay = wait ?? Recording.retryDelay(afterAttempts: attempts) else {
            retrying[path] = nil
            if mode == .idle {
                status = idleStatus
            }
            flash("Saved, not sent", for: 6)
            return
        }
        retrying[path] = attempts
        if mode == .idle {
            status = idleStatus
        }
        Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.retry(path) }
        }
    }

    private func retry(_ path: String) {
        let attempts = retrying[path] ?? 1
        Task.detached(priority: .utility) { [repoRoot, fmHome] in
            let result = Self.retryRecording(repoRoot: repoRoot, fmHome: fmHome, path: path)
            await MainActor.run {
                switch result {
                case .delivered(let status):
                    self.retried(path, status: status)
                case .unsent(let made):
                    self.scheduleRetry(path, attempts: made)
                case .busy:
                    self.scheduleRetry(path, attempts: attempts, after: Recording.busyDelay)
                case .gone:
                    self.retried(path, status: nil)
                case nil:
                    self.scheduleRetry(path, attempts: attempts + 1)
                }
            }
        }
    }

    private func retried(_ path: String, status message: String?) {
        retrying[path] = nil
        if mode == .idle {
            status = idleStatus
        }
        if let message {
            flash(message, for: 6)
        }
    }

    /// At launch: saves any recording a stopped floater left in the recording
    /// folder, then resumes the automatic retries of saved talk-to-Firstmate
    /// recordings that still have some left.
    func recoverRecordings() {
        Task.detached(priority: .utility) { [repoRoot, fmHome, recordingDir] in
            let names = (try? FileManager.default.contentsOfDirectory(atPath: recordingDir)) ?? []
            for name in names where name.hasSuffix(".wav") {
                let url = URL(fileURLWithPath: recordingDir).appendingPathComponent(name)
                let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
                // A file still being written belongs to a capture under way.
                if let modified = attributes?[.modificationDate] as? Date,
                   Date().timeIntervalSince(modified) < 10 {
                    continue
                }
                if !Recording.isSilent(url),
                   Recording.keep(failed: true, duration: Recording.duration(of: url)) {
                    _ = Self.keep(repoRoot: repoRoot, fmHome: fmHome, audio: url,
                                  purpose: Recording.purpose(ofFileName: name),
                                  reason: "the floater stopped before it was sent")
                } else {
                    try? FileManager.default.removeItem(at: url)
                }
            }
            let listing = Self.run(bin: (repoRoot as NSString).appendingPathComponent("bin/fm-desk-voice.sh"),
                                   args: ["recordings"], env: ["FM_HOME": fmHome]) ?? ""
            let pending: [(String, Int)] = listing.split(separator: "\n").compactMap { line in
                let cols = line.split(separator: "\t", omittingEmptySubsequences: false)
                guard cols.count >= 3, cols[1] == "firstmate", let attempts = Int(cols[2]),
                      Recording.retryDelay(afterAttempts: attempts) != nil else { return nil }
                return (String(cols[0]), attempts)
            }
            await MainActor.run {
                for (path, attempts) in pending where self.retrying[path] == nil {
                    self.scheduleRetry(path, attempts: attempts)
                }
            }
        }
    }

    private func finish(status: String, for seconds: TimeInterval? = nil) {
        mode = .idle
        purpose = .firstmate
        flash(status, for: seconds)
    }

    /// Shows a short outcome on the status line while nothing is being captured.
    /// A message saved rather than sent stays up longer, so it is not missed.
    private func flash(_ message: String, for seconds: TimeInterval? = nil) {
        guard mode == .idle else { return }
        status = message
        let shown = seconds ?? (message == SendOutcome.savedForFirstmate ? 6 : 2)
        DispatchQueue.main.asyncAfter(deadline: .now() + shown) {
            if self.mode == .idle && self.status == message {
                self.status = self.idleStatus
            }
        }
    }

    /// Builds the capture engine ahead of the first press when the microphone
    /// is already allowed, so the first words of the first message are
    /// recorded too. See VoiceCapture.
    func warmMicrophone() {
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else { return }
        try? capture.warm()
    }

    private func requestMic() async -> Bool {
        await withCheckedContinuation { cont in
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                cont.resume(returning: granted)
            }
        }
    }

    nonisolated private static func transcribe(repoRoot: String, fmHome: String, audio: URL) -> String? {
        let bin = (repoRoot as NSString).appendingPathComponent("bin/fm-deepgram-stt.sh")
        return run(bin: bin, args: [audio.path], env: ["FM_HOME": fmHome])
    }

    /// Sends one message to Firstmate: the transcript, the screenshots, or both,
    /// and returns the status to show. It is typed into firstmate's own chat;
    /// bin/fm-desk-voice.sh falls back to its mailbox when that pane cannot be
    /// reached.
    nonisolated private static func deliver(repoRoot: String, fmHome: String, text: String?, images: [String]) -> String? {
        let bin = (repoRoot as NSString).appendingPathComponent("bin/fm-desk-voice.sh")
        var args = ["send", "--source", "desk-floater"]
        for image in images {
            args += ["--image", image]
        }
        args.append("--")
        if let text {
            args.append(text)
        }
        return SendOutcome.status(run(bin: bin, args: args, env: ["FM_HOME": fmHome]))
    }

    /// Sends dictated text to Firstmate when the text box with the cursor is
    /// Firstmate's own chat: the frontmost tab <tty> of app <app> shows it.
    /// Returns the status to show, or nil when the chat is not in front (or
    /// the check failed), so the caller pastes the text instead.
    nonisolated private static func sendIfInFront(repoRoot: String, fmHome: String, text: String,
                                                  app: pid_t, tty: String) -> String? {
        let bin = (repoRoot as NSString).appendingPathComponent("bin/fm-desk-voice.sh")
        let args = ["send", "--front-app", String(app), "--front-tty", tty,
                    "--source", "desk-floater-dictation", "--", text]
        guard let out = run(bin: bin, args: args, env: ["FM_HOME": fmHome]),
              !out.hasPrefix("not-in-front") else {
            return nil
        }
        return SendOutcome.status(out)
    }

    /// Saves a recording to the home's unsent folder; the saved path, or nil.
    nonisolated private static func keep(repoRoot: String, fmHome: String, audio: URL,
                                         purpose: String, reason: String) -> String? {
        let bin = (repoRoot as NSString).appendingPathComponent("bin/fm-desk-voice.sh")
        let path = run(bin: bin, args: ["keep", "--purpose", purpose, "--reason", reason, "--", audio.path],
                       env: ["FM_HOME": fmHome])?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return path.isEmpty ? nil : path
    }

    /// Transcribes and delivers one saved recording again.
    nonisolated private static func retryRecording(repoRoot: String, fmHome: String, path: String) -> RetryResult? {
        let bin = (repoRoot as NSString).appendingPathComponent("bin/fm-desk-voice.sh")
        return run(bin: bin, args: ["retry", path], env: ["FM_HOME": fmHome])
            .flatMap { RetryResult.parse($0) }
    }

    /// Captures one display to this home's screenshot folder; nil on failure.
    nonisolated private static func shoot(repoRoot: String, fmHome: String, display: Int?) -> String? {
        let bin = (repoRoot as NSString).appendingPathComponent("bin/fm-desk-voice.sh")
        var args = ["shot"]
        if let display {
            args += ["--display", String(display)]
        }
        let path = run(bin: bin, args: args, env: ["FM_HOME": fmHome])?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return path.isEmpty ? nil : path
    }

    nonisolated private static func speak(repoRoot: String, fmHome: String, args: [String]) -> String? {
        let bin = (repoRoot as NSString).appendingPathComponent("bin/fm-speak.sh")
        return run(bin: bin, args: args, env: ["FM_HOME": fmHome])
    }

    nonisolated private static func run(bin: String, args: [String], env: [String: String]) -> String? {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: bin)
        proc.arguments = args
        var environment = ProcessInfo.processInfo.environment
        // Finder's PATH omits Homebrew and user-installed Firstmate helpers.
        environment["PATH"] = (environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin")
            + ":/opt/homebrew/bin:/usr/local/bin:" + NSHomeDirectory() + "/.local/bin"
        for (k, v) in env { environment[k] = v }
        proc.environment = environment
        let out = Pipe()
        proc.standardOutput = out
        proc.standardError = FileHandle.standardError
        do {
            try proc.run()
        } catch {
            return nil
        }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        guard proc.terminationStatus == 0 else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

enum FloaterGeneration {
    static let current = 2

    static func roman(_ number: Int) -> String {
        guard number > 0 else { return "" }
        var remaining = number
        var result = ""
        for (value, symbol) in [(1000, "M"), (900, "CM"), (500, "D"), (400, "CD"),
                                (100, "C"), (90, "XC"), (50, "L"), (40, "XL"),
                                (10, "X"), (9, "IX"), (5, "V"), (4, "IV"), (1, "I")] {
            result += String(repeating: symbol, count: remaining / value)
            remaining %= value
        }
        return result
    }
}

struct GenerationMark: View {
    let beta: Bool
    let hovered: Bool

    var body: some View {
        HStack(spacing: 2) {
            Text("β")
                .frame(width: 7, alignment: .trailing)
                .opacity(beta ? 1 : 0)
            Text(FloaterGeneration.roman(FloaterGeneration.current))
                .opacity(beta || hovered ? 1 : 0)
        }
        .font(.system(size: 11, weight: .semibold))
        .foregroundStyle(.white.opacity(0.75))
        .frame(height: 14)
        .animation(.easeInOut(duration: 0.15), value: hovered)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(beta ? "Beta, " : "")generation \(FloaterGeneration.current)")
        .accessibilityHidden(!beta && !hovered)
    }
}

struct WritingIndicator: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var started = Date()

    struct Frame: Equatable {
        var lines: [Double]
        var tip: CGPoint
        var opacity: Double
    }

    static let duration = 4.8

    static func frame(at elapsed: TimeInterval, reduceMotion: Bool) -> Frame {
        if reduceMotion { return Frame(lines: [0, 0, 0], tip: CGPoint(x: 10, y: 16), opacity: 1) }
        let time = max(0, elapsed).truncatingRemainder(dividingBy: duration)
        func ease(_ value: Double) -> Double {
            let x = min(1, max(0, value))
            return x * x * (3 - 2 * x)
        }
        let lines = (0..<3).map { min(1, max(0, (time - 0.65 - Double($0) * 1.07) / 0.85)) }
        var tip = CGPoint(x: 3, y: 9 - 5 * (1 - ease(time / 0.65)))
        for row in 0..<3 where time >= 0.65 + Double(row) * 1.07 {
            let progress = lines[row]
            tip = scribblePoint(progress, row: row)
            if row < 2 && progress == 1 {
                let move = ease((time - 0.65 - Double(row) * 1.07 - 0.85) / 0.22)
                let next = scribblePoint(0, row: row + 1)
                tip.x += (next.x - tip.x) * move
                tip.y += (next.y - tip.y) * move - sin(move * .pi) * 1.2
            }
        }
        tip.y -= 0.3 * sin(time * 5)
        return Frame(lines: lines, tip: tip,
                     opacity: ease(time / 0.4) * (1 - ease((time - 3.95) / 0.6)))
    }

    static func scribblePoint(_ progress: Double, row: Int) -> CGPoint {
        CGPoint(x: 3 + progress * (row == 2 ? 10 : 14),
                y: 9 + Double(row) * 4 + sin(progress * 9 * .pi) * 0.65
                    + sin(progress * 17 * .pi) * 0.25)
    }

    static func drawing(_ frame: Frame) -> some View {
        Canvas { context, _ in
            for row in 0..<3 where frame.lines[row] > 0 {
                var line = Path()
                line.move(to: scribblePoint(0, row: row))
                let steps = max(1, Int(ceil(frame.lines[row] * 60)))
                for step in 1...steps {
                    line.addLine(to: scribblePoint(frame.lines[row] * Double(step) / Double(steps), row: row))
                }
                context.stroke(line, with: .color(.white.opacity(0.55)),
                               style: StrokeStyle(lineWidth: 0.85, lineCap: .round, lineJoin: .round))
            }
            // A tiny hand-drawn nib: its point stays just above the fresh ink.
            var pen = Path()
            pen.move(to: frame.tip)
            pen.addLine(to: CGPoint(x: frame.tip.x + 2, y: frame.tip.y - 4))
            pen.addLine(to: CGPoint(x: frame.tip.x + 7, y: frame.tip.y - 11))
            pen.addQuadCurve(to: CGPoint(x: frame.tip.x + 9, y: frame.tip.y - 9),
                             control: CGPoint(x: frame.tip.x + 10, y: frame.tip.y - 12))
            pen.addLine(to: CGPoint(x: frame.tip.x + 4, y: frame.tip.y - 2))
            pen.closeSubpath()
            context.stroke(pen, with: .color(.white.opacity(0.95)),
                           style: StrokeStyle(lineWidth: 1.15, lineCap: .round, lineJoin: .round))
        }
        .frame(width: 26, height: 26)
        .clipped()
        .opacity(frame.opacity)
    }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 24, paused: reduceMotion)) { context in
            Self.drawing(Self.frame(at: context.date.timeIntervalSince(started), reduceMotion: reduceMotion))
        }
        .accessibilityLabel("Transcribing")
    }
}

struct FloaterView: View {
    @ObservedObject var model: FloaterModel
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @AppStorage(AmbientSettings.defaultsKey) private var animatedBackground = true
    let mover: WindowMover
    @State private var hovering = false

    private let mainSize: CGFloat = 36
    private let controlSize: CGFloat = 20
    private let controlSpacing: CGFloat = 4
    private let rowSpacing: CGFloat = 6
    private let arrowWidth: CGFloat = 12
    private let gripSize: CGFloat = 14

    static func isBeta(bundleIdentifier: String?) -> Bool {
        bundleIdentifier == "com.firstmate.desk-floater.beta"
    }

    /// The move handle in the bottom-right corner: in the status line's row,
    /// or in a row of its own below an open list.
    private var grip: some View {
        Image(systemName: "arrow.up.and.down.and.arrow.left.and.right")
            .font(.system(size: 8, weight: .bold))
            .foregroundStyle(.white.opacity(0.6))
            .frame(width: gripSize, height: gripSize)
            .overlay { GripCatcher(mover: mover) }
            .accessibilityLabel(GripView.help + ". " + model.shortcutHelp)
    }

    private var rowWidth: CGFloat {
        model.voiceOutAvailable
            ? mainSize + rowSpacing + controlSize * 2 + controlSpacing + rowSpacing + arrowWidth
            : mainSize + rowSpacing + controlSize
    }

    var body: some View {
        VStack(alignment: .trailing, spacing: 4) {
            HStack(spacing: rowSpacing) {
                mainButton
                if model.voiceOutAvailable {
                    VStack(spacing: controlSpacing) {
                        HStack(spacing: controlSpacing) {
                            control("stop.fill", help: "Stop the spoken reply", action: model.stopTalking)
                            control("arrow.counterclockwise", help: "Repeat the last spoken reply", action: model.repeatLast)
                        }
                        HStack(spacing: controlSpacing) {
                            speakerButton
                            shotButton
                        }
                    }
                    recentToggle
                } else {
                    shotButton
                }
            }
            if model.voiceOutAvailable && model.showingVolume {
                volumeControl
            }
            if model.voiceOutAvailable && model.showingRecent {
                recentList
            }
            HStack(spacing: 0) {
                GenerationMark(beta: Self.isBeta(bundleIdentifier: Bundle.main.bundleIdentifier), hovered: hovering)
                Spacer(minLength: 0)
                grip
            }
            .frame(maxWidth: .infinity)
        }
        .padding(6)
        .background {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(.black.opacity(reduceTransparency ? 1 : 0.55))
                .overlay {
                    if animatedBackground && !reduceTransparency {
                        GeometryReader { proxy in
                            let rowHeight = model.voiceOutAvailable ? max(mainSize, controlSize * 2 + controlSpacing) : mainSize
                            AmbientBackground(active: model.mode == .starting || model.mode == .recording,
                                              center: CGPoint(x: proxy.size.width - 6 - rowWidth + mainSize / 2,
                                                              y: proxy.size.height - 6 - rowHeight / 2))
                        }
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                    }
                }
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 1)
                        .onChanged { _ in mover.drag() }
                        .onEnded { _ in mover.end() }
                )
        }
        .fixedSize()
        .onHover { hovering = $0 }
        .onGeometryChange(for: CGSize.self) { proxy in
            proxy.size
        } action: { size in
            mover.fit(size)
        }
    }

    /// Mutes on a click; a right-click or Control-click opens the voice-volume
    /// control below the row.
    private var speakerButton: some View {
        let help = model.muted
            ? "Unmute voice - right-click for volume"
            : "Mute voice - right-click for volume"
        return control(
            model.muted ? "speaker.slash.fill" : "speaker.wave.2.fill",
            help: help,
            tint: model.muted ? Color(red: 0.85, green: 0.45, blue: 0.10) : nil,
            action: model.toggleMute
        )
        .overlay {
            SpeakerClickCatcher(help: help, onMute: model.toggleMute, onVolume: model.toggleVolume)
        }
        .accessibilityAction(named: "Voice volume", model.toggleVolume)
    }

    /// The voice's own level beside everything else on the Mac: 100% is the
    /// system volume, lower is quieter than other audio, higher is louder.
    private var volumeControl: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 5) {
                Image(systemName: "speaker.wave.1.fill")
                    .font(.system(size: 8))
                Slider(
                    value: Binding(
                        get: { Double(model.voiceVolume) },
                        set: { model.voiceVolume = VoiceVolume.clamp(Int($0.rounded())) }
                    ),
                    in: Double(VoiceVolume.range.lowerBound)...Double(VoiceVolume.range.upperBound),
                    step: 5
                ) { editing in
                    if !editing {
                        model.setVoiceVolume(model.voiceVolume)
                    }
                }
                .controlSize(.mini)
                .accessibilityLabel("Voice volume")
                .accessibilityValue("\(model.voiceVolume)%")
                .tip("\(model.voiceVolume)% of system volume")
                if model.voiceVolume != VoiceVolume.standard {
                    Button { model.setVoiceVolume(VoiceVolume.standard) } label: {
                        Image(systemName: "arrow.counterclockwise")
                            .font(.system(size: 9, weight: .semibold))
                    }
                    .buttonStyle(.plain)
                    .tip("Back to the system volume (100%)")
                    .accessibilityLabel("Reset voice volume")
                }
            }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 5)
        .padding(.vertical, 3)
        .background(RoundedRectangle(cornerRadius: 5).fill(Color.white.opacity(0.12)))
        .frame(width: 180)
    }

    /// The dropdown arrow to the right of the controls, centred beside them and
    /// only as tall as one control: opens the recent replies.
    private var recentToggle: some View {
        Button(action: model.toggleRecent) {
            Image(systemName: model.showingRecent ? "chevron.up" : "chevron.down")
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: arrowWidth, height: controlSize + controlSpacing)
                .background(Capsule().fill(model.showingRecent ? Color.white.opacity(0.35) : Color.white.opacity(0.22)))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .tip(model.showingRecent ? "Hide recent replies" : "Recent replies - click one to hear it again")
        .accessibilityLabel(model.showingRecent ? "Hide recent replies" : "Show recent replies")
    }

    private var recentList: some View {
        VStack(alignment: .leading, spacing: 2) {
            if model.recent.isEmpty {
                Image(systemName: "speaker.slash")
                    .font(.system(size: 9))
                    .tip("Nothing spoken yet")
                    .accessibilityLabel("Nothing spoken yet")
                    .foregroundStyle(.white.opacity(0.7))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 2)
            }
            ForEach(model.recent) { reply in
                Button {
                    model.replay(reply)
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "play.fill")
                            .font(.system(size: 7))
                        Spacer(minLength: 0)
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 3)
                    .background(RoundedRectangle(cornerRadius: 5).fill(Color.white.opacity(0.12)))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .tip(Self.timeLabel(reply.time) + " - " + reply.text)
                .accessibilityLabel("Hear again: \(reply.text)")
            }
        }
        .frame(width: 230)
    }

    private static let clock: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f
    }()

    private static let dayClock: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "d MMM HH:mm"
        return f
    }()

    /// Today's replies show the time; older ones the day as well.
    private static func timeLabel(_ time: Date) -> String {
        Calendar.current.isDateInToday(time) ? clock.string(from: time) : dayClock.string(from: time)
    }

    private var badgeOrange: Color { Color(red: 0.90, green: 0.50, blue: 0.10) }

    /// Takes a screenshot of the display under the pointer. Queued shots have
    /// a stack badge; without Screen Recording it shows an exclamation icon and
    /// clicking asks macOS again.
    private var shotButton: some View {
        control(
            "camera.fill",
            help: model.screenTrusted
                ? "Take a screenshot for Firstmate - shots close together go as one message"
                : "Screenshots are off: macOS has not allowed this build Screen Recording. Click to allow it.",
            shortcut: model.shotHint,
            action: model.shotButton
        )
        .overlay(alignment: .topTrailing) {
            if !model.screenTrusted {
                badge("exclamationmark", fill: badgeOrange)
                    .offset(x: 4, y: -4)
                    .allowsHitTesting(false)
            } else if model.shotCount > 0 {
                badge("square.stack.fill", fill: Color(red: 0.12, green: 0.45, blue: 0.85))
                    .offset(x: 4, y: -4)
                    .allowsHitTesting(false)
            }
        }
    }

    private func badge(_ symbol: String, fill: Color) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 8, weight: .heavy))
            .foregroundStyle(.white)
            .frame(minWidth: 14, minHeight: 14)
            .background(Capsule().fill(fill))
    }

    private var dictateColor: Color { Color(red: 0.55, green: 0.30, blue: 0.85) }

    private var mainButton: some View {
        ZStack {
            Circle()
                .fill(color)
            if model.mode == .recording {
                speechBars
            } else if model.mode == .busy {
                WritingIndicator()
                    .transition(.opacity.animation(.easeOut(duration: 0.2)))
                    .zIndex(1)
            } else {
                shortcutIcon(icon, shortcut: mainHint, size: 15, weight: .semibold)
            }
        }
        .frame(width: mainSize, height: mainSize)
        .contentShape(Circle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in model.pressBegan() }
                .onEnded { _ in model.pressEnded() }
        )
        .onTapGesture(count: 2) {
            model.toggle()
        }
        .tip("Talk to Firstmate - hold, or click to start and click again to send\n" + model.shortcutHelp + "\n" + model.status)
        .accessibilityLabel(model.mode == .recording ? "Recording" : model.mode == .busy ? "Transcribing" : "Desk push to talk")
        .accessibilityValue(model.shortcutHelp + "\n" + model.status)
        .overlay(alignment: .topTrailing) {
            if !model.keysTrusted {
                keysOffBadge
                    .offset(x: 4, y: -4)
            }
        }
    }

    private var mainHint: String {
        model.purpose == .dictate && model.mode != .idle ? model.dictationHint : model.talkHint
    }

    /// Only shortcut-bearing icons fade; live recording bars never fade or get covered.
    private func shortcutIcon(_ symbol: String, shortcut: String? = nil, size: CGFloat, weight: Font.Weight = .bold) -> some View {
        ZStack {
            Image(systemName: symbol)
                .font(.system(size: size, weight: weight))
                .opacity(hovering && shortcut != nil ? 0.15 : 1)
            if let shortcut {
                Text(shortcut)
                    .font(.system(size: size + 1, weight: .bold))
                    .fixedSize()
                    .opacity(hovering ? 1 : 0)
                    .accessibilityHidden(true)
            }
        }
        .foregroundStyle(.white)
        .animation(.easeInOut(duration: 0.15), value: hovering)
    }

    private var speechBars: some View {
        HStack(spacing: 2) {
            ForEach(Array([0.45, 0.8, 1.0, 0.7, 0.4].enumerated()), id: \.offset) { _, scale in
                Capsule().fill(.white)
                    .frame(width: 2.5, height: 3 + 16 * scale * model.microphoneLevel)
            }
        }
        .frame(width: 22, height: 22)
        .accessibilityHidden(true)
    }

    /// Shown while macOS has not granted this build Accessibility, so the
    /// hotkeys and dictation paste are off; clicking it asks again.
    private var keysOffBadge: some View {
        Button(action: model.fixKeys) {
            Image(systemName: "exclamationmark")
                .font(.system(size: 8, weight: .heavy))
                .foregroundStyle(.white)
                .frame(width: 14, height: 14)
                .background(Circle().fill(badgeOrange))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .tip("Hotkeys are off: macOS has not allowed this build Accessibility. Click to allow it.")
        .accessibilityLabel("Hotkeys off - allow Accessibility")
    }

    private func control(_ symbol: String, help: String, tint: Color? = nil, shortcut: String? = nil, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            shortcutIcon(symbol, shortcut: shortcut, size: 9)
                .frame(width: controlSize, height: controlSize)
                .background(Circle().fill(tint ?? Color.white.opacity(0.22)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .tip(help)
        .accessibilityLabel(help)
    }

    private var color: Color {
        if model.purpose == .dictate && model.mode != .idle {
            return dictateColor
        }
        switch model.mode {
        case .idle: return Color(red: 0.12, green: 0.45, blue: 0.85)
        case .starting: return Color(red: 0.85, green: 0.55, blue: 0.20)
        case .recording: return Color(red: 0.85, green: 0.20, blue: 0.20)
        case .busy: return Color(red: 0.35, green: 0.35, blue: 0.40)
        }
    }

    private var icon: String {
        if model.purpose == .dictate && model.mode == .recording {
            return "text.cursor"
        }
        switch model.mode {
        case .idle: return "mic.fill"
        case .starting: return "mic"
        case .recording: return "waveform"
        case .busy: return "pencil.tip"
        }
    }
}

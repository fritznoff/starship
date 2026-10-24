import AppKit
import XCTest
@testable import DeskFloater

final class ActivationTests: XCTestCase {
    /// Opt in with a bundle made by fm-desk-floater.sh --build-only.
    /// Launches the real app in a temporary home; macOS may ask for Accessibility.
    @MainActor
    func testSettingsWindowOpensOnlyOnReopen() throws {
        guard let path = ProcessInfo.processInfo.environment["FM_DESK_FLOATER_TEST_APP"] else {
            throw XCTSkip("Set FM_DESK_FLOATER_TEST_APP to DeskFloater-build-only.app for the live window regression")
        }
        let url = URL(fileURLWithPath: path).standardizedFileURL
        let bundle = try XCTUnwrap(Bundle(url: url))
        XCTAssertEqual(bundle.bundleIdentifier, "com.firstmate.desk-floater.build-only")
        guard bundle.bundleIdentifier == "com.firstmate.desk-floater.build-only" else { return }
        let root = url.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }

        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        configuration.environment = ["FM_HOME": home.path, "FM_DESK_FLOATER_ROOT": root.path]
        let launched = expectation(description: "isolated floater launched")
        var application: NSRunningApplication?
        NSWorkspace.shared.openApplication(at: url, configuration: configuration) { app, error in
            XCTAssertNil(error)
            application = app
            launched.fulfill()
        }
        wait(for: [launched], timeout: 10)
        let app = try XCTUnwrap(application)
        defer {
            app.terminate()
            RunLoop.current.run(until: Date().addingTimeInterval(1))
        }

        func assertSettingsWindow(_ phase: String, visible: Bool = false) throws {
            RunLoop.current.run(until: Date().addingTimeInterval(2))
            XCTAssertFalse(app.isTerminated, phase)
            XCTAssertTrue(app.isFinishedLaunching, phase)
            let windows = try XCTUnwrap(CGWindowListCopyWindowInfo(.optionAll, kCGNullWindowID) as? [[String: Any]])
            let normalWindows = windows.filter {
                ($0[kCGWindowOwnerPID as String] as? Int32) == app.processIdentifier
                    && ($0[kCGWindowLayer as String] as? Int) == Int(CGWindowLevelForKey(.normalWindow))
            }
            // The floater and its tips use floating panels, never a normal window.
            XCTAssertEqual(!normalWindows.isEmpty, visible, "\(phase): normal windows: \(normalWindows)")
        }
        try assertSettingsWindow("launch without any Settings command")
        app.activate()
        try assertSettingsWindow("activation")
        let reopened = expectation(description: "reopen delivered")
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration()) { _, error in
            XCTAssertNil(error)
            reopened.fulfill()
        }
        wait(for: [reopened], timeout: 10)
        try assertSettingsWindow("reopen", visible: true)
    }

    func testShortcutParsingAndValidation() {
        XCTAssertNil(ActivationShortcut(stored: "Right Command + A"))
        XCTAssertNil(ActivationShortcut(stored: "-1"))
        XCTAssertNil(ActivationShortcut(stored: ""))
        XCTAssertNil(ActivationShortcut(bits: 0))
        for choice in ActivationShortcut.choices {
            XCTAssertNil(ActivationShortcut(bits: choice.bit), choice.name)
        }
        XCTAssertNil(ActivationShortcut(bits: 0x10 | 0x40 | 0x100000))
        let pair = ActivationShortcut(bits: 0x10 | 0x40)!
        XCTAssertEqual(ActivationShortcut(stored: "80"), pair)
        XCTAssertEqual(pair.name, "Right Command + Right Option")
        XCTAssertNotNil(pair.warning)
        XCTAssertNil(ActivationShortcut(bits: 0x08 | 0x20)?.warning)
    }

    func testShortcutPersistenceAndInvalidFallback() throws {
        let suite = "activation-test-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertEqual(ActivationShortcut.load(from: defaults).bits, ActivationShortcut.defaultBits)
        let pair = try XCTUnwrap(ActivationShortcut(bits: 0x10 | 0x40))
        pair.save(to: defaults)
        let reopened = try XCTUnwrap(UserDefaults(suiteName: suite))
        XCTAssertEqual(ActivationShortcut.load(from: reopened), pair)
        for invalid in ["abc", "16", "0", "1048656"] {
            defaults.set(invalid, forKey: ActivationShortcut.defaultsKey)
            XCTAssertEqual(ActivationShortcut.load(from: defaults).bits, ActivationShortcut.defaultBits)
        }
    }

    func testEveryModifierPairDistinguishesSidesAndLatchesUntilReleased() {
        for (index, first) in ActivationShortcut.choices.enumerated() {
            for second in ActivationShortcut.choices.dropFirst(index + 1) {
                for order in [[first.bit, second.bit], [second.bit, first.bit]] {
                    var chord = ActivationChord(bits: first.bit | second.bit)
                    XCTAssertFalse(chord.update(flags: order[0]))
                    XCTAssertTrue(chord.update(flags: order[0] | order[1]))
                    XCTAssertFalse(chord.update(flags: order[1]))
                    XCTAssertTrue(chord.held)
                    XCTAssertFalse(chord.update(flags: order[0] | order[1]))
                    XCTAssertFalse(chord.update(flags: 0))
                    XCTAssertFalse(chord.held)
                    XCTAssertTrue(chord.update(flags: order[0] | order[1]))
                }
            }
        }
    }

    @MainActor
    func testShortcutAppliesLiveAndDropsPendingCapture() {
        let monitor = HotkeyMonitor()
        var dropped = 0
        monitor.onTalkChord = { dropped += 1 }
        monitor.activationShortcut = ActivationShortcut(bits: 0x10 | 0x40)!
        XCTAssertEqual(monitor.activationShortcut.bits, 0x50)
        XCTAssertEqual(dropped, 1)
    }

    @MainActor
    func testCustomChordCancelsCaptureAndNeverDeliversOrDictates() throws {
        for order: [UInt16] in [[61, 54], [54, 61]] {
            let monitor = HotkeyMonitor()
            monitor.activationShortcut = ActivationShortcut(bits: 0x10 | 0x40)!
            monitor.hotkeysEnabled = true
            var toggles = 0
            var drops = 0
            var deliveries = 0
            var dictations = 0
            var shots = 0
            monitor.onChord = { toggles += 1 }
            monitor.onTalkChord = { drops += 1 }
            monitor.onTalkUp = { deliveries += 1 }
            monitor.onDictateTap = { dictations += 1 }
            monitor.onShotTap = { shots += 1 }
            var flags: UInt = 0
            for (index, code) in (order + order.reversed()).enumerated() {
                let bit: UInt = code == 61 ? 0x40 : 0x10
                flags = index < 2 ? flags | bit : flags & ~bit
                let cg = try XCTUnwrap(CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: index < 2))
                cg.type = .flagsChanged
                let generic: UInt = (flags & 0x40 != 0 ? 0x80000 : 0) | (flags & 0x10 != 0 ? 0x100000 : 0)
                cg.flags = CGEventFlags(rawValue: UInt64(flags | generic))
                monitor.handle(try XCTUnwrap(NSEvent(cgEvent: cg)))
            }
            XCTAssertEqual(toggles, 1)
            XCTAssertEqual(drops, 1)
            XCTAssertEqual(deliveries, 0)
            XCTAssertEqual(dictations, 0)
            XCTAssertEqual(shots, 0)
        }
    }

    private let start = Date(timeIntervalSince1970: 1_000_000)

    private func at(_ seconds: TimeInterval) -> Date {
        start.addingTimeInterval(seconds)
    }

    private let rightCommand: UInt = 0x10
    private let rightOption: UInt = 0x40
    private let rightShift: UInt = 0x04
    private let leftCommand: UInt = 0x08
    private let leftOption: UInt = 0x20
    private let leftShift: UInt = 0x02

    func testChordFiresOnceWhenTheThirdRightKeyGoesDown() {
        var chord = ActivationChord()
        XCTAssertFalse(chord.update(flags: rightOption))
        XCTAssertFalse(chord.update(flags: rightOption | rightCommand))
        XCTAssertTrue(chord.update(flags: rightOption | rightCommand | rightShift))
        XCTAssertTrue(chord.held, "its keys do nothing else while it is held")
        XCTAssertFalse(chord.update(flags: rightOption | rightCommand | rightShift), "a repeat is the same press")
    }

    func testChordWorksInAnyOrder() {
        for order in [[rightShift, rightCommand, rightOption], [rightCommand, rightOption, rightShift]] {
            var chord = ActivationChord()
            var flags: UInt = 0
            var fired = 0
            for key in order {
                flags |= key
                if chord.update(flags: flags) { fired += 1 }
            }
            XCTAssertEqual(fired, 1)
        }
    }

    func testLeftHandKeysNeverCount() {
        var chord = ActivationChord()
        XCTAssertFalse(chord.update(flags: leftCommand | leftOption | leftShift))
        XCTAssertFalse(chord.update(flags: leftCommand | rightOption | rightShift), "left Command in place of right")
        XCTAssertFalse(chord.update(flags: rightCommand | leftOption | rightShift), "left Option in place of right")
        XCTAssertFalse(chord.update(flags: rightCommand | rightOption | leftShift), "left Shift in place of right")
        XCTAssertFalse(chord.held)
    }

    func testChordFiresAgainOnlyAfterAllThreeAreReleased() {
        var chord = ActivationChord()
        XCTAssertTrue(chord.update(flags: rightOption | rightCommand | rightShift))
        XCTAssertFalse(chord.update(flags: rightOption | rightCommand))
        XCTAssertTrue(chord.held, "letting go of one key is still the chord")
        XCTAssertFalse(chord.update(flags: rightOption | rightCommand | rightShift), "pressing it back is not a new chord")
        XCTAssertFalse(chord.update(flags: 0))
        XCTAssertFalse(chord.held)
        XCTAssertTrue(chord.update(flags: rightOption | rightCommand | rightShift))
    }

    func testChordToggles() {
        var activation = Activation()
        XCTAssertFalse(activation.isActive, "off by default")
        XCTAssertTrue(activation.toggle(at: at(0)))
        XCTAssertFalse(activation.toggle(at: at(5)), "the same chord again switches it off")
        XCTAssertFalse(activation.isActive)
    }

    func testSwitchesOffTwoMinutesAfterTheLastUse() {
        var activation = Activation()
        _ = activation.toggle(at: at(0))
        activation.used(at: at(30))
        XCTAssertFalse(activation.tick(at: at(149), busy: false))
        XCTAssertTrue(activation.tick(at: at(150), busy: false), "two minutes after the use at 30s")
        XCTAssertFalse(activation.isActive)
        XCTAssertFalse(activation.tick(at: at(400), busy: false), "already off")
    }

    func testIdleWaitStartsAtActivation() {
        var activation = Activation()
        _ = activation.toggle(at: at(10))
        XCTAssertFalse(activation.tick(at: at(129), busy: false))
        XCTAssertTrue(activation.tick(at: at(130), busy: false))
    }

    func testNeverSwitchesOffWhileBusyAndWaitsAgainAfterwards() {
        var activation = Activation()
        _ = activation.toggle(at: at(0))
        for second in stride(from: 1.0, through: 600, by: 1) {
            XCTAssertFalse(activation.tick(at: at(second), busy: true), "recording or delivering at \(second)s")
        }
        XCTAssertFalse(activation.tick(at: at(719), busy: false), "the wait began when the work ended")
        XCTAssertTrue(activation.tick(at: at(720), busy: false))
    }

    func testUseWhileOffChangesNothing() {
        var activation = Activation()
        activation.used(at: at(0))
        XCTAssertFalse(activation.isActive)
        XCTAssertTrue(activation.toggle(at: at(500)))
        XCTAssertFalse(activation.tick(at: at(619), busy: false), "the old use does not shorten the wait")
    }

    func testStaysActiveAfterASendFinishes() {
        var activation = Activation()
        _ = activation.toggle(at: at(0))
        activation.used(at: at(60))
        XCTAssertFalse(activation.tick(at: at(61), busy: false), "sending a message does not hide the floater")
        XCTAssertTrue(activation.isActive)
    }
}

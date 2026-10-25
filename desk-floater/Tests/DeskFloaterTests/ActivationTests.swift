import AppKit
import SwiftUI
import XCTest
@testable import DeskFloater

final class ActivationTests: XCTestCase {
    @MainActor
    func testEscapeIsObservedEvenWhenCaptureHotkeysAreOff() throws {
        let monitor = HotkeyMonitor()
        var escapes = 0
        monitor.onEscape = { escapes += 1 }
        let cg = try XCTUnwrap(CGEvent(keyboardEventSource: nil, virtualKey: 53, keyDown: true))
        let event = try XCTUnwrap(NSEvent(cgEvent: cg))
        monitor.handle(event)
        XCTAssertEqual(escapes, 1)
        XCTAssertEqual(event.keyCode, 53)
    }

    /// Opt in with a bundle made by fm-desk-floater.sh --build-only.
    /// Launches the real app in a temporary home; macOS may ask for Accessibility.
    @MainActor
    func testPermissionGuidanceAndReopenNeverCreateABlankWindow() throws {
        guard let path = ProcessInfo.processInfo.environment["FM_DESK_FLOATER_TEST_APP"] else {
            throw XCTSkip("Set FM_DESK_FLOATER_TEST_APP to Starship Floater (test build).app for the live window regression")
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
            // Launch may show permission guidance; reopen additionally shows the shortcut editor.
            XCTAssertLessThanOrEqual(normalWindows.count, visible ? 2 : 1, "\(phase): normal windows: \(normalWindows)")
            if visible { XCTAssertFalse(normalWindows.isEmpty, phase) }
            let titles = normalWindows.compactMap { $0[kCGWindowName as String] as? String }
            for title in titles {
                XCTAssertTrue(title == "Activation Shortcut" || title.hasSuffix(" Permissions"),
                              "\(phase): unexpected window: \(title)")
            }
            if visible && titles.count == normalWindows.count {
                XCTAssertTrue(titles.contains("Activation Shortcut"), "reopen opens the shortcut editor")
            }
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

final class ShortcutHintTests: XCTestCase {
    func testGlyphsKeepBothSidesAndAllSupportedModifiers() {
        XCTAssertEqual(ActivationShortcut.glyphs(for: TalkKey.bit), "R⌥")
        XCTAssertEqual(ActivationShortcut.glyphs(for: TapKey.rightCommand.bit), "R⌘")
        XCTAssertEqual(ActivationShortcut.glyphs(for: TapKey.rightShift.bit), "R⇧")
        XCTAssertEqual(ActivationShortcut.glyphs(for: 0x01 | 0x2000), "⌃ R⌃")
        XCTAssertEqual(ActivationShortcut.glyphs(for: 0x08 | 0x20 | 0x02), "⌘ ⌥ ⇧")
    }

    @MainActor func testHintsFollowActualShortcutChangesWithoutRestarting() {
        let monitor = HotkeyMonitor()
        let model = FloaterModel(repoRoot: "/unused", fmHome: "/unused")
        monitor.onShortcutChanged = { model.activationShortcut = $0 }
        let alternate = ActivationShortcut(bits: 0x01 | 0x20)!
        monitor.activationShortcut = alternate
        XCTAssertEqual(model.activationShortcut, alternate)
        XCTAssertTrue(model.shortcutHelp.contains("Show / hide: ⌥ ⌃"))
        XCTAssertTrue(model.shortcutHelp.contains("Talk: hold R⌥"))
        XCTAssertTrue(model.shortcutHelp.contains("Dictate: tap R⌘"))
        XCTAssertTrue(model.status.isEmpty)
        XCTAssertTrue(model.idleStatus.isEmpty)
    }

    @MainActor func testMeterStopsAndClearsWhenRecordingEnds() async throws {
        let model = FloaterModel(repoRoot: "/unused", fmHome: "/unused")
        model.mode = .recording
        model.microphoneLevel = 0.9
        model.mode = .busy
        XCTAssertEqual(model.microphoneLevel, 0)
        model.microphoneLevel = 0.7
        try await Task.sleep(nanoseconds: 80_000_000)
        XCTAssertEqual(model.microphoneLevel, 0.7, "no meter updates outside recording")
        model.mode = .idle
        XCTAssertEqual(model.microphoneLevel, 0)
    }
}

final class IconOnlyFloaterTests: XCTestCase {
    @MainActor func testBetaMarkRequiresTheExactBetaBundleIdentifier() {
        XCTAssertTrue(FloaterView.isBeta(bundleIdentifier: "com.firstmate.desk-floater.beta"))
        for identifier in [nil, "com.firstmate.desk-floater", "com.firstmate.desk-floater.build-only",
                           "com.firstmate.desk-floater.beta.preview"] as [String?] {
            XCTAssertFalse(FloaterView.isBeta(bundleIdentifier: identifier))
        }
    }

    @MainActor func testWritingFloatsInDrawsThreeLinesThenFadesAndRepeats() {
        let start = WritingIndicator.frame(at: 0, reduceMotion: false)
        XCTAssertEqual(start.opacity, 0)
        XCTAssertEqual(start.lines, [0, 0, 0])
        let landed = WritingIndicator.frame(at: 0.65, reduceMotion: false)
        XCTAssertGreaterThan(landed.tip.y, start.tip.y)
        XCTAssertEqual(landed.opacity, 1)
        for row in 0..<3 {
            let frame = WritingIndicator.frame(at: 0.65 + Double(row) * 1.07 + 0.425, reduceMotion: false)
            for line in 0..<3 {
                XCTAssertEqual(frame.lines[line], line < row ? 1 : line == row ? 0.5 : 0, accuracy: 0.00001)
            }
            XCTAssertEqual(frame.tip.x, row == 2 ? 8 : 10, accuracy: 0.00001)
        }
        for row in 0..<2 {
            let moving = WritingIndicator.frame(at: 0.65 + Double(row) * 1.07 + 0.96, reduceMotion: false)
            XCTAssertEqual(moving.tip.x, 10, accuracy: 0.00001, "pen glides back between lines")
            XCTAssertEqual(moving.lines[row], 1)
            XCTAssertEqual(moving.lines[row + 1], 0)
        }
        XCTAssertEqual(WritingIndicator.frame(at: 3.8, reduceMotion: false).lines, [1, 1, 1])
        XCTAssertEqual(WritingIndicator.frame(at: 4.25, reduceMotion: false).opacity, 0.5, accuracy: 0.00001)
        XCTAssertEqual(WritingIndicator.frame(at: 4.6, reduceMotion: false).opacity, 0)
        XCTAssertEqual(WritingIndicator.frame(at: WritingIndicator.duration, reduceMotion: false), start)
        XCTAssertEqual(WritingIndicator.frame(at: -1, reduceMotion: false), start)
    }

    @MainActor func testReduceMotionKeepsThePenStatic() {
        let still = WritingIndicator.frame(at: 0, reduceMotion: true)
        XCTAssertEqual(still.opacity, 1)
        for time in [0.3, 0.9, 2.0, 100.0] {
            XCTAssertEqual(WritingIndicator.frame(at: time, reduceMotion: true), still)
        }
    }
}

final class FloaterGenerationTests: XCTestCase {
    func testRomanNumeralsCountUpAndUseSubtractiveNotation() {
        let cases = [(1, "I"), (2, "II"), (3, "III"), (4, "IV"), (5, "V"), (9, "IX"),
                     (14, "XIV"), (19, "XIX"), (40, "XL"), (49, "XLIX"), (90, "XC"),
                     (400, "CD"), (944, "CMXLIV"), (2026, "MMXXVI"), (3999, "MMMCMXCIX")]
        for (number, expected) in cases {
            XCTAssertEqual(FloaterGeneration.roman(number), expected)
        }
        XCTAssertEqual(FloaterGeneration.roman(0), "")
        XCTAssertEqual(FloaterGeneration.roman(-1), "")
        XCTAssertGreaterThan(FloaterGeneration.current, 0)
    }

    func testBetaDisplaysTheNextGenerationFromTheSameCounter() {
        let regular = GenerationMark(beta: false, hovered: true)
        let beta = GenerationMark(beta: true, hovered: false)
        XCTAssertEqual(regular.generation, FloaterGeneration.current)
        XCTAssertEqual(beta.generation, FloaterGeneration.current + 1)
    }

    @MainActor func testBetaPrefixAndHoverNeverResizeTheGenerationMark() {
        let regular = NSHostingView(rootView: GenerationMark(beta: false, hovered: true))
        let beta = NSHostingView(rootView: GenerationMark(beta: true, hovered: false))
        let hidden = NSHostingView(rootView: GenerationMark(beta: false, hovered: false))
        XCTAssertGreaterThan(regular.fittingSize.width, 9, "the beta prefix slot precedes the numeral")
        XCTAssertEqual(regular.fittingSize, beta.fittingSize, "beta reserves exactly the same prefix slot")
        XCTAssertEqual(regular.fittingSize, hidden.fittingSize, "hover cannot shift the fixed numeral anchor")
    }
}

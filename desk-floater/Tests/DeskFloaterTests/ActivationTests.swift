import AppKit
import XCTest
@testable import DeskFloater

final class ActivationTests: XCTestCase {
    /// Opt in with a bundle made by fm-desk-floater.sh --build-only.
    /// Launches the real app in a temporary home; macOS may ask for Accessibility.
    @MainActor
    func testLaunchAndReopenNeverCreateASettingsWindow() throws {
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

        func assertNoSettingsWindow(_ phase: String) throws {
            RunLoop.current.run(until: Date().addingTimeInterval(2))
            XCTAssertFalse(app.isTerminated, phase)
            XCTAssertTrue(app.isFinishedLaunching, phase)
            let windows = try XCTUnwrap(CGWindowListCopyWindowInfo(.optionAll, kCGNullWindowID) as? [[String: Any]])
            let normalWindows = windows.filter {
                ($0[kCGWindowOwnerPID as String] as? Int32) == app.processIdentifier
                    && ($0[kCGWindowLayer as String] as? Int) == Int(CGWindowLevelForKey(.normalWindow))
            }
            // The floater and its tips use floating panels, never a normal window.
            XCTAssertTrue(normalWindows.isEmpty, "\(phase): unexpected normal window: \(normalWindows)")
        }
        try assertNoSettingsWindow("launch without any Settings command")
        app.activate()
        try assertNoSettingsWindow("activation")
        let reopened = expectation(description: "reopen delivered")
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration()) { _, error in
            XCTAssertNil(error)
            reopened.fulfill()
        }
        wait(for: [reopened], timeout: 10)
        try assertNoSettingsWindow("reopen")
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

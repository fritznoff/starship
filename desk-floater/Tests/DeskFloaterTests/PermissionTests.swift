import AppKit
import AVFoundation
import Carbon
import XCTest
@testable import DeskFloater

final class PermissionTests: XCTestCase {
    func testEachPermissionOpensItsSpecificPrivacyPane() {
        let expected: [FloaterPermission: String] = [
            .microphone: "Privacy_Microphone",
            .accessibility: "Privacy_Accessibility",
            .screenRecording: "Privacy_ScreenCapture",
            .automation: "Privacy_Automation"
        ]
        XCTAssertEqual(expected.count, FloaterPermission.allCases.count)
        for permission in FloaterPermission.allCases {
            let url = permission.settingsURL
            XCTAssertEqual(url.scheme, "x-apple.systempreferences")
            XCTAssertEqual(url.path, "com.apple.preference.security")
            XCTAssertEqual(url.query, expected[permission])
            XCTAssertFalse(permission.why.isEmpty)
        }
    }

    func testMicrophoneStatesDistinguishFirstPromptFromDenied() {
        XCTAssertEqual(PermissionState.microphone(.authorized), .granted)
        XCTAssertEqual(PermissionState.microphone(.notDetermined), .notDetermined)
        XCTAssertEqual(PermissionState.microphone(.denied), .missing)
        XCTAssertEqual(PermissionState.microphone(.restricted), .missing)
    }

    func testAutomationDoesNotReportStoppedTerminalOrQueryErrorsAsDenial() {
        XCTAssertEqual(PermissionState.automation(noErr), .granted)
        XCTAssertEqual(PermissionState.automation(OSStatus(errAEEventWouldRequireUserConsent)), .notDetermined)
        XCTAssertEqual(PermissionState.automation(OSStatus(errAEEventNotPermitted)), .missing)
        XCTAssertEqual(PermissionState.automation(OSStatus(procNotFound)), .unavailable)
        XCTAssertEqual(PermissionState.automation(OSStatus(paramErr)), .unavailable)
    }

    func testOnlyAccessibilityAndScreenRecordingAcceptAppDrops() {
        XCTAssertEqual(FloaterPermission.allCases.filter(\.supportsAppDrop), [.accessibility, .screenRecording])
    }

    func testPanelAttachesBelowSettingsAndClampsToScreen() {
        let visible = CGRect(x: 0, y: 25, width: 1440, height: 850)
        let size = CGSize(width: 420, height: 124)
        let settings = CGRect(x: 400, y: 300, width: 600, height: 550)
        let panel = PermissionPanelPlacement.frame(settings: settings, visible: visible, size: size)
        XCTAssertEqual(panel.midX, settings.midX)
        XCTAssertEqual(panel.maxY, settings.minY - 8)
        let atEdge = PermissionPanelPlacement.frame(settings: CGRect(x: 1300, y: 30, width: 600, height: 550),
                                                    visible: visible, size: size)
        XCTAssertTrue(visible.contains(atEdge))
    }

    func testFallbackAndSecondaryDisplayPlacementStayVisible() {
        let screen = CGRect(x: -1920, y: -300, width: 1920, height: 1080)
        let size = CGSize(width: 420, height: 124)
        let fallback = PermissionPanelPlacement.frame(settings: nil, visible: screen, size: size)
        XCTAssertTrue(screen.contains(fallback))
        XCTAssertEqual(fallback.midX, screen.midX)
        let settings = CGRect(x: -1800, y: -250, width: 600, height: 500)
        XCTAssertTrue(screen.contains(PermissionPanelPlacement.frame(settings: settings, visible: screen, size: size)))
    }

    func testAppDragProvidesAFileURLRatherThanText() {
        let url = URL(fileURLWithPath: "/Applications/Test Floater.app", isDirectory: true)
        let provider = NSItemProvider(object: url as NSURL)
        XCTAssertTrue(provider.hasItemConformingToTypeIdentifier("public.file-url"))
        let loaded = expectation(description: "file URL loaded")
        provider.loadItem(forTypeIdentifier: "public.file-url", options: nil) { item, error in
            XCTAssertNil(error)
            if let data = item as? Data {
                XCTAssertEqual(URL(dataRepresentation: data, relativeTo: nil), url)
            } else {
                XCTAssertEqual(item as? URL, url)
            }
            loaded.fulfill()
        }
        wait(for: [loaded], timeout: 5)
    }
}

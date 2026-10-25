import AppKit
import XCTest
@testable import DeskFloater

final class AmbientBackgroundTests: XCTestCase {
    func testTheSmallFieldStaysInsideThePlateAndFallsOffWithDepth() {
        let size = CGSize(width: 116, height: 76)
        for time in stride(from: 0.0, through: 12, by: 0.5) {
            let points = AmbientPointField.points(size: size, time: time)
            XCTAssertEqual(points.count, 264)
            for point in points {
                XCTAssertTrue(point.position.x.isFinite && point.position.y.isFinite)
                XCTAssertTrue(CGRect(origin: .zero, size: size).contains(point.position))
                XCTAssertLessThan(point.opacity, 0.64)
                XCTAssertLessThanOrEqual(point.radius, 0.8)
                XCTAssertTrue((0...2).contains(point.hue))
            }
            XCTAssertLessThan(points[0].radius, points[240].radius)
            XCTAssertLessThan(points[0].opacity, points[240].opacity)
            XCTAssertGreaterThan(points[0].position.x, points[240].position.x,
                                 "the distant rows narrow in perspective")
        }
        XCTAssertTrue(AmbientPointField.points(size: .zero, time: 0).isEmpty)
    }

    func testVisibleWavesAndFifteenPercentBreathingRepeatEveryFiveAndAHalfSeconds() {
        let size = CGSize(width: 116, height: 76)
        let first = AmbientPointField.points(size: size, time: 0)
        let later = AmbientPointField.points(size: size, time: 0.5)
        let cycle = AmbientPointField.points(size: size, time: 5.5)
        let peak = AmbientPointField.points(size: size, time: 5.5 / 4)
        let trough = AmbientPointField.points(size: size, time: 5.5 * 3 / 4)
        XCTAssertEqual(first.last!.opacity, 0.55, accuracy: 0.0001)
        XCTAssertEqual(peak.last!.opacity / first.last!.opacity, 1.15, accuracy: 0.0001)
        XCTAssertEqual(trough.last!.opacity / first.last!.opacity, 0.85, accuracy: 0.0001)
        XCTAssertNotEqual(first.map(\.position), later.map(\.position))
        for (a, b) in zip(first, later) {
            XCTAssertEqual(a.position.x, b.position.x)
            XCTAssertLessThan(abs(a.position.y - b.position.y), size.height * 0.12)
            XCTAssertLessThan(abs(a.opacity - b.opacity), 0.05)
        }
        for (a, b) in zip(first, cycle) {
            XCTAssertEqual(a.position.y, b.position.y, accuracy: 0.0001)
            XCTAssertEqual(a.opacity, b.opacity, accuracy: 0.0001)
        }
    }

    @MainActor
    func testHiddenOccludedLockedAndSleepingViewsStopTheirTimer() throws {
        let (window, view) = try visibleBackground()
        defer { window.orderOut(nil) }
        XCTAssertTrue(view.isAnimating)
        pump(0.25)
        XCTAssertGreaterThan(view.elapsed, 0)
        XCTAssertNil(view.hitTest(NSPoint(x: 10, y: 10)))

        for name in ["com.apple.screenIsLocked", NSWorkspace.screensDidSleepNotification.rawValue,
                     NSWorkspace.sessionDidResignActiveNotification.rawValue] {
            view.environmentChanged(Notification(name: Notification.Name(name)))
            XCTAssertFalse(view.isAnimating)
            let stopped = view.elapsed
            pump(0.15)
            XCTAssertEqual(view.elapsed, stopped)
            let resume = name == "com.apple.screenIsLocked" ? "com.apple.screenIsUnlocked"
                : name == NSWorkspace.screensDidSleepNotification.rawValue
                ? NSWorkspace.screensDidWakeNotification.rawValue : NSWorkspace.sessionDidBecomeActiveNotification.rawValue
            view.environmentChanged(Notification(name: Notification.Name(resume)))
            XCTAssertTrue(view.isAnimating)
        }
        view.isHidden = true
        XCTAssertFalse(view.isAnimating)
        view.isHidden = false
        XCTAssertTrue(view.isAnimating)
        window.orderOut(nil)
        pump(0.1)
        XCTAssertFalse(view.isAnimating)
        window.contentView = nil
        XCTAssertFalse(view.isAnimating)
    }

    @MainActor
    func testCoveringTheWindowStopsTheTimer() throws {
        let (window, view) = try visibleBackground()
        let cover = NSWindow(contentRect: window.frame.insetBy(dx: -20, dy: -20),
                             styleMask: [.borderless], backing: .buffered, defer: false)
        cover.isReleasedWhenClosed = false
        cover.level = NSWindow.Level(rawValue: window.level.rawValue + 1)
        cover.backgroundColor = .black
        cover.isOpaque = true
        defer { cover.orderOut(nil); window.orderOut(nil) }
        cover.orderFrontRegardless()
        for _ in 0..<20 {
            pump(0.1)
            if !window.occlusionState.contains(.visible) { break }
        }
        XCTAssertFalse(window.occlusionState.contains(.visible))
        XCTAssertFalse(view.isAnimating)
        let stopped = view.elapsed
        pump(0.2)
        XCTAssertEqual(view.elapsed, stopped)
        cover.orderOut(nil)
        for _ in 0..<20 {
            pump(0.1)
            if view.isAnimating { break }
        }
        XCTAssertTrue(view.isAnimating)
    }

    @MainActor
    func testAccessibilityPreferencesFreezeOrRemoveTheDecoration() throws {
        let (window, view) = try visibleBackground()
        defer { window.orderOut(nil) }
        pump(0.2)
        view.reduceMotion = true
        XCTAssertFalse(view.isAnimating)
        let still = render(view)
        pump(0.2)
        XCTAssertEqual(render(view), still)
        view.reduceMotion = false
        XCTAssertTrue(view.isAnimating)
        view.reduceTransparency = true
        XCTAssertFalse(view.isAnimating)
        let empty = render(view)
        XCTAssertNotEqual(empty, still)
        view.reduceTransparency = false
        XCTAssertTrue(view.isAnimating)
        XCTAssertNotEqual(render(view), empty)
    }

    @MainActor
    private func visibleBackground() throws -> (NSWindow, AmbientBackgroundView) {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        app.finishLaunching()
        let view = AmbientBackgroundView(frame: NSRect(x: 0, y: 0, width: 116, height: 76))
        view.reduceMotion = false
        view.reduceTransparency = false
        let window = NSWindow(contentRect: view.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.level = .floating
        window.contentView = view
        window.center()
        window.orderFrontRegardless()
        for _ in 0..<20 {
            pump(0.1)
            if window.occlusionState.contains(.visible) { break }
        }
        guard window.occlusionState.contains(.visible) else {
            window.orderOut(nil)
            throw XCTSkip("requires a visible macOS window session")
        }
        return (window, view)
    }

    @MainActor
    private func pump(_ seconds: TimeInterval) {
        let until = Date().addingTimeInterval(seconds)
        while Date() < until {
            if let event = NSApp.nextEvent(matching: .any, until: Date().addingTimeInterval(0.01),
                                           inMode: .default, dequeue: true) {
                NSApp.sendEvent(event)
            }
        }
    }

    @MainActor
    private func render(_ view: AmbientBackgroundView) -> Data {
        let image = NSImage(size: view.bounds.size)
        image.lockFocus()
        view.layer!.displayIfNeeded()
        view.layer!.render(in: NSGraphicsContext.current!.cgContext)
        image.unlockFocus()
        return image.tiffRepresentation!
    }
}

import AppKit
import QuartzCore
import SwiftUI

/// One small Core Animation backing layer, not a scene or a layer per particle.
struct AmbientBackground: NSViewRepresentable {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    func makeNSView(context: Context) -> AmbientBackgroundView { AmbientBackgroundView() }
    func updateNSView(_ view: AmbientBackgroundView, context: Context) {
        view.reduceMotion = reduceMotion
        view.reduceTransparency = reduceTransparency
    }
}

struct AmbientPointField {
    struct Point {
        let position: CGPoint
        let radius: CGFloat
        let opacity: CGFloat
        let hue: Int
    }

    static func points(size: CGSize, time: TimeInterval) -> [Point] {
        guard size.width > 0, size.height > 0 else { return [] }
        let breath = 1 + 0.06 * sin(time * .pi / 6)
        return (0..<11).flatMap { row in
            let depth = Double(row) / 10
            let perspective = 0.52 + 0.48 * depth
            return (0..<24).map { column in
                let x = Double(column) / 23
                let wave = sin(x * 3 * .pi + depth * 2.4 - time * .pi / 6)
                    * exp(-pow((x - 0.5) * 1.7, 2))
                return Point(
                    position: CGPoint(
                        x: size.width * (0.5 + (x - 0.5) * perspective * 0.96),
                        y: size.height * (0.18 + depth * 0.64 + wave * 0.10 * perspective * breath)),
                    radius: 0.35 + 0.45 * depth,
                    opacity: (0.07 + 0.15 * depth) * breath,
                    hue: min(2, column / 8))
            }
        }
    }
}

final class AmbientBackgroundView: NSView {
    var reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
        didSet { if oldValue != reduceMotion { refreshAnimation(); refreshDrawing() } }
    }
    var reduceTransparency = NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency {
        didSet { if oldValue != reduceTransparency { refreshAnimation(); refreshDrawing() } }
    }
    private let fieldLayer = AmbientPointLayer()
    private var timer: Timer?
    private var lastFrame = CACurrentMediaTime()
    private(set) var elapsed: TimeInterval = 0
    var isAnimating: Bool { timer != nil }
    private var sessionAvailable = true
    private var screenAwake = true
    private var screenLocked = (CGSessionCopyCurrentDictionary() as? [String: Any])?["CGSSessionScreenIsLocked"] as? Bool == true

    override init(frame: NSRect) {
        super.init(frame: frame)
        layer = fieldLayer
        wantsLayer = true
        fieldLayer.needsDisplayOnBoundsChange = true
        refreshDrawing()
        let center = NotificationCenter.default
        for name in [NSWindow.didChangeOcclusionStateNotification,
                     NSApplication.didHideNotification, NSApplication.didUnhideNotification] {
            center.addObserver(self, selector: #selector(refreshAnimation), name: name, object: nil)
        }
        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.screensDidSleepNotification, NSWorkspace.screensDidWakeNotification,
                     NSWorkspace.sessionDidResignActiveNotification, NSWorkspace.sessionDidBecomeActiveNotification] {
            workspace.addObserver(self, selector: #selector(environmentChanged(_:)), name: name, object: nil)
        }
        for name in ["com.apple.screenIsLocked", "com.apple.screenIsUnlocked"] {
            DistributedNotificationCenter.default().addObserver(
                self, selector: #selector(environmentChanged(_:)), name: Notification.Name(name), object: nil)
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    deinit {
        timer?.invalidate()
        NotificationCenter.default.removeObserver(self)
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        DistributedNotificationCenter.default().removeObserver(self)
    }

    // This decoration must never intercept a control or the backing plate's drag.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        refreshDrawing()
        refreshAnimation()
    }
    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        refreshDrawing()
    }
    override func viewDidHide() { super.viewDidHide(); refreshAnimation() }
    override func viewDidUnhide() { super.viewDidUnhide(); refreshAnimation() }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        refreshDrawing()
    }

    @objc func environmentChanged(_ notification: Notification) {
        switch notification.name {
        case NSWorkspace.screensDidSleepNotification: screenAwake = false
        case NSWorkspace.screensDidWakeNotification: screenAwake = true
        case NSWorkspace.sessionDidResignActiveNotification: sessionAvailable = false
        case NSWorkspace.sessionDidBecomeActiveNotification: sessionAvailable = true
        case Notification.Name("com.apple.screenIsLocked"): screenLocked = true
        case Notification.Name("com.apple.screenIsUnlocked"): screenLocked = false
        default: break
        }
        refreshAnimation()
        refreshDrawing()
    }

    @objc private func refreshAnimation() {
        let animate = window?.isVisible == true && window?.occlusionState.contains(.visible) == true
            && !isHiddenOrHasHiddenAncestor && !NSApp.isHidden
            && sessionAvailable && screenAwake && !screenLocked
            && !reduceMotion && !reduceTransparency
        if animate && timer == nil {
            lastFrame = CACurrentMediaTime()
            let timer = Timer(timeInterval: 1.0 / 6, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    let now = CACurrentMediaTime()
                    self.elapsed += min(now - self.lastFrame, 0.25)
                    self.lastFrame = now
                    self.refreshDrawing()
                }
            }
            timer.tolerance = 0.04
            RunLoop.main.add(timer, forMode: .common)
            self.timer = timer
        } else if !animate {
            timer?.invalidate()
            timer = nil
        }
    }

    private func refreshDrawing() {
        fieldLayer.contentsScale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        fieldLayer.time = reduceMotion ? 0 : elapsed
        fieldLayer.dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        fieldLayer.isHidden = reduceTransparency
        fieldLayer.setNeedsDisplay()
    }
}

/// Redraw only the field's layer, not the hosting view and all its controls.
private final class AmbientPointLayer: CALayer {
    var time: TimeInterval = 0
    var dark = true

    override func draw(in context: CGContext) {
        // Cyan, violet and pink from the icon's voice wave, without its bright glow.
        let colors = [NSColor(srgbRed: 0.21, green: 0.89, blue: 1, alpha: 1),
                      NSColor(srgbRed: 0.56, green: 0.48, blue: 1, alpha: 1),
                      NSColor(srgbRed: 1, green: 0.37, blue: 0.82, alpha: 1)]
        for point in AmbientPointField.points(size: bounds.size, time: time) {
            context.setFillColor(colors[point.hue].withAlphaComponent(point.opacity * (dark ? 1 : 0.85)).cgColor)
            context.fillEllipse(in: CGRect(x: point.position.x - point.radius, y: point.position.y - point.radius,
                                          width: point.radius * 2, height: point.radius * 2))
        }
    }
}

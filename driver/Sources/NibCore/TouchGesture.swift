import Foundation
import CoreGraphics

/// Turns touch frames into gestures. v1: two-finger scroll (pan) via CGScrollWheel.
/// One-finger touch is intentionally ignored so it doesn't fight the pen for the cursor.
public final class TouchGestureEngine {
    private var lastCentroid: (x: Double, y: Double)?
    private var lastCount = 0

    /// Gain converting raw touch units to scroll pixels. Touch space is ~15360x8640.
    public var scrollGain = 0.35
    /// Natural scrolling: content follows the fingers (macOS default). When true,
    /// moving fingers down reveals content above (scrolls toward the top).
    public var naturalScrolling = true
    /// When false, touch input is ignored entirely.
    public var enabled = true
    /// Palm rejection: suppress touch while the pen is in proximity, plus a brief
    /// cooldown after it lifts (a resting palm often lingers as the pen leaves).
    public var palmRejection = true
    public var palmCooldown: TimeInterval = 0.6

    /// Tap-to-click: a quick single-finger tap (short, little movement) → left click
    /// at the tapped location. Needs `tapMapping` to convert touch coords to screen points.
    public var tapToClick = true
    public var tapMapping: DisplayMapping?
    private let tapMaxDuration: TimeInterval = 0.30
    private let tapMoveThreshold = 300.0   // touch units (~35 px)
    private var tapActive = false
    private var tapStart: (x: Double, y: Double, t: TimeInterval) = (0, 0, 0)
    private var tapMoved = 0.0
    private var tapClicks = ClickCounter(maxDistance: 20)   // fingers land less precisely than a pen
    /// System double-click interval (the app sets it from NSEvent.doubleClickInterval).
    public var doubleClickInterval: TimeInterval {
        get { tapClicks.interval }
        set { tapClicks.interval = newValue }
    }

    /// Three-finger swipe → Mission Control shortcuts (switch spaces / Mission Control /
    /// App Exposé). Uses the default macOS keyboard shortcuts, so they must be enabled
    /// in System Settings › Keyboard Shortcuts › Mission Control (they are by default).
    public var threeFingerSwipe = true
    public var swipeThreshold = 1500.0        // touch units of centroid travel (~190 px)
    private var threeStart: (x: Double, y: Double)?
    private var swipeFired = false
    private var sawThreePlus = false
    private var sequenceStart: TimeInterval = 0
    /// Delay before a 2-finger touch is treated as scroll, so a landing 3rd finger
    /// (a swipe) isn't briefly misread as a scroll. Kept short so quick 2-finger
    /// navigation flicks still register.
    private let scrollSettle: TimeInterval = 0.06
    /// Optional debug sink (stderr) for diagnosing gestures.
    public var debug: ((String) -> Void)?

    private var penInProximity = false
    private var penLeftAt: TimeInterval = -1e9

    /// Fed from the pen report stream so touch can be gated on pen proximity.
    public func setPenInProximity(_ v: Bool) {
        if penInProximity && !v { penLeftAt = now() }
        penInProximity = v
    }

    private var penBlocking: Bool {
        guard palmRejection else { return false }
        if penInProximity { return true }
        return (now() - penLeftAt) < palmCooldown
    }

    private let sink: EventSink
    /// HID-state source, like real input (see `EventEmitter.source`).
    private let source: CGEventSource? = {
        let s = CGEventSource(stateID: .hidSystemState)
        s?.localEventsSuppressionInterval = 0   // never mute the keyboard/trackpad after posting
        return s
    }()
    private let now: () -> TimeInterval
    /// Performs a three-finger swipe given the arrow key code (123 ← / 124 → / 125 ↓ / 126 ↑).
    /// Defaults to Control+arrow via System Events; tests substitute a recorder.
    public var onSwipe: (Int) -> Void = TouchGestureEngine.postControlKey

    public init(sink: EventSink = SystemEventSink(),
                now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.sink = sink
        self.now = now
    }

    public func handle(_ frame: TouchFrame) {
        guard enabled, !penBlocking else { lastCentroid = nil; tapActive = false; return }
        let down = frame.contacts.filter { $0.down }
        defer { lastCount = down.count }

        let t = now()
        if lastCount == 0 && down.count > 0 { sequenceStart = t }
        // Any sequence that reaches 3 fingers is a swipe, not a scroll — suppress scroll
        // for the whole sequence (incl. the 2-finger phases while landing/lifting).
        if down.count >= 3 { sawThreePlus = true }
        else if down.count == 0 { sawThreePlus = false }

        if tapToClick { updateTap(down) }
        if threeFingerSwipe { updateSwipe(down) }

        // Scroll only for a settled 2-finger touch that never reached 3 fingers.
        let canScroll = down.count == 2 && !sawThreePlus && (t - sequenceStart) >= scrollSettle
        guard canScroll else { lastCentroid = nil; return }

        let cx = down.reduce(0.0) { $0 + Double($1.x) } / 2.0
        let cy = down.reduce(0.0) { $0 + Double($1.y) } / 2.0

        // Only scroll once we have a previous 2-finger centroid (avoids a jump on touch-down).
        if let last = lastCentroid, lastCount == 2 {
            // Raw deltas: touch Y increases downward, X increases rightward.
            let rawDx = (cx - last.x) * scrollGain
            let rawDy = (cy - last.y) * scrollGain
            // Natural: content follows fingers (positive wheel1 scrolls toward top).
            let sign = naturalScrolling ? 1.0 : -1.0
            postScroll(dx: rawDx * sign, dy: rawDy * sign)
        }
        lastCentroid = (cx, cy)
    }

    private func postScroll(dx: Double, dy: Double) {
        // Plain pixel scroll (horizontal + vertical). Phased/gesture scroll for Safari
        // swipe-navigation is a stretch goal — it felt janky, so we keep simple scrolling.
        guard abs(dx) >= 1 || abs(dy) >= 1 else { return }
        guard let e = CGEvent(scrollWheelEvent2Source: source, units: .pixel,
                              wheelCount: 2, wheel1: Int32(dy), wheel2: Int32(dx), wheel3: 0)
        else { return }
        sink.post(e)
    }

    // MARK: - Tap to click

    private func updateTap(_ down: [TouchContact]) {
        let t = now()
        switch down.count {
        case 1:
            let f = down[0]
            if !tapActive && lastCount == 0 {
                tapActive = true
                tapStart = (Double(f.x), Double(f.y), t)
                tapMoved = 0
            } else if tapActive {
                let dx = Double(f.x) - tapStart.x, dy = Double(f.y) - tapStart.y
                tapMoved = max(tapMoved, (dx * dx + dy * dy).squareRoot())
            }
        case 0:
            if tapActive {
                let quick = (t - tapStart.t) <= tapMaxDuration
                if quick && tapMoved <= tapMoveThreshold {
                    emitTapClick(x: Int(tapStart.x), y: Int(tapStart.y))
                }
                tapActive = false
            }
        default:
            tapActive = false   // 2+ fingers is a gesture, not a tap
        }
    }

    private func emitTapClick(x: Int, y: Int) {
        guard let m = tapMapping else { return }
        let pt = m.point(x: x, y: y)
        let clicks = tapClicks.down(at: pt, time: now())
        for type in [CGEventType.leftMouseDown, .leftMouseUp] {
            guard let e = CGEvent(mouseEventSource: source, mouseType: type,
                                  mouseCursorPosition: pt, mouseButton: .left) else { continue }
            e.setIntegerValueField(.mouseEventClickState, value: Int64(clicks))
            sink.post(e)
        }
    }

    // MARK: - Three-finger swipe

    private func updateSwipe(_ down: [TouchContact]) {
        guard down.count == 3 else {
            threeStart = nil
            if lastCount == 3 { swipeFired = false }
            return
        }
        let cx = down.reduce(0.0) { $0 + Double($1.x) } / 3.0
        let cy = down.reduce(0.0) { $0 + Double($1.y) } / 3.0
        if lastCount != 3 {                 // three fingers just landed
            threeStart = (cx, cy); swipeFired = false
            debug?("swipe: 3 fingers down")
        } else if !swipeFired, let s = threeStart {
            let dx = cx - s.x, dy = cy - s.y
            if max(abs(dx), abs(dy)) >= swipeThreshold {
                fireSwipe(dx: dx, dy: dy)
                swipeFired = true
            }
        }
    }

    // Arrow key codes; Mission Control shortcuts are Control+Arrow by default.
    private func fireSwipe(dx: Double, dy: Double) {
        let key: Int
        if abs(dx) > abs(dy) {
            key = dx > 0 ? 123 : 124        // fingers right → prev space (←) ; left → next (→)
        } else {
            key = dy < 0 ? 126 : 125        // up → Mission Control (↑) ; down → App Exposé (↓)
        }
        debug?("swipe: FIRE key=\(key)")
        onSwipe(key)
    }

    /// Fire Control+<arrow> via System Events. Raw CGEvent posting does not reliably
    /// trigger these system shortcuts from a background agent, but osascript/System
    /// Events does. Runs detached (needs the one-time Automation permission prompt).
    public static func postControlKey(_ keyCode: Int) {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        task.arguments = ["-e", "tell application \"System Events\" to key code \(keyCode) using control down"]
        do { try task.run() } catch {
            FileHandle.standardError.write("nib: swipe osascript failed \(error)\n".data(using: .utf8)!)
        }
    }
}

import Foundation
import CoreGraphics
import ApplicationServices
import AppKit
import NibCore

// The device Nib is driving. All model-specific identity, report layouts, mode-switch and
// touch-enable sequences live in the profile — see NibCore/DeviceProfile.swift.
// Resolve it from whatever tablet is actually plugged in; fall back to the reference
// device if nothing recognized is connected yet (e.g. the agent started before attach).
let profile: DeviceProfile = {
    let detected = DeviceProfile.detectConnected()
    if let p = detected.first {
        FileHandle.standardError.write("nib: detected \(p.name)\n".data(using: .utf8)!)
        if detected.count > 1 {
            let others = detected.dropFirst().map { $0.name }.joined(separator: ", ")
            FileHandle.standardError.write("nib: (also connected: \(others); driving the first)\n".data(using: .utf8)!)
        }
        return p
    }
    FileHandle.standardError.write("nib: no known tablet detected, defaulting to \(DeviceProfile.dth2420.name)\n".data(using: .utf8)!)
    return .dth2420
}()

let args = CommandLine.arguments
let mode = args.count > 1 ? args[1] : "run"

/// Locate the tablet's own display so the pen maps 1:1 onto the tablet surface.
/// Match on the profile's native panel resolution; fall back to the main display.
func cintiqDisplayBounds() -> CGRect {
    guard let panel = profile.panelSize else { return CGDisplayBounds(CGMainDisplayID()) }
    var count: UInt32 = 0
    CGGetActiveDisplayList(0, nil, &count)
    var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
    CGGetActiveDisplayList(count, &ids, &count)
    for id in ids {
        // Match on native pixel resolution; the panel may run HiDPI, so CGDisplayBounds
        // returns the point-space rect used for cursor mapping.
        guard let mode = CGDisplayCopyDisplayMode(id) else { continue }
        if mode.pixelWidth == Int(panel.width) && mode.pixelHeight == Int(panel.height) {
            let b = CGDisplayBounds(id)
            FileHandle.standardError.write("nib: mapping to tablet display id=\(id) bounds=\(b)\n".data(using: .utf8)!)
            return b
        }
    }
    FileHandle.standardError.write("nib: tablet display not found, using main display\n".data(using: .utf8)!)
    return CGDisplayBounds(CGMainDisplayID())
}

// Pen mode-switch: send the profile's feature reports to put the pen into its native
// high-resolution mode (buffers include the report-ID byte as data[0]).
func enableNativeMode(_ t: HIDTransport) {
    let results = profile.initSequence.map { w in
        (w.reportID, t.sendFeature(reportID: w.reportID, w.bytes))
    }
    let summary = results.map { String(format: "0x%02x=%@", $0.0, $0.1 ? "ok" : "FAIL") }.joined(separator: ", ")
    FileHandle.standardError.write("nib: mode-switch sent (\(summary))\n".data(using: .utf8)!)
}

// Touch enable: send the profile's vendor OUTPUT reports to enable the multitouch sensor.
func enableTouch(_ t: HIDTransport) {
    let results = profile.touchEnable.map { w in
        (w.reportID, t.sendOutput(reportID: w.reportID, w.bytes))
    }
    let summary = results.enumerated()
        .map { "\($0.offset == 0 ? "multitouch" : "configure")=\($0.element.1 ? "ok" : "FAIL")" }
        .joined(separator: ", ")
    FileHandle.standardError.write("nib: touch-enable sent (\(summary))\n".data(using: .utf8)!)
}

switch mode {
case "log":
    // Confirm report-0x10 field offsets against real gestures.
    FileHandle.standardError.write("nib: logging pen reports (Ctrl-C to stop)\n".data(using: .utf8)!)
    var transport: HIDTransport!
    transport = HIDTransport(
        vendorID: profile.vendorID, productID: profile.penPID,
        onAttach: { enableNativeMode(transport) },
        onReport: { reportID, payload in
            guard reportID == profile.pen.reportID, let s = PenReport.parse(payload, profile.pen) else { return }
            let line = String(format: "tiltX=%4d tiltY=%4d | tip=%d barrel=%d barrel2=%d eraser=%d prox=%d | x=%6d y=%6d p=%4d\n",
                              s.tiltX, s.tiltY,
                              s.tipDown ? 1 : 0, s.barrelButton ? 1 : 0, s.secondaryBarrel ? 1 : 0,
                              s.eraser ? 1 : 0, s.inRange ? 1 : 0, s.x, s.y, s.pressure)
            FileHandle.standardOutput.write(line.data(using: .utf8)!)
        })
    transport.start()
    CFRunLoopRun()

case "touchlog":
    // Raw-hex dump of the touch interface (PID 0x0355) to decode the finger report layout.
    FileHandle.standardError.write("nib: logging TOUCH reports (Ctrl-C to stop)\n".data(using: .utf8)!)
    var touchT: HIDTransport!
    touchT = HIDTransport(
        vendorID: profile.vendorID, productID: profile.touchPID,
        onAttach: {
            FileHandle.standardError.write("nib: TOUCH device opened; sending enable…\n".data(using: .utf8)!)
            enableTouch(touchT)
        },
        onReport: { reportID, payload in
            let hex = payload.map { String(format: "%02x", $0) }.joined(separator: " ")
            FileHandle.standardOutput.write(String(format: "id=0x%02x len=%3d | %@\n", reportID, payload.count, hex).data(using: .utf8)!)
        })
    touchT.start()
    CFRunLoopRun()

case "calibrate":
    // Two-point calibration: warp the cursor to a target, the user aligns the pen tip
    // and holds; we capture the raw pen coords, then derive the pen active-range that
    // spans the display and save it. Does NOT emit pen events (cursor stays on target).
    let bounds = cintiqDisplayBounds()
    func cerr(_ s: String) { FileHandle.standardError.write((s + "\n").data(using: .utf8)!) }
    let p1 = CGPoint(x: bounds.minX + 0.15 * bounds.width, y: bounds.minY + 0.15 * bounds.height)
    let p2 = CGPoint(x: bounds.minX + 0.85 * bounds.width, y: bounds.minY + 0.85 * bounds.height)

    var state = 0            // 0: hold P1, 1: lift, 2: hold P2
    var buf: [(Int, Int)] = []
    let K = 40, tol = 1200   // samples to confirm a steady hold; raw-unit spread tolerance
    var rawP1 = (0.0, 0.0)

    func mean(_ b: [(Int, Int)]) -> (Double, Double) {
        (b.reduce(0.0) { $0 + Double($1.0) } / Double(b.count),
         b.reduce(0.0) { $0 + Double($1.1) } / Double(b.count))
    }
    func stable(_ b: [(Int, Int)]) -> Bool {
        let xs = b.map { $0.0 }, ys = b.map { $0.1 }
        return (xs.max()! - xs.min()! < tol) && (ys.max()! - ys.min()! < tol)
    }
    func finish(_ rawP2: (Double, Double)) {
        let sx = (Double(p2.x) - Double(p1.x)) / (rawP2.0 - rawP1.0)
        let ox = Double(p1.x) - sx * rawP1.0            // screenX = sx*raw + ox
        let sy = (Double(p2.y) - Double(p1.y)) / (rawP2.1 - rawP1.1)
        let oy = Double(p1.y) - sy * rawP1.1
        let cal = Calibration(
            xMin: (Double(bounds.minX) - ox) / sx, xMax: (Double(bounds.maxX) - ox) / sx,
            yMin: (Double(bounds.minY) - oy) / sy, yMax: (Double(bounds.maxY) - oy) / sy)
        do { try cal.save(); cerr("nib: calibration saved to \(Calibration.fileURL.path)") }
        catch { cerr("nib: save failed: \(error)") }
        cerr(String(format: "nib: active raw range X[%.0f..%.0f] Y[%.0f..%.0f]",
                    cal.xMin, cal.xMax, cal.yMin, cal.yMax))
        exit(0)
    }

    CGWarpMouseCursorPosition(p1)
    cerr("nib: CALIBRATION — place the pen tip exactly on the cursor dot (upper-left area) and hold still…")
    var calTransport: HIDTransport!
    calTransport = HIDTransport(
        vendorID: profile.vendorID, productID: profile.penPID,
        onAttach: { enableNativeMode(calTransport) },
        onReport: { reportID, payload in
            guard reportID == profile.pen.reportID, let s = PenReport.parse(payload, profile.pen) else { return }
            if !s.tipDown || !s.inRange {
                if state == 1 { state = 2; CGWarpMouseCursorPosition(p2)
                    cerr("nib: point 1 captured. Now align the pen to the cursor (lower-right area) and hold…") }
                buf.removeAll(); return
            }
            guard state == 0 || state == 2 else { buf.removeAll(); return }
            buf.append((s.x, s.y)); if buf.count > K { buf.removeFirst() }
            if buf.count == K && stable(buf) {
                let m = mean(buf)
                if state == 0 { rawP1 = m; state = 1; buf.removeAll()
                    cerr("nib: got point 1 raw=(\(Int(m.0)),\(Int(m.1))). Lift the pen.") }
                else { finish(m) }
            }
        })
    calTransport.start()
    CFRunLoopRun()

case "run":
    // Pen -> cursor with pressure/tilt via CGEvent tablet events.
    // Posting synthetic events requires the process to be Accessibility-trusted.
    // Key value equals kAXTrustedCheckOptionPrompt; use the literal to stay Swift-6 safe.
    let opts = ["AXTrustedCheckOptionPrompt" as CFString: true] as CFDictionary
    let trusted = AXIsProcessTrustedWithOptions(opts)
    FileHandle.standardError.write("nib: Accessibility trusted = \(trusted)\n".data(using: .utf8)!)
    if !trusted {
        FileHandle.standardError.write("nib: NOT trusted — events will be dropped. Grant this binary Accessibility in System Settings, then relaunch.\n".data(using: .utf8)!)
    }
    var mapping = DisplayMapping(targetBounds: cintiqDisplayBounds())
    if let cal = Calibration.load() {
        cal.apply(to: &mapping)
        FileHandle.standardError.write("nib: loaded calibration \(Calibration.fileURL.path)\n".data(using: .utf8)!)
    } else {
        FileHandle.standardError.write("nib: no calibration found, using full pen range\n".data(using: .utf8)!)
    }
    let config = NibConfig.load()
    let emitter = EventEmitter(mapping: mapping)
    let touchGesture = TouchGestureEngine()
    // In-app calibration: captures raw pen coords at two on-screen targets, then applies.
    let calibration = CalibrationController(apply: { cal in
        let m = DisplayMapping(targetBounds: cintiqDisplayBounds(),
                               xMin: cal.xMin, xMax: cal.xMax, yMin: cal.yMin, yMax: cal.yMax)
        emitter.setMapping(m)
        try? cal.save()
    })
    // Touch coords (0..15360 x 0..8640) map to the Cintiq display for tap-to-click position.
    touchGesture.tapMapping = DisplayMapping(
        targetBounds: cintiqDisplayBounds(),
        xMin: 0, xMax: Double(profile.touch.xLogicalMax),
        yMin: 0, yMax: Double(profile.touch.yLogicalMax))
    var transport: HIDTransport!
    transport = HIDTransport(
        vendorID: profile.vendorID, productID: profile.penPID,
        onAttach: {
            FileHandle.standardError.write("nib: pen attached\n".data(using: .utf8)!)
            enableNativeMode(transport)
        },
        onReport: { reportID, payload in
            guard reportID == profile.pen.reportID, let s = PenReport.parse(payload, profile.pen) else { return }
            if calibration.isActive { calibration.feed(s); return }   // capture instead of emit
            emitter.handle(s)
            touchGesture.setPenInProximity(s.inRange)   // palm rejection gating
        })
    transport.start()

    // Touch: enable the sensor and drive 2-finger scroll (respecting the engine's enabled flag).
    var touch: HIDTransport!
    touch = HIDTransport(
        vendorID: profile.vendorID, productID: profile.touchPID,
        onAttach: {
            FileHandle.standardError.write("nib: touch attached\n".data(using: .utf8)!)
            enableTouch(touch)
        },
        onReport: { reportID, payload in
            guard !calibration.isActive else { return }   // ignore touch during calibration
            guard reportID == profile.touch.reportID, let f = TouchReport.parse(payload, profile.touch) else { return }
            touchGesture.handle(f)
        })
    touch.start()

    FileHandle.standardError.write("nib: running (needs Accessibility/Input-Monitoring permission)\n".data(using: .utf8)!)
    // Menu-bar agent: status item applies config live to the engines. NSApplication.run()
    // drives the main run loop, which the HID transports are scheduled on.
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    let statusBar = StatusBarController(config: config, emitter: emitter, touch: touchGesture, calibration: calibration)
    _ = statusBar   // retained for the process lifetime
    app.run()

default:
    FileHandle.standardError.write("usage: nib [run|log|calibrate]\n".data(using: .utf8)!)
    exit(2)
}

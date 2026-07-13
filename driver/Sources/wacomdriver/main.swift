import Foundation
import CoreGraphics
import ApplicationServices
import AppKit
import WacomDriverCore

// DTH2420k0 confirmed USB identity (from live HID enumeration).
let WACOM_VID: UInt16 = 0x056a
let PEN_PID:   UInt16 = 0x0351
let TOUCH_PID: UInt16 = 0x0355

let args = CommandLine.arguments
let mode = args.count > 1 ? args[1] : "run"

/// Locate the Cintiq's own display so the pen maps 1:1 onto the tablet surface.
/// The DTH2420 panel is 3840x2160 native; match on that, fall back to main display.
func cintiqDisplayBounds() -> CGRect {
    var count: UInt32 = 0
    CGGetActiveDisplayList(0, nil, &count)
    var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
    CGGetActiveDisplayList(count, &ids, &count)
    for id in ids {
        // Match on native pixel resolution (3840x2160); the panel may run HiDPI,
        // so CGDisplayBounds returns the point-space rect used for cursor mapping.
        guard let mode = CGDisplayCopyDisplayMode(id) else { continue }
        if mode.pixelWidth == 3840 && mode.pixelHeight == 2160 {
            let b = CGDisplayBounds(id)
            FileHandle.standardError.write("wacomdriver: mapping to Cintiq display id=\(id) bounds=\(b)\n".data(using: .utf8)!)
            return b
        }
    }
    FileHandle.standardError.write("wacomdriver: Cintiq display not found, using main display\n".data(using: .utf8)!)
    return CGDisplayBounds(CGMainDisplayID())
}

// Mode-switch recovered from CGD16GraphicsTablet::DeviceStart (see
// recon/decompile-CDTH2420.md). Buffers include the report-ID byte as data[0].
//   FEATURE 0x02 = [02 02] -> native high-res Wacom mode (report 0x10, 8192 pressure)
//   FEATURE 0x04 = [04 00] -> data-rate mode
func enableNativeMode(_ t: HIDTransport) {
    let okMode = t.sendFeature(reportID: 0x02, [0x02, 0x02])
    let okRate = t.sendFeature(reportID: 0x04, [0x04, 0x00])
    FileHandle.standardError.write(
        "wacomdriver: mode-switch sent (0x02=\(okMode ? "ok" : "FAIL"), 0x04=\(okRate ? "ok" : "FAIL"))\n"
            .data(using: .utf8)!)
}

// Touch enable — two 64-byte vendor OUTPUT reports (ID 0x06), recovered from
// CHIDInterface::SendConfigCommand (recon/decompile-touch-enable.md):
//   [0]=0x06 id, [1]=0x06, [2]=0x00, [3]=sub-cmd, [4]=value, rest 0.
//   sub-cmd 0x06 val 0x02 = enable multitouch;  sub-cmd 0x01 val 0x03 = HID+touch configure.
func enableTouch(_ t: HIDTransport) {
    func buf(_ sub: UInt8, _ val: UInt8) -> [UInt8] {
        var b = [UInt8](repeating: 0, count: 64)
        b[0] = 0x06; b[1] = 0x06; b[2] = 0x00; b[3] = sub; b[4] = val
        return b
    }
    let okMT  = t.sendOutput(reportID: 0x06, buf(0x06, 0x02))
    let okCfg = t.sendOutput(reportID: 0x06, buf(0x01, 0x03))
    FileHandle.standardError.write(
        "wacomdriver: touch-enable sent (multitouch=\(okMT ? "ok" : "FAIL"), configure=\(okCfg ? "ok" : "FAIL"))\n"
            .data(using: .utf8)!)
}

switch mode {
case "log":
    // Confirm report-0x10 field offsets against real gestures.
    FileHandle.standardError.write("wacomdriver: logging pen reports (Ctrl-C to stop)\n".data(using: .utf8)!)
    var transport: HIDTransport!
    transport = HIDTransport(
        vendorID: WACOM_VID, productID: PEN_PID,
        onAttach: { enableNativeMode(transport) },
        onReport: { reportID, payload in
            guard reportID == PenReport.reportID, let s = PenReport.parse(payload) else { return }
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
    FileHandle.standardError.write("wacomdriver: logging TOUCH reports (Ctrl-C to stop)\n".data(using: .utf8)!)
    var touchT: HIDTransport!
    touchT = HIDTransport(
        vendorID: WACOM_VID, productID: TOUCH_PID,
        onAttach: {
            FileHandle.standardError.write("wacomdriver: TOUCH device opened; sending enable…\n".data(using: .utf8)!)
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
        do { try cal.save(); cerr("wacomdriver: calibration saved to \(Calibration.fileURL.path)") }
        catch { cerr("wacomdriver: save failed: \(error)") }
        cerr(String(format: "wacomdriver: active raw range X[%.0f..%.0f] Y[%.0f..%.0f]",
                    cal.xMin, cal.xMax, cal.yMin, cal.yMax))
        exit(0)
    }

    CGWarpMouseCursorPosition(p1)
    cerr("wacomdriver: CALIBRATION — place the pen tip exactly on the cursor dot (upper-left area) and hold still…")
    var calTransport: HIDTransport!
    calTransport = HIDTransport(
        vendorID: WACOM_VID, productID: PEN_PID,
        onAttach: { enableNativeMode(calTransport) },
        onReport: { reportID, payload in
            guard reportID == PenReport.reportID, let s = PenReport.parse(payload) else { return }
            if !s.tipDown || !s.inRange {
                if state == 1 { state = 2; CGWarpMouseCursorPosition(p2)
                    cerr("wacomdriver: point 1 captured. Now align the pen to the cursor (lower-right area) and hold…") }
                buf.removeAll(); return
            }
            guard state == 0 || state == 2 else { buf.removeAll(); return }
            buf.append((s.x, s.y)); if buf.count > K { buf.removeFirst() }
            if buf.count == K && stable(buf) {
                let m = mean(buf)
                if state == 0 { rawP1 = m; state = 1; buf.removeAll()
                    cerr("wacomdriver: got point 1 raw=(\(Int(m.0)),\(Int(m.1))). Lift the pen.") }
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
    FileHandle.standardError.write("wacomdriver: Accessibility trusted = \(trusted)\n".data(using: .utf8)!)
    if !trusted {
        FileHandle.standardError.write("wacomdriver: NOT trusted — events will be dropped. Grant this binary Accessibility in System Settings, then relaunch.\n".data(using: .utf8)!)
    }
    var mapping = DisplayMapping(targetBounds: cintiqDisplayBounds())
    if let cal = Calibration.load() {
        cal.apply(to: &mapping)
        FileHandle.standardError.write("wacomdriver: loaded calibration \(Calibration.fileURL.path)\n".data(using: .utf8)!)
    } else {
        FileHandle.standardError.write("wacomdriver: no calibration found, using full pen range\n".data(using: .utf8)!)
    }
    let config = WacomConfig.load()
    let emitter = EventEmitter(mapping: mapping)
    let touchGesture = TouchGestureEngine()
    // Touch coords (0..15360 x 0..8640) map to the Cintiq display for tap-to-click position.
    touchGesture.tapMapping = DisplayMapping(
        targetBounds: cintiqDisplayBounds(),
        xMin: 0, xMax: Double(TouchContact.xLogicalMax),
        yMin: 0, yMax: Double(TouchContact.yLogicalMax))
    var transport: HIDTransport!
    transport = HIDTransport(
        vendorID: WACOM_VID, productID: PEN_PID,
        onAttach: {
            FileHandle.standardError.write("wacomdriver: pen attached\n".data(using: .utf8)!)
            enableNativeMode(transport)
        },
        onReport: { reportID, payload in
            guard reportID == PenReport.reportID, let s = PenReport.parse(payload) else { return }
            emitter.handle(s)
            touchGesture.setPenInProximity(s.inRange)   // palm rejection gating
        })
    transport.start()

    // Touch: enable the sensor and drive 2-finger scroll (respecting the engine's enabled flag).
    var touch: HIDTransport!
    touch = HIDTransport(
        vendorID: WACOM_VID, productID: TOUCH_PID,
        onAttach: {
            FileHandle.standardError.write("wacomdriver: touch attached\n".data(using: .utf8)!)
            enableTouch(touch)
        },
        onReport: { reportID, payload in
            guard reportID == TouchReport.reportID, let f = TouchReport.parse(payload) else { return }
            touchGesture.handle(f)
        })
    touch.start()

    FileHandle.standardError.write("wacomdriver: running (needs Accessibility/Input-Monitoring permission)\n".data(using: .utf8)!)
    // Menu-bar agent: status item applies config live to the engines. NSApplication.run()
    // drives the main run loop, which the HID transports are scheduled on.
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    let statusBar = StatusBarController(config: config, emitter: emitter, touch: touchGesture)
    _ = statusBar   // retained for the process lifetime
    app.run()

default:
    FileHandle.standardError.write("usage: wacomdriver [run|log|calibrate]\n".data(using: .utf8)!)
    exit(2)
}

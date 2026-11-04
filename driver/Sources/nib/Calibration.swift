import AppKit
import SwiftUI
import NibCore

/// Drives an in-app two-point pen calibration: a full-screen overlay on the Cintiq
/// shows crosshair targets; the user taps each with the pen; we capture the raw pen
/// coordinates, derive the active range, apply it live, and persist it.
final class CalibrationController: ObservableObject {
    @Published var targetFraction = CGPoint(x: 0.1, y: 0.1)
    @Published var instruction = ""
    @Published var pointLabel = ""

    private(set) var isActive = false
    private var window: NSWindow?
    private var escMonitor: Any?
    private var bounds: CGRect = .zero
    private let apply: (Calibration) -> Void
    /// The active device profile, used to locate the tablet's screen for the overlay.
    private let profile: () -> DeviceProfile

    // Target positions as a fraction of the display (inset from the corners).
    private let p1 = CGPoint(x: 0.1, y: 0.1)
    private let p2 = CGPoint(x: 0.9, y: 0.9)
    private var state = 0                 // 0: hold P1, 1: lift, 2: hold P2
    private var buf: [(Int, Int)] = []
    private var rawP1 = (0.0, 0.0)
    private let K = 40, tol = 1200

    init(profile: @escaping () -> DeviceProfile, apply: @escaping (Calibration) -> Void) {
        self.profile = profile
        self.apply = apply
    }

    func begin(bounds: CGRect) {
        self.bounds = bounds
        state = 0; buf.removeAll()
        targetFraction = p1; pointLabel = "Point 1 of 2"
        instruction = "Press the pen tip on the crosshair and hold still"
        isActive = true
        showWindow()
        escMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] e in
            if e.keyCode == 53 { self?.cancel() }   // Esc
        }
    }

    func cancel() { close() }

    /// Fed from the pen report stream while calibration is active.
    func feed(_ s: PenSample) {
        guard isActive else { return }
        if !s.tipDown || !s.inRange {
            if state == 1 {
                state = 2; targetFraction = p2; pointLabel = "Point 2 of 2"
                instruction = "Now press the second crosshair and hold"
            }
            buf.removeAll(); return
        }
        guard state == 0 || state == 2 else { buf.removeAll(); return }
        buf.append((s.x, s.y)); if buf.count > K { buf.removeFirst() }
        if buf.count == K && stable() {
            let m = mean()
            if state == 0 { rawP1 = m; state = 1; instruction = "Captured — lift the pen" }
            else { finish(m) }
        }
    }

    private func stable() -> Bool {
        let xs = buf.map { $0.0 }, ys = buf.map { $0.1 }
        return (xs.max()! - xs.min()! < tol) && (ys.max()! - ys.min()! < tol)
    }
    private func mean() -> (Double, Double) {
        (buf.reduce(0.0) { $0 + Double($1.0) } / Double(buf.count),
         buf.reduce(0.0) { $0 + Double($1.1) } / Double(buf.count))
    }

    private func finish(_ rawP2: (Double, Double)) {
        // raw = a*frac + b, solved from the two known target fractions.
        func range(_ r1: Double, _ r2: Double, _ f1: Double, _ f2: Double) -> (Double, Double) {
            let a = (r2 - r1) / (f2 - f1)
            let b = r1 - a * f1
            return (b, a + b)   // raw at frac 0, raw at frac 1
        }
        let (xMin, xMax) = range(rawP1.0, rawP2.0, Double(p1.x), Double(p2.x))
        let (yMin, yMax) = range(rawP1.1, rawP2.1, Double(p1.y), Double(p2.y))
        apply(Calibration(xMin: xMin, xMax: xMax, yMin: yMin, yMax: yMax))
        instruction = "Calibration saved"
        close()
    }

    /// The tablet's NSScreen, whose .frame is in Cocoa coordinates — CGDisplayBounds is
    /// Quartz (top-left origin) and would place the window off-screen.
    private func cintiqScreen() -> NSScreen? {
        guard let id = DisplayLocator.tabletDisplayID(for: profile()) else { return nil }
        return NSScreen.screens.first {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)
                .map { CGDirectDisplayID(truncating: $0) } == id
        }
    }

    // Called on the main thread (HID transports + menu actions run on the main run loop).
    private func showWindow() {
        let frame = (cintiqScreen() ?? NSScreen.main)?.frame ?? bounds
        let hosting = NSHostingController(rootView: CalibrationOverlay(controller: self))
        let w = NSWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
        w.contentViewController = hosting
        w.setFrame(frame, display: true)
        w.level = .screenSaver
        w.backgroundColor = .clear
        w.isOpaque = false
        w.ignoresMouseEvents = true           // pen still reaches us via the HID stream
        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
        w.orderFrontRegardless()
        window = w
    }

    private func close() {
        isActive = false
        if let m = escMonitor { NSEvent.removeMonitor(m); escMonitor = nil }
        window?.orderOut(nil); window = nil
    }
}

struct CalibrationOverlay: View {
    @ObservedObject var controller: CalibrationController
    var body: some View {
        GeometryReader { geo in
            ZStack {
                Color.black.opacity(0.55).ignoresSafeArea()
                VStack(spacing: 8) {
                    Text(controller.pointLabel).font(.title2).bold()
                    Text(controller.instruction).font(.title3)
                    Text("Press Esc to cancel").font(.callout).foregroundStyle(.white.opacity(0.7))
                }
                .foregroundStyle(.white)
                .position(x: geo.size.width / 2, y: geo.size.height * 0.28)

                Crosshair()
                    .position(x: controller.targetFraction.x * geo.size.width,
                              y: controller.targetFraction.y * geo.size.height)
            }
        }
    }
}

private struct Crosshair: View {
    var body: some View {
        ZStack {
            Circle().stroke(Color.red, lineWidth: 3).frame(width: 46, height: 46)
            Rectangle().fill(Color.red).frame(width: 2, height: 66)
            Rectangle().fill(Color.red).frame(width: 66, height: 2)
        }
    }
}

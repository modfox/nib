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
    private var solver: CalibrationSolver?

    init(profile: @escaping () -> DeviceProfile, apply: @escaping (Calibration) -> Void) {
        self.profile = profile
        self.apply = apply
    }

    func begin(bounds: CGRect) {
        self.bounds = bounds
        solver = CalibrationSolver(target1: p1, target2: p2, pen: profile().pen)
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
        guard isActive, var solver else { return }
        let event = solver.feed(s)
        self.solver = solver
        switch event {
        case .none: break
        case .firstCaptured:
            instruction = "Captured — lift the pen"
        case .awaitingSecond:
            targetFraction = p2; pointLabel = "Point 2 of 2"
            instruction = "Now press the second crosshair and hold"
        case .finished(let cal):
            apply(cal)
            instruction = "Calibration saved"
            close()
        case .rejected:
            targetFraction = p1; pointLabel = "Point 1 of 2"
            instruction = "Those points didn't look right — try again: press the first crosshair and hold"
        }
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

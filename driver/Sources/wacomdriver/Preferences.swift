import SwiftUI
import AppKit
import WacomDriverCore

/// Backing model for the preferences window. Edits flow back to the driver via callbacks.
final class PrefsModel: ObservableObject {
    @Published var curve: PressureCurve
    @Published var livePressure: Double = 0
    /// Called continuously while editing (apply to the live engine, no disk write).
    var onLive: ((PressureCurve) -> Void)?
    /// Called when an edit finishes (persist to disk).
    var onCommit: (() -> Void)?

    init(curve: PressureCurve) { self.curve = curve }

    func applyLive() { onLive?(curve) }
    func commit() { onCommit?() }
    func set(_ c: PressureCurve) { curve = c; applyLive(); commit() }
}

struct PreferencesView: View {
    @ObservedObject var model: PrefsModel

    private static let soft = PressureCurve(points: [.init(x: 0, y: 0), .init(x: 0.25, y: 0.45),
        .init(x: 0.5, y: 0.7), .init(x: 0.75, y: 0.88), .init(x: 1, y: 1)])
    private static let firm = PressureCurve(points: [.init(x: 0, y: 0), .init(x: 0.25, y: 0.1),
        .init(x: 0.5, y: 0.28), .init(x: 0.75, y: 0.55), .init(x: 1, y: 1)])

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Pen Pressure Curve").font(.headline)
            Text("Input pressure (→) mapped to output. Drag the middle points.")
                .font(.caption).foregroundStyle(.secondary)
            CurveEditor(curve: $model.curve, live: model.livePressure,
                        onLive: { model.applyLive() }, onCommit: { model.commit() })
                .frame(width: 320, height: 320)
            HStack(spacing: 8) {
                Button("Linear") { model.set(.linear) }
                Button("Soft") { model.set(Self.soft) }
                Button("Firm") { model.set(Self.firm) }
                Spacer()
                Text(String(format: "Live: %3.0f%%", model.livePressure * 100))
                    .monospacedDigit().foregroundStyle(.secondary)
            }
        }
        .padding(20)
        .frame(width: 360)
    }
}

/// Piecewise-linear curve editor. Endpoints are fixed; interior points drag freely
/// (kept ordered in x). A red dot shows the current live pressure on the curve.
struct CurveEditor: View {
    @Binding var curve: PressureCurve
    var live: Double
    var onLive: () -> Void
    var onCommit: () -> Void

    private func toView(_ p: PressureCurve.Point, _ w: CGFloat, _ h: CGFloat) -> CGPoint {
        CGPoint(x: p.x * w, y: (1 - p.y) * h)
    }

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            ZStack {
                RoundedRectangle(cornerRadius: 6).fill(Color.gray.opacity(0.08))
                Path { path in
                    for i in 1..<4 {
                        let f = CGFloat(i) / 4
                        path.move(to: CGPoint(x: f * w, y: 0)); path.addLine(to: CGPoint(x: f * w, y: h))
                        path.move(to: CGPoint(x: 0, y: f * h)); path.addLine(to: CGPoint(x: w, y: f * h))
                    }
                }.stroke(Color.gray.opacity(0.25), lineWidth: 0.5)
                Path { p in p.move(to: CGPoint(x: 0, y: h)); p.addLine(to: CGPoint(x: w, y: 0)) }
                    .stroke(Color.gray.opacity(0.35), style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
                Path { path in
                    let pts = curve.points.sorted { $0.x < $1.x }
                    guard let first = pts.first else { return }
                    path.move(to: toView(first, w, h))
                    for p in pts.dropFirst() { path.addLine(to: toView(p, w, h)) }
                }.stroke(Color.accentColor, lineWidth: 2)

                if live > 0.001 {
                    Circle().fill(Color.red).frame(width: 9, height: 9)
                        .position(toView(.init(x: live, y: curve.evaluate(live)), w, h))
                }

                ForEach(curve.points.indices, id: \.self) { i in
                    let isEnd = (i == 0 || i == curve.points.count - 1)
                    let dot = Circle()
                        .fill(isEnd ? Color.gray : Color.accentColor)
                        .frame(width: 13, height: 13)
                        .position(toView(curve.points[i], w, h))
                    if isEnd {
                        dot
                    } else {
                        dot.gesture(DragGesture()
                            .onChanged { g in
                                let lo = curve.points[i - 1].x + 0.03
                                let hi = curve.points[i + 1].x - 0.03
                                let nx = min(hi, max(lo, Double(g.location.x / w)))
                                let ny = min(1, max(0, 1 - Double(g.location.y / h)))
                                curve.points[i] = .init(x: nx, y: ny)
                                onLive()
                            }
                            .onEnded { _ in onCommit() })
                    }
                }
            }
        }
    }
}

/// Owns the single preferences window for the LSUIElement agent.
final class PreferencesWindowController {
    private var window: NSWindow?
    let model: PrefsModel
    var isShown: Bool { window?.isVisible ?? false }

    init(model: PrefsModel) { self.model = model }

    func show() {
        if window == nil {
            let hosting = NSHostingController(rootView: PreferencesView(model: model))
            let w = NSWindow(contentViewController: hosting)
            w.title = "Wacom Driver Preferences"
            w.styleMask = [.titled, .closable]
            w.isReleasedWhenClosed = false
            window = w
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.center()
        window?.makeKeyAndOrderFront(nil)
    }
}

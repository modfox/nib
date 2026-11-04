import SwiftUI
import AppKit
import NibCore

/// Backing model for the preferences window — holds the whole config. Edits flow back
/// to the driver via callbacks: `onLive` applies to the engines, `onCommit` also saves.
final class PrefsModel: ObservableObject {
    @Published var config: NibConfig
    @Published var livePressure: Double = 0
    var onLive: ((NibConfig) -> Void)?
    var onCommit: ((NibConfig) -> Void)?

    init(config: NibConfig) { self.config = config }

    func live() { onLive?(config) }                        // apply, no save (during a drag)
    func commit() { onLive?(config); onCommit?(config) }    // apply + save
}

/// Full settings window: mirrors the menu-bar quick toggles plus the pressure curve.
struct PreferencesView: View {
    @ObservedObject var model: PrefsModel
    var onRecalibrate: () -> Void

    private static let soft = PressureCurve(points: [.init(x: 0, y: 0), .init(x: 0.25, y: 0.45),
        .init(x: 0.5, y: 0.7), .init(x: 0.75, y: 0.88), .init(x: 1, y: 1)])
    private static let firm = PressureCurve(points: [.init(x: 0, y: 0), .init(x: 0.25, y: 0.1),
        .init(x: 0.5, y: 0.28), .init(x: 0.75, y: 0.55), .init(x: 1, y: 1)])

    /// Binding to a config field that applies + saves on change.
    private func bind<T>(_ kp: WritableKeyPath<NibConfig, T>) -> Binding<T> {
        Binding(get: { model.config[keyPath: kp] },
                set: { model.config[keyPath: kp] = $0; model.commit() })
    }

    private var naturalBinding: Binding<Bool> {
        Binding(get: { effectiveNatural() },
                set: { model.config.naturalScrolling = $0; model.commit() })
    }
    private func effectiveNatural() -> Bool { model.config.effectiveNaturalScrolling() }

    var body: some View {
        Form {
            Section("Touch") {
                Toggle("Touch Enabled", isOn: bind(\.touchEnabled))
                Toggle("Palm Rejection", isOn: bind(\.palmRejection))
                Toggle("Tap to Click", isOn: bind(\.tapToClick))
                Toggle("Three-Finger Swipe", isOn: bind(\.threeFingerSwipe))
                Toggle("Natural Scrolling", isOn: naturalBinding)
                Picker("Scroll Speed", selection: bind(\.scrollGain)) {
                    Text("Slow").tag(0.20); Text("Medium").tag(0.35); Text("Fast").tag(0.55)
                }.pickerStyle(.segmented)
            }

            Section("Pen") {
                Picker("Lower Side Button", selection: bind(\.lowerBarrel)) { buttonOptions }
                Picker("Upper Side Button", selection: bind(\.upperBarrel)) { buttonOptions }
                Button("Recalibrate…") { onRecalibrate() }
            }

            Section("Pen Pressure Curve") {
                CurveEditor(curve: bind(\.pressureCurve), live: model.livePressure,
                            onLive: { model.live() }, onCommit: { model.commit() })
                    .frame(height: 240)
                HStack(spacing: 8) {
                    Button("Linear") { model.config.pressureCurve = .linear; model.commit() }
                    Button("Soft") { model.config.pressureCurve = Self.soft; model.commit() }
                    Button("Firm") { model.config.pressureCurve = Self.firm; model.commit() }
                    Spacer()
                    Text(String(format: "Live: %3.0f%%", model.livePressure * 100))
                        .monospacedDigit().foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 420, height: 640)
    }

    @ViewBuilder private var buttonOptions: some View {
        Text("Right Click").tag(PenButtonAction.rightClick)
        Text("Middle Click").tag(PenButtonAction.middleClick)
        Text("Left Click").tag(PenButtonAction.leftClick)
        Text("Disabled").tag(PenButtonAction.none)
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
    private let onRecalibrate: () -> Void
    var isShown: Bool { window?.isVisible ?? false }

    init(model: PrefsModel, onRecalibrate: @escaping () -> Void) {
        self.model = model
        self.onRecalibrate = onRecalibrate
    }

    func show() {
        if window == nil {
            let hosting = NSHostingController(rootView: PreferencesView(model: model, onRecalibrate: onRecalibrate))
            let w = NSWindow(contentViewController: hosting)
            w.title = "Nib Preferences"
            w.styleMask = [.titled, .closable]
            w.isReleasedWhenClosed = false
            window = w
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.center()
        window?.makeKeyAndOrderFront(nil)
    }
}

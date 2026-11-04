import Foundation

/// Owns the pen + touch HID transports for whatever known tablet is connected and
/// re-resolves the active `DeviceProfile` on hotplug. One running instance can therefore
/// drive whichever supported model is plugged in — and switch if the hardware changes —
/// without restarting the process.
///
/// Design: a lightweight *watcher* transport per known vendor fires on any attach/detach.
/// Each event triggers `reconcile()`, which re-detects the connected profile and, if it
/// changed, tears down the old pen/touch pipeline and brings up one for the new device.
/// All UI/display concerns stay in the caller via `Handlers`.
public final class DeviceManager {
    public struct Handlers {
        /// A decoded pen sample from the active device.
        public var onPen: (PenSample) -> Void
        /// A decoded touch frame from the active device.
        public var onTouch: (TouchFrame) -> Void
        /// The active profile changed — to a new model, or to `nil` when the last known
        /// device was unplugged. Called on the run loop; use it to (re)build display maps.
        public var onProfileChange: (DeviceProfile?) -> Void
        /// Optional: result of sending a pen ("pen") or touch ("touch") enable sequence.
        public var onEnableResult: ((_ interface: String, _ results: [Bool]) -> Void)?

        public init(onPen: @escaping (PenSample) -> Void,
                    onTouch: @escaping (TouchFrame) -> Void,
                    onProfileChange: @escaping (DeviceProfile?) -> Void,
                    onEnableResult: ((String, [Bool]) -> Void)? = nil) {
            self.onPen = onPen
            self.onTouch = onTouch
            self.onProfileChange = onProfileChange
            self.onEnableResult = onEnableResult
        }
    }

    private let handlers: Handlers
    private var watchers: [HIDTransport] = []
    private var pen: HIDTransport?
    private var touch: HIDTransport?
    private var active: DeviceProfile?

    public init(handlers: Handlers) {
        self.handlers = handlers
    }

    /// The profile currently being driven, if any.
    public var activeProfile: DeviceProfile? { active }

    /// Begin watching for supported tablets and bring up whatever is already connected.
    /// Schedules on the current run loop; call `CFRunLoopRun()`/`NSApplication.run()` after.
    public func start() {
        let vendors = Set(DeviceProfile.all.map { $0.vendorID })
        for v in vendors {
            let watcher = HIDTransport(
                vendorID: v, productID: 0,               // any product for this vendor
                onAttach: { [weak self] in self?.reconcile() },
                onDetach: { [weak self] in self?.reconcile() })   // watch-only: no reports
            watcher.start()
            watchers.append(watcher)
        }
        reconcile()   // hardware already present at launch
    }

    public func stop() {
        watchers.forEach { $0.stop() }
        watchers.removeAll()
        teardownActive()
        active = nil
    }

    /// Re-detect the connected profile; swap the pen/touch pipeline if it changed.
    private func reconcile() {
        let detected = DeviceProfile.detectConnected().first
        if detected?.name == active?.name { return }   // no change → nothing to do
        teardownActive()
        active = detected
        if let p = detected { bringUp(p) }
        handlers.onProfileChange(detected)
    }

    private func teardownActive() {
        pen?.stop(); pen = nil
        touch?.stop(); touch = nil
    }

    private func bringUp(_ profile: DeviceProfile) {
        // Capture the transports weakly in their own closures: a transport retains its
        // onAttach/onReport, so a strong self-capture would cycle and leak the wrapper on
        // every hotplug swap (the C ctx is freed by stop(), but the Swift object would not).
        var penT: HIDTransport!
        penT = HIDTransport(
            vendorID: profile.vendorID, productID: profile.penPID,
            onAttach: { [weak self, weak penT] in
                guard let penT else { return }
                let results = penT.applyFeatures(profile.initSequence)
                self?.handlers.onEnableResult?("pen", results)
            },
            onReport: { [weak self] reportID, payload in
                guard reportID == profile.pen.reportID,
                      let sample = PenReport.parse(payload, profile.pen) else { return }
                self?.handlers.onPen(sample)
            })
        penT.start()
        pen = penT

        var touchT: HIDTransport!
        touchT = HIDTransport(
            vendorID: profile.vendorID, productID: profile.touchPID,
            onAttach: { [weak self, weak touchT] in
                guard let touchT else { return }
                let results = touchT.applyOutputs(profile.touchEnable)
                self?.handlers.onEnableResult?("touch", results)
            },
            onReport: { [weak self] reportID, payload in
                guard reportID == profile.touch.reportID,
                      let frame = TouchReport.parse(payload, profile.touch) else { return }
                self?.handlers.onTouch(frame)
            })
        touchT.start()
        touch = touchT
    }
}

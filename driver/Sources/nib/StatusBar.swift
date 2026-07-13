import AppKit
import NibCore

/// Menu-bar UI for the driver: a status item whose menu toggles touch and other
/// settings. Applies changes live to the running engines and persists the config.
final class StatusBarController: NSObject, NSMenuDelegate {
    private var config: NibConfig
    private let emitter: EventEmitter
    private let touch: TouchGestureEngine
    private let item: NSStatusItem
    private let prefsModel: PrefsModel
    private let prefs: PreferencesWindowController
    private let calibration: CalibrationController

    private static let speeds: [(String, Double)] = [("Slow", 0.20), ("Medium", 0.35), ("Fast", 0.55)]

    init(config: NibConfig, emitter: EventEmitter, touch: TouchGestureEngine, calibration: CalibrationController) {
        self.config = config
        self.emitter = emitter
        self.touch = touch
        self.calibration = calibration
        self.item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        self.prefsModel = PrefsModel(config: config)
        self.prefs = PreferencesWindowController(model: prefsModel,
                                                 onRecalibrate: { calibration.begin(bounds: cintiqDisplayBounds()) })
        super.init()
        if let button = item.button {
            button.image = NSImage(systemSymbolName: "hand.draw", accessibilityDescription: "Nib")
        }
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu

        // Preferences-window edits (full config) flow back to the driver.
        prefsModel.onLive = { [weak self] cfg in self?.config = cfg; self?.applyEngines() }
        prefsModel.onCommit = { [weak self] cfg in
            self?.config = cfg; self?.applyEngines(); try? self?.config.save()
        }
        // Feed live pressure to the prefs window (throttled, only while it is open).
        emitter.pressureObserver = { [weak self] p in
            guard let self, self.prefs.isShown else { return }
            if p == 0 || abs(p - self.prefsModel.livePressure) > 0.01 {
                self.prefsModel.livePressure = p
            }
        }
        apply()   // push loaded config into the engines
    }

    /// Effective natural-scrolling: explicit override, else the system setting.
    private func effectiveNatural() -> Bool {
        if let v = config.naturalScrolling { return v }
        if UserDefaults.standard.object(forKey: "com.apple.swipescrolldirection") != nil {
            return UserDefaults.standard.bool(forKey: "com.apple.swipescrolldirection")
        }
        return true
    }

    /// Push config into the live engines (no disk write).
    private func applyEngines() {
        touch.enabled = config.touchEnabled
        touch.palmRejection = config.palmRejection
        touch.tapToClick = config.tapToClick
        touch.threeFingerSwipe = config.threeFingerSwipe
        touch.scrollGain = config.scrollGain
        touch.naturalScrolling = effectiveNatural()
        emitter.lowerBarrelAction = config.lowerBarrel
        emitter.upperBarrelAction = config.upperBarrel
        emitter.pressureCurve = config.pressureCurve
    }

    /// Apply to the engines and persist. Also keeps the prefs window in sync.
    private func apply() {
        applyEngines()
        prefsModel.config = config
        try? config.save()
    }

    // Build the menu fresh each time it opens so checkmarks reflect current state.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let header = NSMenuItem(title: "Nib", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        menu.addItem(.separator())

        // Touch Enabled at top level for quick access.
        addCheck(menu, "Touch Enabled", config.touchEnabled, #selector(toggleTouch))

        // Remaining touch controls in a submenu.
        let touchItem = NSMenuItem(title: "Touch Controls", action: nil, keyEquivalent: "")
        let touchMenu = NSMenu()
        addCheck(touchMenu, "Palm Rejection", config.palmRejection, #selector(togglePalm))
        addCheck(touchMenu, "Tap to Click", config.tapToClick, #selector(toggleTap))
        addCheck(touchMenu, "3-Finger Swipe", config.threeFingerSwipe, #selector(toggleSwipe))
        addCheck(touchMenu, "Natural Scrolling", effectiveNatural(), #selector(toggleNatural))
        let speed = NSMenuItem(title: "Scroll Speed", action: nil, keyEquivalent: "")
        let speedMenu = NSMenu()
        for (i, s) in Self.speeds.enumerated() {
            let mi = radio(s.0, on: abs(config.scrollGain - s.1) < 0.001, #selector(setSpeed(_:)))
            mi.tag = i; speedMenu.addItem(mi)
        }
        speed.submenu = speedMenu
        touchMenu.addItem(speed)
        touchItem.submenu = touchMenu
        menu.addItem(touchItem)

        // Pen side buttons (top level).
        menu.addItem(buttonSubmenu("Lower Side Button", current: config.lowerBarrel, action: #selector(setLower(_:))))
        menu.addItem(buttonSubmenu("Upper Side Button", current: config.upperBarrel, action: #selector(setUpper(_:))))

        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Preferences…", action: #selector(openPrefs), keyEquivalent: ","))
        menu.addItem(NSMenuItem(title: "Recalibrate…", action: #selector(recalibrate), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Open Config File", action: #selector(openConfig), keyEquivalent: ""))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Restart Driver", action: #selector(restartDriver), keyEquivalent: "r"))
        menu.addItem(NSMenuItem(title: "Quit Driver", action: #selector(quit), keyEquivalent: "q"))
        for mi in menu.items where mi.action != nil { mi.target = self }
    }

    private static let actions: [(String, PenButtonAction)] =
        [("Right Click", .rightClick), ("Middle Click", .middleClick), ("Left Click", .leftClick), ("Disabled", .none)]

    private func buttonSubmenu(_ title: String, current: PenButtonAction, action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        let sub = NSMenu()
        for (i, a) in Self.actions.enumerated() {
            let mi = radio(a.0, on: a.1 == current, action); mi.tag = i
            mi.target = self; sub.addItem(mi)
        }
        item.submenu = sub
        return item
    }

    private func addCheck(_ menu: NSMenu, _ title: String, _ on: Bool, _ action: Selector) {
        let mi = NSMenuItem(title: title, action: action, keyEquivalent: "")
        mi.state = on ? .on : .off
        mi.target = self          // works at any submenu depth
        menu.addItem(mi)
    }
    private func radio(_ title: String, on: Bool, _ action: Selector) -> NSMenuItem {
        let mi = NSMenuItem(title: title, action: action, keyEquivalent: "")
        mi.state = on ? .on : .off
        mi.target = self
        return mi
    }

    // MARK: - Actions
    @objc private func toggleTouch() { config.touchEnabled.toggle(); apply() }
    @objc private func togglePalm() { config.palmRejection.toggle(); apply() }
    @objc private func toggleTap() { config.tapToClick.toggle(); apply() }
    @objc private func toggleSwipe() { config.threeFingerSwipe.toggle(); apply() }
    @objc private func toggleNatural() { config.naturalScrolling = !effectiveNatural(); apply() }
    @objc private func setSpeed(_ sender: NSMenuItem) { config.scrollGain = Self.speeds[sender.tag].1; apply() }
    @objc private func setLower(_ sender: NSMenuItem) { config.lowerBarrel = Self.actions[sender.tag].1; apply() }
    @objc private func setUpper(_ sender: NSMenuItem) { config.upperBarrel = Self.actions[sender.tag].1; apply() }
    @objc private func openPrefs() { prefsModel.config = config; prefs.show() }
    @objc private func openConfig() {
        try? config.save()
        NSWorkspace.shared.open(NibConfig.fileURL)
    }
    @objc private func recalibrate() {
        calibration.begin(bounds: cintiqDisplayBounds())
    }
    /// Restart via launchd: kickstart -k kills this instance and relaunches a fresh one.
    /// Useful if the driver ever hangs or the tablet stops responding.
    @objc private func restartDriver() {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        task.arguments = ["kickstart", "-k", "gui/\(getuid())/com.modfox.nib"]
        try? task.run()
    }

    @objc private func quit() { NSApp.terminate(nil) }
}

import AppKit
import WacomDriverCore

/// Menu-bar UI for the driver: a status item whose menu toggles touch and other
/// settings. Applies changes live to the running engines and persists the config.
final class StatusBarController: NSObject, NSMenuDelegate {
    private var config: WacomConfig
    private let emitter: EventEmitter
    private let touch: TouchGestureEngine
    private let item: NSStatusItem

    private static let speeds: [(String, Double)] = [("Slow", 0.20), ("Medium", 0.35), ("Fast", 0.55)]

    init(config: WacomConfig, emitter: EventEmitter, touch: TouchGestureEngine) {
        self.config = config
        self.emitter = emitter
        self.touch = touch
        self.item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()
        if let button = item.button {
            button.image = NSImage(systemSymbolName: "hand.draw", accessibilityDescription: "Wacom Driver")
        }
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
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

    /// Push config into the live engines and persist it.
    private func apply() {
        touch.enabled = config.touchEnabled
        touch.palmRejection = config.palmRejection
        touch.tapToClick = config.tapToClick
        touch.threeFingerSwipe = config.threeFingerSwipe
        touch.scrollGain = config.scrollGain
        touch.naturalScrolling = effectiveNatural()
        emitter.lowerBarrelAction = config.lowerBarrel
        emitter.upperBarrelAction = config.upperBarrel
        try? config.save()
    }

    // Build the menu fresh each time it opens so checkmarks reflect current state.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let header = NSMenuItem(title: "Wacom DTH2420 Driver", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        menu.addItem(.separator())

        addCheck(menu, "Touch Enabled", config.touchEnabled, #selector(toggleTouch))
        addCheck(menu, "Palm Rejection", config.palmRejection, #selector(togglePalm))
        addCheck(menu, "Tap to Click", config.tapToClick, #selector(toggleTap))
        addCheck(menu, "3-Finger Swipe", config.threeFingerSwipe, #selector(toggleSwipe))
        addCheck(menu, "Natural Scrolling", effectiveNatural(), #selector(toggleNatural))

        let speed = NSMenuItem(title: "Scroll Speed", action: nil, keyEquivalent: "")
        let speedMenu = NSMenu()
        for (i, s) in Self.speeds.enumerated() {
            let mi = radio(s.0, on: abs(config.scrollGain - s.1) < 0.001, #selector(setSpeed(_:)))
            mi.tag = i; mi.target = self; speedMenu.addItem(mi)
        }
        speed.submenu = speedMenu
        menu.addItem(speed)

        menu.addItem(buttonSubmenu("Lower Side Button", current: config.lowerBarrel, action: #selector(setLower(_:))))
        menu.addItem(buttonSubmenu("Upper Side Button", current: config.upperBarrel, action: #selector(setUpper(_:))))

        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Recalibrate…", action: #selector(recalibrate), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Open Config File", action: #selector(openConfig), keyEquivalent: ""))
        menu.addItem(.separator())
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
        menu.addItem(mi)
    }
    private func radio(_ title: String, on: Bool, _ action: Selector) -> NSMenuItem {
        let mi = NSMenuItem(title: title, action: action, keyEquivalent: "")
        mi.state = on ? .on : .off
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
    @objc private func openConfig() {
        try? config.save()
        NSWorkspace.shared.open(WacomConfig.fileURL)
    }
    @objc private func recalibrate() {
        let a = NSAlert()
        a.messageText = "Recalibrate the pen"
        a.informativeText = "Quit the driver, then run:\n\n  wacomdriver calibrate\n\nfollow the on-screen cursor with the pen, then relaunch the driver."
        a.runModal()
    }
    @objc private func quit() { NSApp.terminate(nil) }
}

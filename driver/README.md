# nib — standalone macOS driver for the Cintiq Pro 24 Touch (DTH2420k0)

A clean-room, from-scratch userspace driver. **No dependency on OpenTabletDriver or the
stock vendor driver.** Pen protocol was decoded from the device's own HID report descriptor
(see `../spec/DTH2420-protocol.md`). Architecture mirrors the stock stack: read HID with
`IOHIDManager`, decode reports in pure Swift, inject `CGEvent` tablet events.

## Layout
- `Sources/CNibHID` — thin C shim over `IOHIDManager` (device open + raw report delivery + feature reports).
- `Sources/NibCore` — pure-Swift, hardware-independent, unit-tested:
  - `PenReport.swift` — decode HID report 0x10 → `PenSample` (X/Y 24-bit, pressure 0–8191, tilt ±64, buttons, serial).
  - `DisplayMapping.swift` — tablet logical coords → screen points.
  - `EventEmitter.swift` — `PenSample` → CGEvent tablet pointer + proximity events.
  - `HIDTransport.swift` — Swift wrapper over the C shim.
- `Sources/nib` — the daemon (`run` and `log` modes).
- `Tests/` — parser + mapping unit tests (no hardware needed).

## Build & test
```
swift build
swift test
```

## Run
```
# Confirm the report layout against real gestures (prints decoded samples):
.build/debug/nib log

# Drive the cursor with pressure/tilt (needs Accessibility + Input Monitoring grants):
.build/debug/nib run
```
Grant the built binary **Input Monitoring** and **Accessibility** in System Settings ›
Privacy & Security the first time. For a clean capture, temporarily unload the stock
vendor agents so they don't seize the interface:
```
launchctl bootout gui/$(id -u)/com.wacom.wacomtablet 2>/dev/null
# re-enable later: open "/Applications/Wacom Tablet.localized/.Tablet/WacomTabletDriver.app"
```

## Features
- **Pen:** absolute position with in-app 2-point calibration; pressure (0–8191) shaped by an
  adjustable response curve; tilt; side buttons (lower → right-click, upper → middle-click, remappable).
- **Touch:** 2-finger scroll, tap-to-click, 3-finger swipe (Mission Control / spaces / App Exposé),
  and palm rejection — all toggleable.
- **UI:** a menu-bar app with quick toggles, a full Preferences window (all settings + a draggable
  pressure-curve editor with live feedback), and an in-app calibration overlay.
- **Runtime:** persistent LaunchAgent (auto-start, KeepAlive), stable self-signed code signing so
  Privacy grants survive rebuilds, injection via the userspace CGEvent path — no kernel extension.

Protocol details (USB IDs, pen report `0x10`, touch report `0x81`, the pen mode-switch and touch
enable sequences) are in [`../spec/DTH2420-protocol.md`](../spec/DTH2420-protocol.md).
Planned work is tracked in [`../ROADMAP.md`](../ROADMAP.md).

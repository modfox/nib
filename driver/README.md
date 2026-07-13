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

## Status
- [x] USB IDs confirmed (VID 0x056a, pen PID 0x0351, touch PID 0x0355).
- [x] Pen report 0x10 decoded + **confirmed against live raw captures**; parser unit-tested on real reports.
- [x] **Mode-switch wired + verified live** (FEATURE 0x02=`02 02`, 0x04=`04 00`; SetReport succeeded, native mode engaged — 6.6k report-0x10 packets flowed).
- [x] HID open + CGEvent emitter pipeline compiles and runs.
- [x] **End-to-end `run` verified live**: cursor tracks the pen on the Cintiq, and **pressure varies
      line thickness** in pressure-aware apps. Sets both `mouseEventPressure` (NSEvent.pressure) and
      `tabletEventPointPressure`, with pressure/tilt advertised in the proximity capability mask.
- [x] Detect + map to the Cintiq's own display (matches native 3840x2160 mode; maps to its bounds).
- [x] **Calibration** — in-app overlay (menu → Recalibrate…): full-screen crosshair targets on
      the Cintiq, tap two points with the pen, applies + saves live. Also the CLI `nib
      calibrate`. Saved to `~/.config/nib/calibration.json`; `run` loads it.
- [x] **Persistence/packaging** — installed as `~/Applications/Nib.app` + LaunchAgent
      `com.modfox.nib` (auto-start, KeepAlive). Stock agents permanently disabled. Requires
      the `.app` bundle for TCC Accessibility to work. See `INSTALL.md`. Running clean, verified live.
- [x] **Touch — raw HID** (PID 0x0355). The vendor MultiTouch framework was a dead end here
      (`WMTErrorDriverNotFound` — depends on the broken stock daemon), so touch uses raw HID:
      enable via two vendor OUTPUT reports (ID 0x06), parse report 0x81 (up to 10 contacts),
      **2-finger scroll** via CGScrollWheel, direction/speed matched to the system setting.
- [x] **Stable code signing** — signed with self-signed `modfox-codesign` identity so TCC grants
      persist across rebuilds (verified). No more re-granting on each build.
- [x] **Tilt/barrel verified** — tiltX +right/-left, tiltY +bottom/-top (±64); lower button =
      barrelButton, upper = secondaryBarrel. Side buttons wired (lower→right-click, upper→middle-click).
- [x] **Settings menu-bar app** — status-item menu: Touch Enabled, Natural Scrolling, Scroll Speed,
      Lower/Upper Side Button remap, Recalibrate, Open Config. Persists to `~/.config/nib/config.json`,
      applied live to the engines.
- [x] **Palm rejection** — suppresses touch while the pen is in proximity (+0.6s cooldown after
      lift); menu-toggleable. Pen proximity is fed from the pen report stream into the touch engine.
- [x] **Tap-to-click** — quick single-finger tap → left click at the tapped point (touch coords
      mapped to the display); menu-toggleable. Guards on duration + movement + single finger.
- [x] **3-finger swipe** — up→Mission Control, down→App Exposé, left/right→switch spaces.
      Fired via `osascript`/System Events (raw CGEvent didn't trigger these system shortcuts),
      so it needs a one-time **Automation** permission grant. Menu-toggleable. Scroll is
      suppressed for any touch that reaches 3 fingers (plus a 60ms settle) so swipes don't leak scroll.
- [x] **Unified Preferences window** — full settings UI (menu → Preferences…): Touch section
      (enable, palm rejection, tap-to-click, 3-finger swipe, natural scrolling, scroll speed),
      Pen section (side-button remap, Recalibrate), and a draggable pressure-curve editor with
      Linear/Soft/Firm presets + live pressure dot. Menu-bar quick toggles are kept for fast access;
      both write the same `NibConfig` and apply live.
- [ ] ExpressKeys / touch-ring (pen report 0x11/0x13).
- [ ] Stretch: phased/gesture scroll for Safari swipe-navigation (plain scroll for now); pinch-zoom.
- [ ] Developer ID signing + notarization (for distributing to other machines).

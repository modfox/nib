# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

**Nib** is a clean-room, userspace macOS driver for Wacom pen displays: it reads the tablet's
HID reports, decodes them in pure Swift and injects CoreGraphics events. No kernel extension
and no vendor software at runtime. The reference device is the Cintiq Pro 24 Touch (DTH2420).
`README.md` has the overview; the Swift package is in `driver/`.

## Clean-room rules

- **Never commit vendor code, binaries or assets.** Wacom's binaries in `recon/*.arm64` are
  gitignored local copies, for reverse engineering only. What was learned goes into
  `recon/*.md` (findings) and `spec/DTH2420-protocol.md` (the protocol), described from the
  device's observable behaviour.
- "Wacom" and model names appear only to identify compatible hardware: keep the app, the
  bundle ID (`com.modfox.nib`) and the code free of vendor branding.

## Commands

Run from `driver/`:

| Command | What it does |
| --- | --- |
| `swift build` | Builds every product, including the `nib` app target. CI runs this |
| `swift test` | `NibCoreTests` (XCTest), no hardware needed. CI runs this |
| `swift test --filter PenReportTests` | One test class (or `PenReportTests/testName`) |
| `.build/debug/nib log` / `touchlog` | Print decoded pen samples / raw touch hex, to check layouts against real gestures |
| `.build/debug/nib run` | The driver: menu-bar app, drives the cursor (needs Input Monitoring + Accessibility) |
| `.build/debug/nib calibrate` | Two-point pen calibration, saved to `~/.config/nib/calibration.json` |
| `.build/debug/nib capture [--send-enable]` | Raw hex from every interface of known vendors, for bringing up a new device |
| `scripts/build-app.sh` | Universal release build, assembled into an unsigned `build/Nib.app` |

- **Install and update** as a signed `.app` plus a per-user LaunchAgent: `driver/INSTALL.md`.
  Sign with the stable `modfox-codesign` identity, never ad hoc (`-s -`): an ad-hoc signature
  changes the code hash and resets the Privacy (TCC) grants on every rebuild.
- **The installed agent holds the tablet.** Stop it before `calibrate`
  (`launchctl bootout gui/$(id -u)/com.modfox.nib`), and reload it after. Its log is
  `~/Library/Logs/nib.log`.
- **Releases:** a `v*` tag builds a Developer ID–signed, notarized DMG (`driver/RELEASING.md`,
  `scripts/release.sh`). The workflow stays dormant unless the repo variable
  `RELEASE_ENABLED` is `true`.

## Architecture

Three targets in `driver/Package.swift`:

- **`CNibHID`**: a thin C shim over `IOHIDManager` (open devices, raw input reports, feature
  and output writes).
- **`NibCore`**: everything that can be tested without hardware or permissions. No AppKit.
- **`nib`**: the executable. `main.swift` dispatches on its mode (`run`, `log`, `touchlog`,
  `calibrate`, `capture`); the rest is the menu-bar UI (`StatusBar`, `Preferences`, the
  calibration overlay). It's a single-threaded AppKit agent: everything, HID callbacks
  included, runs on the main run loop, so this target builds in Swift 5 language mode.

The `run` pipeline:

1. **`DeviceManager`** watches each known vendor for attach/detach. On every event it re-resolves
   the connected `DeviceProfile` and, if the profile changed, tears down the pen and touch
   `HIDTransport`s and brings up new ones. On attach it sends the profile's pen mode-switch
   (`initSequence`) and touch enable (`touchEnable`).
2. **`PenReport` / `TouchReport`** decode raw reports using the active profile's `PenLayout` /
   `TouchLayout` into `PenSample` / `TouchFrame`.
3. **Pen:** `EventEmitter` maps a sample through `DisplayMapping` (and `PressureCurve`) to
   CGEvent tablet pointer and proximity events. Before a press, `main.swift` activates the
   app under the pen: a synthesized click doesn't, and only the frontmost app receives
   proximity (pen vs eraser).
   **Touch:** `TouchGestureEngine` turns frames into scrolling, tap-to-click, 3-finger swipes
   and palm rejection (gated by pen proximity).
4. Both post through an **`EventSink`**: `SystemEventSink` in production, a recorder in tests.

- **Display mapping:** `DisplayLocator` finds the tablet's own screen by EDID, then by the
  profile's `panelSize`, falling back to the main display. Mappings are rebuilt on profile
  changes, after calibration, and on display reconfiguration, because on replug the panel
  often registers after the HID interface.
- **Settings:** `NibConfig` lives in `~/.config/nib/config.json` and decodes with
  `decodeIfPresent` plus a default for every field, so older files keep loading. A new
  setting needs the same treatment. `StatusBarController` applies changes live to the
  emitter and the gesture engine.

## Device profiles: a model is data, not code

Everything model-specific (USB IDs, report byte offsets and logical maxima, the mode-switch,
touch enable, panel size) is in `DeviceProfile` (`NibCore/DeviceProfile.swift`). Don't branch
on a model in the decode, emit or gesture code: extend the profile instead.

Adding a model (`docs/ADDING-A-DEVICE.md`): add a `DeviceProfile` literal, register it in
`DeviceProfile.all`, and add a fixture bundle of real captured reports to
`Tests/NibCoreTests/DeviceFixtures.swift`. `ProfileConformanceTests` then checks every
profile against its fixtures, with no per-device test code. This is how a profile is
accepted without the hardware.

## Tests

`Tests/NibCoreTests/` covers `NibCore` only. Parsers are tested against real captured
report bytes. The emitter and gesture state machines are tested through `RecordingSink`
and the manually advanced `TestClock` (`TestSupport.swift`), so tests never need
Accessibility or move the real cursor. Logic added to `nib` can't be tested, so keep new
logic in `NibCore`.

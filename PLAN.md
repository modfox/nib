# Plan: A Standalone Open Driver for the Wacom Cintiq Pro 24 Touch (DTH2420k0)

**Goal:** an independent, maintainable macOS driver for the DTH2420k0 providing pen
(position, pressure, tilt, buttons), multitouch, and ExpressKey/button input — built
from a reverse-engineered protocol spec. **Not** an OpenTabletDriver plugin/config;
OTD is used only as a *reference technique*. Standalone deliverable.

**Legality/ethics:** interoperability RE of hardware you own, to make it work — the same
category as OpenTabletDriver / Linux `wacom.ko`. Keep it **clean-room**: document
*behavior and protocol*, do not copy Wacom's proprietary source or assets.

> Phase 0 (recon) is **already done** — see [`recon/FINDINGS.md`](recon/FINDINGS.md).
> The architecture below is grounded in those verified findings, not assumptions.

---

## What Phase 0 already established (so the plan is concrete)

- Stock stack is **userspace + sandboxed** (no kext / no system extension). Our driver can
  be a userspace daemon too — **no kernel or DriverKit signing required** for a working driver.
- Driver core is **unstripped C++**: base `CGraphicsTablet` → **`CDTH2420GraphicsTablet`**
  (exact class for this device), pen `C*PressureStylus/*Pen`, controls `C*TabletControls`,
  transport `CMacHIDCommInterface`/`CCommInterface`, top `CMacTabletDriver`.
- Input is injected via the **CoreGraphics tablet-event path** (`CGEventCreate` +
  `kCGEventTabletProximity`/`kCGTabletEventPointData`, seen as `NXTabletPointData`/`ProximityEvent`).
- **Touch has a public SDK**: `WacomMultiTouch.framework` with headers
  (`WacomMTRegisterFingerReadCallback` → `WacomMTFingerCollection`).
- USB VID `0x056a`; the DTH2420k0 **PID must be confirmed live** (tablet was unplugged).

**Decision this enables:** target a **userspace Swift/C++ daemon**:
`IOHIDManager` (USB HID read) → report parser (from RE) → `CGEvent` tablet-event post,
with touch via `WacomMultiTouch` framework (v1) or raw HID (v2). This mirrors the stock
architecture exactly and is the lowest-risk path to a working driver.

---

## Phase 1 — Toolchain & workspace setup
**Objective:** everything needed to decompile and to capture live HID, installed and verified.

- Install: Ghidra (primary, free, great C++ demangling) **and/or** Hopper/Binary Ninja;
  `radare2`/`rizin`; keep Apple `otool`/`nm`/`class-dump`/`dsdump`.
- Live-capture tooling: Xcode + `usbdump`/`PacketLogger` (Apple "Additional Tools for Xcode"),
  Wireshark w/ macOS USB (`XHC`/`usbmon`-equivalent via `ktrace`/`PacketLogger`), `hidutil`,
  `ioreg`, IORegistryExplorer, `lldb`, `dtrace` (note: SIP must be considered for dtrace on
  Apple-signed procs; our own procs are fine).
- Set up a Ghidra project; import **both** `WacomTabletDriver` (arm64 slice) and
  `Wacom_IOManager`. Split the fat binary first: `lipo -thin arm64 … -output …`.
- **Checkpoint:** Ghidra auto-analysis completes; `CDTH2420GraphicsTablet` methods appear
  named in the symbol tree; a USB capture tool can see *some* HID device end-to-end.

**Artifacts:** `recon/tools.md` (versions, install notes), Ghidra project.

---

## Phase 2 — Static analysis / decompilation (the core RE)
**Objective:** recover the DTH2420 pen protocol and event mapping from the binary.

Order of attack (leverages the unstripped symbols):
1. **Device identity & matching.** Find `CDTH2420GraphicsTablet` ctor + its registration;
   recover its USB **PID(s)**, interface/usage matching, and any init/mode-switch feature
   reports it sends on connect (the "enable full pen/tablet mode" command — Wacom devices
   boot in a HID-mouse compatibility mode and must be switched).
2. **Report parser.** Trace from `CMacHIDCommInterface` read path → the per-model
   `CDTH2420GraphicsTablet` / its stylus class parse routines. Recover the **input report
   layout**: report IDs, byte offsets and bit widths for X, Y, pressure, tilt X/Y, proximity,
   tip/barrel-button bits, tool/serial, and the transducer-type encoding.
3. **Ranges & transforms.** Extract logical max for X/Y, pressure (likely 0–8191 or 0–65535),
   tilt range, and any smoothing/normalization applied before posting.
4. **ExpressKeys / touch ring / controls.** From `C*TabletControls` recover the button/ring
   report layout for the DTH2420's on-tablet controls.
5. **Injection mapping.** Confirm exactly which `CGEvent`/tablet fields the stock code fills
   (proximity enter/leave, point data, buttons, pressure scaling) so our output matches app
   expectations (Photoshop, etc.).
6. Cross-check ambiguous fields against the **Linux kernel `wacom_wac.c`** and **OpenTabletDriver's**
   Wacom Intuos/Cintiq report parsers (reference only) — they document many shared Wacom report
   formats and resolve guesswork fast.

**Checkpoint:** a written, byte-level **draft** report spec for pen + controls, with every
field either confirmed from code or flagged "verify live."

**Artifacts:** `spec/pen-report.md` (draft), annotated Ghidra DB, `docs/class-map.md`.

---

## Phase 3 — Dynamic analysis / live capture (confirm the spec)
**Objective:** validate and fill gaps in the draft spec against the real device.
**Requires the DTH2420k0 plugged in.**

- Enumerate: `ioreg -p IOUSB -l` and `hidutil list` → record **VID/PID, interfaces, usage
  pages**, and dump the **HID report descriptor** (via `IOHIDDeviceGetProperty`
  `kIOHIDReportDescriptorKey`, small helper tool).
- Capture raw input reports while performing scripted gestures:
  pen hover, tip press with slow **pressure ramp**, tilt sweeps X and Y, barrel-button
  clicks, each ExpressKey, touch-ring/strip, and multitouch (1–10 fingers).
  Log with a minimal `IOHIDManager` reader (`captures/hidtap`) → newline-hex per report.
- Diff observed bytes against the Phase-2 draft; nail down endianness, exact bit boundaries,
  pressure/tilt scaling, and the init/mode-switch (capture the feature report the stock driver
  sends — observe with USB capture while `TabletDriver` starts, or replay-test candidates).
- Record touch via **`WacomMultiTouch`** sample (finger collection) for the supported path,
  AND raw HID for the from-scratch path.

**Checkpoint:** every field in the spec is confirmed live; a captured, replayable
init sequence brings the tablet into full pen mode.

**Artifacts:** `captures/*.hexlog`, `spec/report-descriptor.txt`, updated `spec/pen-report.md`.

---

## Phase 4 — Protocol specification (the deliverable that outlives the binary)
**Objective:** a complete, implementation-ready device spec, independent of Wacom code.

Contents:
- USB: VID `0x056a`, confirmed PID(s), interface/endpoint map, HID report descriptor.
- Init/mode-switch feature report(s) and any keep-alive.
- Pen input report(s): full field table (offset/size/encoding/range) for X, Y, pressure,
  tilt X/Y, proximity, tool type, serial, tip + button bits.
- Controls report(s): ExpressKeys, touch ring/strip encodings.
- Touch: both the `WacomMultiTouch` capability/finger model **and** the raw HID digitizer
  report layout.
- Coordinate → screen mapping notes (the DTH2420 is a 3840×2160 display tablet; full-desktop
  vs display-mapped).

**Checkpoint:** spec is complete enough that someone could implement the driver from it
with **no further reference to the binary**. (This is the clean-room boundary.)

**Artifacts:** `spec/DTH2420-protocol.md` (v1.0).

---

## Phase 5 — Standalone driver implementation
**Objective:** an independent codebase. **No dependency on OpenTabletDriver** at build or runtime.

Recommended shape (mirrors the proven stock architecture, minimal moving parts):
- **Language:** Swift + a small C/C++ shim for HID, or pure C++/ObjC++. Swift Package /
  Xcode project. Self-contained; its own minimal config model tailored to the DTH2420
  (not OTD's schema), extensible to other Wacom models later.
- **Modules:**
  1. `HIDTransport` — `IOHIDManager` open/match (VID `0x056a`/PID), send init report,
     receive input reports. (Sandboxed `com.apple.security.device.usb` if sandboxed, or
     unsandboxed dev build first.)
  2. `ReportParser` — pure function: raw report bytes → typed `PenSample`/`TouchSample`/
     `ControlEvent`, straight from `spec/DTH2420-protocol.md`.
  3. `EventEmitter` — `CGEventCreate` tablet events: proximity (enter/leave, tool caps),
     point data (X/Y, pressure, tilt, buttons). This is the path the stock driver uses.
  4. `TouchInput` — v1: consume `WacomMultiTouch.framework`; v2: raw HID digitizer parse.
  5. `Controls` — ExpressKeys/touch-ring → keystrokes/mouse/modifiers, user-mappable.
  6. `Config` — pressure curve, tablet→display mapping, button bindings (simple JSON/plist).
  7. `daemon` — LaunchAgent, device attach/detach handling, logging.
- **macOS input path decision:** userspace `CGEvent` (as stock) is v1. Only escalate to a
  DriverKit/HIDDriverKit **virtual HID** device (needs a system-extension entitlement from
  Apple + notarization) if `CGEvent` proves insufficient for some app — flagged as a later
  decision, not v1 scope.
- **Signing/SIP notes:** dev builds can run unsandboxed with Input Monitoring +
  Accessibility permissions granted; distribution needs Developer ID + notarization. Posting
  CGEvents requires the **Accessibility/Input-Monitoring** grant. No SIP disable needed for
  the userspace path.

**Checkpoint (MVP):** pen moves the cursor with pressure in a paint app; then tilt, buttons,
ExpressKeys, touch, each landing incrementally.

**Artifacts:** the `driver/` codebase, `README`, `LICENSE`.

---

## Phase 6 — Validation & clean-room hygiene
- Test matrix: cursor accuracy across the 3840×2160 panel corners+center; pressure curve
  linearity (ramp test app); tilt in 4 directions; all barrel buttons; every ExpressKey;
  touch ring/strip; 1–10-finger multitouch; palm rejection; hotplug; sleep/wake.
- App-level: Photoshop / Procreate-equivalent / Krita pressure + tilt behave correctly.
- **Clean-room record:** keep the spec (behavioral) separate from any decompiler output;
  cite Linux `wacom_wac.c` and OTD as reference-only; ship under a permissive/GPL license
  compatible with those references; do **not** ship Wacom assets, strings, or lifted code.

**Checkpoint:** all matrix rows pass; a short compatibility report written.

---

## Phase 7 — Risks, unknowns, open decisions
- **Init/mode-switch report** is the highest-risk unknown — without the correct feature
  report the tablet may stay in HID-mouse mode (no pressure). Mitigation: Phase 3 live USB
  capture of stock startup. **Needs the tablet connected.**
- **Encryption:** some Wacom models use an encrypted pen channel (`CDTUEncrypted*` classes
  exist in the binary). Confirm in Phase 2 whether DTH2420 pen data is encrypted (likely
  **not** for this pro display, but verify) — if so, scope expands significantly.
- **Exact PID** unknown until connected.
- **Coexistence:** the stock Wacom stack will fight for the device. For testing, unload the
  stock LaunchAgents (`launchctl bootout`) so only one driver claims the HID interface.
- **DriverKit escalation** (only if CGEvent path is insufficient): requires Apple-granted
  system-extension entitlement + notarization — decision deferred, flagged for you.
- **Sandbox vs unsandboxed:** develop unsandboxed for speed; decide sandbox model before dist.

---

## Ordered task list (execute top-down)
1. ✅ **Phase 0 recon** — done (`recon/FINDINGS.md`).
2. Install decompiler + USB-capture toolchain; thin-slice arm64 binaries; load in Ghidra. *(Phase 1)*
3. Decompile `CDTH2420GraphicsTablet` + comm/parser → draft pen & controls report spec. *(Phase 2)*
4. **[needs tablet]** Live-capture HID descriptor, init sequence, and gesture reports; confirm spec. *(Phase 3)*
5. Finalize `spec/DTH2420-protocol.md` v1.0 (clean-room boundary). *(Phase 4)*
6. Build MVP: HIDTransport + ReportParser + EventEmitter → pen + pressure in a paint app. *(Phase 5)*
7. Add tilt, buttons, ExpressKeys, then touch (WacomMultiTouch first). *(Phase 5)*
8. Run validation matrix; write compat report; finalize license + README. *(Phase 6)*

### Decisions needed from you before proceeding past step 2
- **A. Language for the driver** — Swift+C shim (recommended) vs C++/ObjC++?
- **B. When can the DTH2420k0 be connected?** Steps 4+ are blocked on it; steps 2–3 are not.
- **C. Touch strategy** — ship on `WacomMultiTouch.framework` (fast, supported) for v1, or go
  raw-HID from the start (fully independent, more work)?

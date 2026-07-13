# DTH2420k0 Protocol Spec (draft v0.1 — decoded from live HID report descriptors)

Source: live capture from the connected tablet (`captures/report-descriptors.txt`,
`captures/hidinfo.c`), 2026-07-12. This is the **clean-room** spec, derived from the
device's own HID descriptors — not from Wacom's binary. Fields marked ⚠ need a live
report capture (draw/press) to confirm byte order / behavior.

## USB identity (confirmed live)
- Vendor: `0x056a` (Wacom Co., Ltd.)
- **Pen digitizer:** PID `0x0351`, usagePage `0x01` usage `0x02`, name "Wacom Cintiq Pro 24"
- **Touch digitizer:** PID `0x0355`, usagePage `0xff00` usage `0x01`, name "Cintiq Pro 24 Touch"
- ExpressKey Remote (separate accessory): PID `0x0331`, usagePage `0xff0c`
- USB hub composite: `0x037F` (Pen Hub), `0x0380` (Hub2), `0x0381` (Hub1)

## Pen interface (PID 0x0351) — report layouts from descriptor

### Report ID 0x01 — mouse-compat (boot/fallback mode)
Standard HID mouse: 3 buttons + relative X/Y (8-bit). This is the compatibility mode
the device may present before being switched to full tablet mode. ⚠ Confirm whether an
init/feature report is needed to enable report 0x10 (the feature reports 0x02–0xE4 below
are the control channel).

### Report ID 0x10 — **primary high-resolution pen report** (27 bytes, **CONFIRMED live**)
The IOHIDManager input buffer **includes the report-ID byte at index 0**. Byte offsets
below are into the full 27-byte report and were verified against live raw-hex captures
(top-left / center / bottom-right / hard-press / lift gestures).

| Bytes | Field | Encoding | Range | Verified value |
|---|---|---|---|---|
| 0 | Report ID | u8 | `0x10` | always 0x10 |
| 1 | Status bits | bit0=Tip, bit1=Barrel, bit2=SecBarrel, bit3=Eraser, bit4=Invert, **bit5=InRange**, bit6=detect | — | `0x60` hover, `0x61` tip-down, `0x00` lifted |
| 2–4 | **X** | u24 LE | 0..105286 | TL≈1246, center≈50170, BR≈104998 |
| 5–7 | **Y** | u24 LE | 0..59574 | top≈2155, center≈26925, bottom≈58759 |
| 8–9 | **Pressure** | u16 LE | **0..8191** | 0 hover → 7598 hard press |
| 10 | **Tilt X** | int8 | -64..63 | |
| 11 | **Tilt Y** | int8 | -64..63 | |
| 12–13 | Twist | int16 LE | | 0 for standard Pro Pen |
| 14–15 | (vendor) | — | | 0 observed |
| 16 | Hover distance | u8 | | `0x3f` far, decreases approaching |
| 17–20 | **Serial** | u32 LE | | `0x44332211` (constant per pen) |
| 21–24 | Tool/type ID | u32 LE | | `0x00100842` observed |
| 25–26 | (vendor 0x77) | u16 LE | 0..0x0fff | |

Barrel-button bit (byte 1 bit1) still to be captured in isolation. Report 0x06 is a
lower-resolution variant (pressure max 2047) — the driver uses 0x10 exclusively.
Implemented + unit-tested against these captures in `driver/Sources/WacomDriverCore/PenReport.swift`.

### Reports 0x11, 0x13 — pad/controls
- 0x11: on-tablet control buttons (usage 0x39 etc., bit flags) — ExpressKeys on the unit.
- 0x13: 8-byte vendor blob. ⚠ confirm which is ExpressKeys vs touch-ring.

### Feature reports 0x02–0xE4 — control/config channel
Large set of vendor feature reports (`b1 02`) for mode-switching, config, OLED/EK
labels, etc.

**Mode-switch (CONFIRMED via decompile — `recon/decompile-CDTH2420.md`, HIGH confidence):**
The startup sequence in `CGD16GraphicsTablet::DeviceStart` (inherited by CDTH2420) is:
1. `SetMaxPressureLevels(0x2000)` — internal (8192 levels); no device write.
2. **SET_FEATURE report `0x02`, buffer `02 02`** → native Wacom high-res mode (enables
   report 0x10 + full pressure). `02 01` = revert to HID/boot mouse mode. Retried up to 6×.
3. **SET_FEATURE report `0x04`, buffer `04 00`** → data-rate mode.
4. GET_FEATURE reads for serial/OEM/version (identification only; not required to drive).

Sent via `MacHidDevice::SendReport(type, data, len)` → `IOHIDDeviceSetReport(dev, Feature,
reportID=data[0], data, len)`. The buffer **includes the report-ID byte** as `data[0]`.

⚠ Verify live: confirm `SET_FEATURE 0x02=02` actually appears on the pen interface
(PID 0x0351) at launch (the stock path early-returns unless `GetKernelDriver()==3`).

## Touch interface (PID 0x0355) — standard HID multitouch digitizer

### Report ID 0x81 — finger data (up to ~10 contacts)
Per finger: TipSwitch (1 bit) + 7 pad, ContactID (0x51, 8-bit), X (0x30, 16-bit,
logmax 0x3c00), Y (0x31, 16-bit, logmax 0x21c0). Repeated per finger collection,
followed by ScanTime (0x56, 16-bit) and ContactCount (0x54, 8-bit).
Feature 0x84 = contact-count-max. This is a Windows-Precision-Touchpad-style layout.

### Report ID 0x88 — single-contact + width/height (0x56) variant
### Report ID 0x83 — device config feature (0x0e / 0x52 / 0x53)
### Report 0x05/0x06 — vendor in/out 63-byte pipes (0xff00) — raw/diagnostic

**Touch path decision (per user):** v1 consumes `WacomMultiTouch.framework`
(`WacomMTRegisterFingerReadCallback`). Raw HID (report 0x81 above) is the v2 fallback —
already fully decodable from this descriptor.

## ExpressKey Remote (PID 0x0331) — vendor 0xff0c
Reports 0x10/0x11 (input, 31 bytes) = button state; 0x20/0x21 (feature) = config.

## Screen mapping
Panel is 3840×2160. Pen logical space 105286×59574 → map to display bounds
(display-mapped by default; full-desktop optional). Aspect ratio 105286/59574 ≈ 1.767 ≈ 16:9. ✓

## Status
1. ✅ Report 0x10 byte offsets — CONFIRMED live (table above), unit-tested.
2. ✅ Mode-switch — CONFIRMED: FEATURE 0x02=`02 02`, 0x04=`04 00`; live SetReport succeeded.
3. ⏳ ExpressKey / touch-ring report IDs and bit maps (reports 0x11/0x13) — not yet captured.
4. ⏳ Barrel-button bit + tilt sign convention — capture in isolation.
5. ⏳ Touch (PID 0x0355) — via WacomMultiTouch.framework (v1 plan).

# wacom-cintiq-driver

A from-scratch, clean-room macOS driver for the **Wacom Cintiq Pro 24 Touch (DTH2420k0)**,
built because the stock Wacom driver does not function on this macOS version. No dependency
on OpenTabletDriver or any Wacom software at runtime.

**Working today:** pen (position, pressure, tilt — calibrated), 2-finger touch scroll,
running as a persistent LaunchAgent.

## Layout
- `driver/` — the Swift package (HID transport, report parsers, event emitter, daemon).
  See `driver/README.md` (usage) and `driver/INSTALL.md` (persistent install + signing).
- `spec/DTH2420-protocol.md` — reverse-engineered device protocol (USB IDs, pen report 0x10,
  touch report 0x81, pen mode-switch, touch enable) — the clean-room deliverable.
- `recon/` — reverse-engineering findings and decompilation reports.
  (Wacom's binary slices are git-ignored; recreate with `lipo` — see `recon/FINDINGS.md`.)
- `captures/` — live HID captures (report descriptors) and the `hidinfo` dump tool.
- `PLAN.md` — the original phased plan.

## How it works (summary)
1. `IOHIDManager` opens the pen (`056a:0351`) and touch (`056a:0355`) HID interfaces.
2. On attach it sends the enable/mode-switch reports recovered from the stock driver
   (pen FEATURE `0x02=02 02`; touch OUTPUT `0x06 …`).
3. Reports are decoded by pure-Swift parsers (unit-tested against real captured reports).
4. Input is injected via CoreGraphics tablet events (pen) and scroll-wheel events (touch),
   the same userspace path the stock driver used.

## Clean-room note
The protocol was documented from the device's own HID descriptors and from behavioral
analysis. Wacom's proprietary binaries are not redistributed here.

## Status / TODO
See `driver/README.md` for the current checklist (ExpressKeys, more gestures, settings, etc.).

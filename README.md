<p align="center">
  <img src="docs/icon/icon-master-1024.png" width="140" alt="Nib icon">
</p>

# Nib

**Nib** is an independent, open-source macOS driver for **Wacom pen displays**, built from
scratch — via clean-room reverse engineering — because Wacom's drivers frequently break on
new macOS releases. This one was created specifically because the Wacom drivers **do not
work on the macOS 27 developer beta**, leaving the tablet unusable. Its reference device is
the **Cintiq Pro 24 Touch (model DTH2420)** — the model it is built on and verified with —
but all model-specific details live in swappable **device profiles**, so other Wacom
tablets can be added as data, not new decode code. No dependency on OpenTabletDriver or any
vendor software at runtime.

**Working today:** automatic detection of the connected tablet with hotplug re-resolution;
pen (position with in-app calibration, an adjustable pressure curve, tilt, remappable side
buttons), multi-touch (2-finger scroll, tap-to-click, 3-finger swipe, palm rejection), a
menu-bar app and a full preferences window, running as a persistent per-user LaunchAgent.

## Why I built this

I use a Cintiq Pro 24 Touch as my tablet display, and I'm a software developer. Whenever a
new macOS beta is released, Wacom's drivers stop working. This was no different for macOS 27.
I didn't want to roll back macOS or wait countless months for a fix, and decided to solve
the problem for myself.

My Cintiq also frequently fails to work when plugged in, and must be unplugged and replugged — oftentimes
in a different USB-C port — before it works. It is too early to tell right now, but I hope this
driver can solve that problem.

The final problem I hope to avoid is Wacom's inevitable end-of-lifing of my tablet. It is several years old now,
and I do not know for how long they will continue to support it. In building my own driver, I hope to extend its
life until the hardware fails.

## Screenshots

<p>
  <img src="docs/screenshots/menu.png" alt="Menu-bar menu" height="360">
  <img src="docs/screenshots/preferences.png" alt="Preferences window" height="360">
  <img src="docs/screenshots/pressure-curve.png" alt="Pressure curve editor" height="360">
</p>

In-app calibration overlay — tap the two crosshairs with the pen:

<img src="docs/screenshots/calibration.jpg" alt="Calibration overlay" width="640">

## Supported devices
- **Wacom Cintiq Pro 24 Touch (DTH2420)** — the reference device, fully verified.

Nib resolves the connected tablet at runtime from a set of device profiles and re-resolves
on hotplug. Other Wacom models can be added from a capture bundle **without shipping
hardware** — see `docs/ADDING-A-DEVICE.md`.

## Layout
- `driver/` — the Swift package (`nib` executable + `NibCore` library). See
  `driver/README.md` (usage) and `driver/INSTALL.md` (persistent install + code signing).
- `spec/DTH2420-protocol.md` — the reverse-engineered device protocol (USB IDs, pen
  report 0x10, touch report 0x81, pen mode-switch, touch enable) — the clean-room deliverable.
- `recon/` — reverse-engineering findings and decompilation notes.
- `captures/` — live HID captures (report descriptors) and the `hidinfo` dump tool.
- `docs/ADDING-A-DEVICE.md` — how to add another tablet from a capture bundle (no code in
  the decode path; model support is a `DeviceProfile` + regression fixtures).
- `ROADMAP.md` — planned work and stretch ideas.

## How it works
1. On launch (and on hotplug) Nib detects the connected tablet from its **device profiles**
   and opens that model's pen and touch HID interfaces via `IOHIDManager` (the DTH2420's
   are `056a:0351` / `056a:0355`).
2. On attach it sends the active profile's enable/mode-switch reports to put the tablet
   into its native high-resolution mode (recovered during reverse engineering).
3. Reports are decoded by pure-Swift parsers (unit-tested against real captured reports).
4. Input is injected via CoreGraphics tablet events (pen) and scroll/key events (touch) —
   an entirely userspace path, no kernel extension.

## Install
See `driver/INSTALL.md`. In short: build (`swift build -c release`), wrap the binary in
`Nib.app`, sign it, grant Input Monitoring + Accessibility, and load the LaunchAgent.

## Disclaimer / trademarks
This is an **independent, unofficial** project. It is **not affiliated with, authorized,
sponsored, or endorsed by Wacom Co., Ltd.** "Wacom", "Cintiq", and the device model
number are trademarks of their respective owner and are used here **only to identify the
hardware this software is compatible with** (nominative fair use). All product names,
logos, and brands are the property of their respective owners.

Nib was created for **interoperability** — to let hardware its owners already possess work
on macOS. It was developed by clean-room documentation of the device's own protocol and
behavior; it does not include or redistribute any vendor software or assets.

## AI disclosure

Nib was built with the help of **Claude** (Anthropic's AI assistant, via
Claude Code). AI was used throughout development — reverse-engineering the
device protocol, writing and testing the Swift code, and drafting
documentation — under my direction and review. I'm responsible for the
project and its decisions; the clean-room reverse engineering was documented
from the device's own observable behavior, not from any vendor source or
confidential material.

## License
See `LICENSE`.

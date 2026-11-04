# Roadmap

Nib is fully usable today (see the feature list in `README.md` / `driver/README.md`).
These are the remaining and possible enhancements.

## Done
- [x] **Device-config abstraction** — all model-specific identity, report layouts,
      mode-switch and touch-enable live in a `DeviceProfile`, chosen at runtime from the
      connected hardware (with hotplug re-resolution). Adding a model is data, not decode
      code. Contribution workflow: `docs/ADDING-A-DEVICE.md`.
- [x] **Developer ID signing + notarization** — a tagged release builds a signed,
      notarized DMG (`driver/RELEASING.md`), so Nib installs on other Macs without a
      self-signed certificate.

## Planned
- [ ] **ExpressKeys / touch-ring** — the tablet's physical buttons and ring (pen reports
      `0x11` / `0x13`), mapped to shortcuts.
- [ ] **More device profiles** — bring up additional Wacom models from contributed capture
      bundles (`docs/ADDING-A-DEVICE.md`).

## Stretch / ideas
- [ ] **Safari swipe-navigation** — phased/gesture scroll so a 2-finger horizontal swipe
      triggers back/forward (currently plain horizontal scroll; a phased attempt felt janky).
- [ ] **Pinch-to-zoom** — needs private CoreGraphics gesture events.
- [ ] More configurable gesture and pen-button mappings.
- [ ] **Descriptor auto-parsing** — derive a `DeviceProfile` layout from a submitted HID
      report descriptor (offline generator first; runtime parsing only if a generic
      "plug-any-Wacom" fallback becomes a goal).

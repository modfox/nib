# Roadmap

Nib is fully usable today (see the feature list in `README.md` / `driver/README.md`).
These are the remaining and possible enhancements.

## Planned
- [ ] **ExpressKeys / touch-ring** — the tablet's physical buttons and ring (pen reports
      `0x11` / `0x13`), mapped to shortcuts.
- [ ] **Developer ID signing + notarization** — so Nib can be installed on other Macs
      without setting up a self-signed certificate.

## Stretch / ideas
- [ ] **Safari swipe-navigation** — phased/gesture scroll so a 2-finger horizontal swipe
      triggers back/forward (currently plain horizontal scroll; a phased attempt felt janky).
- [ ] **Pinch-to-zoom** — needs private CoreGraphics gesture events.
- [ ] More configurable gesture and pen-button mappings.
- [ ] A device-config abstraction so other Wacom models can be added.

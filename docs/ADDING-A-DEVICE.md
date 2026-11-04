# Adding support for another tablet

Nib was built for one device (the Cintiq Pro 24 Touch, DTH2420) but is structured so that
**adding a model is data, not new decode code**. Everything model-specific lives in a
`DeviceProfile` (`driver/Sources/NibCore/DeviceProfile.swift`): USB IDs, report byte
layouts, the pen mode-switch, the touch-enable sequence, and the panel size. The parser,
mode-switch, touch-enable and display match all read from the active profile, chosen at
runtime from whatever tablet is plugged in.

The key consequence: **someone who owns the hardware can contribute a capture, and a
maintainer who does not own it can turn that capture into a tested profile.** This doc is
the workflow for both roles.

---

## What a contribution needs (the "capture bundle")

If you have a tablet Nib doesn't support yet, you can produce everything needed by running
two tools. A complete bundle is:

1. **The HID report descriptor dump** — `hidinfo` output for your device.
2. **Labeled raw report captures** — `nib capture` output while you perform specific
   gestures, each clearly labeled (see the gesture list below).
3. **Basic device facts** — model name/number, and the native panel resolution in pixels
   (for a pen *display*; skip for an opaque tablet).

Attach these to an issue/PR. That's enough for a maintainer to author the profile and the
regression fixtures — no shipping the hardware.

---

## Step 1 — capture the descriptor

Build the little enumerator (once) and dump descriptors for all connected Wacom devices:

```
cd captures
clang -o hidinfo hidinfo.c -framework IOKit -framework CoreFoundation
./hidinfo > my-device-descriptors.txt
```

This lists each HID interface with its **VID/PID/usagePage/usage** and the raw report
descriptor bytes. Identify the **pen** interface (a digitizer, usagePage `0x0d` or a
vendor page with a high-res coordinate report) and the **touch** interface (a
Precision-Touchpad-style digitizer). Note both PIDs.

## Step 2 — capture labeled gestures

`nib capture` opens every connected interface of the known vendors and prints every report
as raw hex tagged by PID. By default it only **listens** — it sends nothing to the tablet:

```
nib capture > my-device-capture.txt
```

If the pen produces no high-res report this way, run it again with `--send-enable`, which
also sends the DTH2420's mode-switch and touch-enable reports to every interface (these
work across much of the Wacom family):

```
nib capture --send-enable > my-device-capture-enabled.txt
```

`--send-enable` writes vendor-specific reports whose meaning on another model is unknown,
so only use it when the passive capture shows no pen report, and say in the bundle which
mode produced each file. Unplugging and replugging the tablet resets it.

Then perform each gesture below **one at a time**, pausing between them, and keep a note of
which lines correspond to which gesture (timestamps or "I did X now" markers help):

**Pen (find the pen PID's `id=0x..` lines):**
- Pen tip touching the **top-left** corner, then **center**, then **bottom-right** — this
  pins down the X/Y byte offsets and their logical max.
- **Light press** and **hard press** at center — pressure offset and its max.
- **Hover** (in range, not touching) and **lift** (fully away) — the status/proximity bits.
- Optional: **tilt** the pen each way; press each **side button**; flip to the **eraser**.

**Touch (find the touch PID's lines):**
- **One finger** down at a known spot, **two fingers**, **three fingers**.

> If the pen produces **no** high-res report even under `nib capture --send-enable`, its
> mode-switch differs from the DTH2420's. That's the one part the descriptor can't give you — note it in the
> bundle; it needs a person with the device to help recover (see "What still needs the
> hardware").

---

## Step 3 — author the profile (maintainer)

Read the offsets and logical maxima straight out of the descriptor (the DTH2420 worked
example is `spec/DTH2420-protocol.md`), confirm them against the captured gestures, and add
a `DeviceProfile` literal. Template:

```swift
public extension DeviceProfile {
    static let myModel = DeviceProfile(
        name: "Vendor Model Name (MODELNO)",
        vendorID: 0x____,           // from hidinfo
        penPID:   0x____,           // pen interface PID
        touchPID: 0x____,           // touch interface PID
        pen: PenLayout(
            reportID: 0x__,         // the high-res pen report's ID
            reportLength: __,       // full report length in bytes, incl. the ID byte
            offsets: PenLayout.Offsets(
                status: 1, x: 2, y: 5, pressure: 8,   // byte offsets into the full report
                tiltX: 10, tiltY: 11, twist: 12,
                distance: 16, serial: 17, toolID: 21),
            xLogicalMax: _____,     // logical max from the descriptor's X usage
            yLogicalMax: _____,
            pressureLogicalMax: ____),
        touch: TouchLayout(
            reportID: 0x__,
            minReportLength: 64,
            fingerRecordSize: 6,    // bytes per finger record
            trailerSize: 3,         // scanTime(2) + contactCount(1)
            xLogicalMax: _____,
            yLogicalMax: _____),
        initSequence: [             // pen mode-switch; [] if the pen needs no poking
            FeatureWrite(reportID: 0x02, [0x02, 0x02]),
        ],
        touchEnable: [              // touch enable; [] if touch works unprompted
            OutputWrite(reportID: 0x06, /* 64-byte vendor buffer */ []),
        ],
        panelSize: CGSize(width: ____, height: ____))   // nil for an opaque tablet
}
```

Then register it so runtime detection and the tests pick it up:

```swift
static let all: [DeviceProfile] = [.dth2420, .myModel]
```

## Step 4 — add regression fixtures

Turn the labeled captures into a fixture bundle in
`driver/Tests/NibCoreTests/DeviceFixtures.swift` and append it to `DeviceFixtures.all`.
Assert only the values you can confidently label (leave the rest `nil`):

```swift
static let myModel = DeviceFixtureBundle(
    profile: .myModel,
    pen: [
        PenFixture(name: "center press", hex: "…captured hex…",
                   tipDown: true, inRange: true, x: 0x____, y: 0x____, pressure: 0x____),
        // top-left, bottom-right, hover, lift …
    ],
    touch: [
        TouchFixture(name: "one finger", hex: "…", contactCount: 1, firstX: 0x____, firstY: 0x____),
    ])
```

`ProfileConformanceTests` then validates the new profile automatically — no per-device test
code. Run:

```
cd driver && swift test
```

Green means the profile decodes real hardware output correctly. This is the check a
maintainer relies on to accept a device they can't physically test.

## Step 5 — verify on hardware (contributor)

Build and run (`driver/INSTALL.md`), plug in the device, and confirm from
`~/Library/Logs/nib.log` that Nib logs `now driving <your model>` and that pen tracking,
pressure, and touch behave. Report the result on the PR.

---

## What still needs the hardware

The descriptor gives the **decode layout** for free. It does **not** give:

- **The pen mode-switch** (`initSequence`) — some models only emit their high-res report
  after a vendor feature write. For the DTH2420 this was recovered by decompiling Wacom's
  driver (`recon/`), not from any descriptor. If `nib capture` shows no pen report, this is
  why, and recovering it needs someone with the device (try `nib capture --send-enable`
  first; the DTH2420 sequence covers much of the Wacom family).
- **The touch-enable sequence** (`touchEnable`) — likewise for the multitouch sensor.
- **Final sign-off** — that pen tracking, pressure curve and gestures actually feel right.

So the split is: maintainers own the abstraction and the profile authoring; contributors
run two capture commands and do the final on-device confirmation. Neither needs to ship the
tablet anywhere.

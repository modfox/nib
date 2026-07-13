# Wacom Cintiq Pro 24 Touch (DTH2420k0) — Touch Enable Command (RE findings)

Target: `WacomTouchDriver.arm64` (unstripped C++ arm64, baddr `0x100000000`)
Device: USB `056a:0355`, touch controller codename **BlueJay**, sensor class **BLUEJAY_24**.

---

## TL;DR — the enable command

To start finger streaming the driver does NOT send a HID **Feature** report on `0x83`.
It sends two **vendor OUTPUT reports with HID Report ID `0x06`** (64 bytes each), via
`IOHIDDeviceSetReport(dev, kIOHIDReportTypeOutput /*=1*/, reportID=0x06, buf, 64)`.

For the Cintiq Pro 24 Touch (BLUEJAY_24) on macOS, enabling touch triggers, in order:

1. **SendSharpMultiTouch(true)** — 64-byte OUTPUT report, ID `0x06`:
   ```
   06 06 00 06 02  00 00 ... 00      (bytes 5..63 = 0x00)
   ```
2. **SendSharpHIDConfigure(HidEnabled, TouchEnabled)** — 64-byte OUTPUT report, ID `0x06`.
   With touch fully enabled (HidEnabled=1, TouchEnabled=1), byte[4]=0x03:
   ```
   06 06 00 01 03  00 00 ... 00      (bytes 5..63 = 0x00)
   ```

Byte layout of the vendor report:
```
[0] = 0x06   HID report ID (numbered report; included in the buffer)
[1] = 0x06   command class (constant 0x06)
[2] = 0x00   constant
[3] = sub-command:  0x06 = multitouch-mode,  0x01 = HID-configure
[4] = value  (see tables below)
[5..63] = 0x00 padding
```

**byte[4] for SendSharpHIDConfigure (sub-cmd 0x01):** `Touch ? (Hid ? 0x03 : 0x01) : 0x00`
| TouchEnabled | HidEnabled | byte[4] |
|---|---|---|
| 0 | x | 0x00 |
| 1 | 0 | 0x01 |
| 1 | 1 | **0x03**  ← enable |

**byte[4] for SendSharpMultiTouch (sub-cmd 0x06):** `enable ? 0x02 : 0x01`. Always called with `enable=true` here → **0x02**.

> Recommended enable sequence to reproduce: send report `06 06 00 06 02 …` then `06 06 00 01 03 …`, both as 64-byte **Output** reports (report ID 6).

---

## Call graph / evidence

### Entry points (state setters)
- `CHIDInterface::SetTouchEnableDisable(bool,bool)` @ `0x100166f70`
  - `strb w8,[x19,0x45]` — stores TouchEnabled into member `this+0x45`
  - then `SendConfigCommand(1,0,0)`.
- `CHIDInterface::SetHidEnableDisable(bool,bool)` @ `0x10016737c` — member `this+0x44`.
- `CHIDInterface::SetTabletModeEnableDisable(bool,bool)` @ `0x10016747c` — member `this+0x46`, then `SendConfigCommand(0,0,1)`.

State members (byte flags), read by the getters:
| member | offset | getter |
|---|---|---|
| HidEnabled | `this+0x44` | `0x100167474` (`ldrb w0,[x0,0x44]`) |
| TouchEnabled | `this+0x45` | `0x100167050` (`ldrb w0,[x0,0x45]`) |
| TabletModeDisabled | `this+0x46` | `0x10016755c` (`ldrb w0,[x0,0x46]`) |
| OneTimeConfigSent | `this+0x47` | `0x100167564` |

Note: the three bool args to `SendConfigCommand` are used only for an assert ("not all three false"); the payload values come from the **member getters** above, i.e. current device state.

### `CHIDInterface::SendConfigCommand(bool,bool,bool)` @ `0x100167058`
Dispatches on sensor ID. Path taken for **BLUEJAY_24 on macOS** (`EOSTYPE_IS_MAC` true):

- `0x1001671cc  cbz w0, 0x100167354`  (none of the "MSInput" sensors matched) → `0x100167354`
- `0x100167354  IS_BLUEJAY_24_SENSOR_ID` → true → `0x10016736c`
  - `0x100167370  mov w1, 1` ; `bl SendSharpMultiTouch` → **SendSharpMultiTouch(true)**
- falls through to `0x1001671dc`: sets `OneTimeConfigSent` (`this+0x47`)=1, then third dispatch:
- `0x100167294  IS_BLUEJAY_24` → true → `0x1001672ac`
  - `x1 = HidEnabled()`, `x2 = TouchEnabled()`; `bl SendSharpHIDConfigure` → **SendSharpHIDConfigure(HidEnabled, TouchEnabled)**

So both reports are emitted per enable.

### `CHIDInterface::SendSharpHIDConfigure(bool hid, bool touch)` @ `0x1001678f8`
Builds a 64-byte `vector<uint8_t>` (filled 0), then:
```
byte[0]=0x06  byte[1]=0x06  byte[2]=0x00  byte[3]=0x01  byte[4]=w20
; w20 computed:
0x100167910  cmp  w1,0            ; hid
0x100167914  mov  w8,3
0x100167918  csinc w8,w8,wzr,ne   ; w8 = hid?3:1
0x10016791c  cmp  w2,0            ; touch
0x100167920  csel w20,w8,wzr,ne   ; byte[4] = touch? (hid?3:1) : 0
```
Then virtual call `[[x19]+0xa8](this, &vec)` @ `0x1001679c4`.

### `CHIDInterface::SendSharpMultiTouch(bool enable)` @ `0x1001676f4`
Same construction; `byte[3]=0x06`, and:
```
0x100167770  cmp  w20,0
0x100167774  cinc w20,w22,ne      ; w22=1 → byte[4] = enable?2:1
```
Same virtual call `[[x19]+0xa8](this,&vec)`.

### The transport: vtable slot `0xa8` = `CMacHIDInterface::Write` @ `0x10006d864`
`CHIDInterface` vtable `__ZTV13CHIDInterface` @ `0x1002a4870` has slot 0xa8 null (pure/abstract);
concrete `__ZTV16CMacHIDInterface` @ `0x10029cc30` slot 0xa8 → `0x10006d864` = `CMacHIDInterface::Write(vector<uint8_t> const&)`.
```
0x10006d8c4  mov w1, 1                     ; IOHIDReportType = kIOHIDReportTypeOutput
0x10006d8dc  b MacHidDevice::SendReport    ; tail call
```

### `MacHidDevice::SendReport(IOHIDReportType, const u8*, size_t)` @ `0x1000c9360`
```
0x1000c93a4  ldrb w2,[x8],1               ; reportID = buf[0]
0x1000c93ac  csel x3, buf, buf+1, (buf[0]!=0)   ; buf[0]!=0 → pass FULL buffer incl. ID
0x1000c93b4  sub  x4, len, (buf[0]==0?1:0)      ; → full length 64
0x1000c93c0  bl IOHIDDeviceSetReport      ; (dev, type, reportID, report, len)
```
So `buf[0]` (=0x06) is used as the numbered-report ID; the full 64-byte buffer (incl. the leading 0x06) is the report data. reportType is Output (1) via `Write`.

For comparison, the **Feature** path exists but is NOT used for BlueJay24 enable:
- `MacHidDevice::SendFeature` @ `0x1000c92cc` → `SendReport(type=2=Feature,…)`
- `CMacHIDInterface::SetFeature` @ `0x10006dbf0` → `MacHidDevice::SendFeature`.

### No `0x83` Device-Mode feature report is built
Binary scan for a `movz w?,#0x83` instruction (4-byte aligned) returns **zero** hits — every `108052` match is unaligned (mid-instruction). The driver never writes literal `0x83` as a report value, i.e. the standard HID "Device Mode (usage 0x52) → 2" Feature report on report 0x83 is not part of this Mac enable path. The enable is the vendor Output report `0x06` above.

---

## Ordering & notes
1. Higher layer sets member flags (`SetTouchEnableDisable(true,…)`, `SetHidEnableDisable(true,…)`), then `SendConfigCommand` reads them and emits the reports.
2. On the enable pass for BLUEJAY_24: **`SendSharpMultiTouch(true)` is sent first**, then **`SendSharpHIDConfigure(hid,touch)`**.
3. No GET_FEATURE read is required before sending (none in this path).
4. `ModeSwitchHandler` (`CBlueJayOpaqueTD::ModeSwitchHandler` @ `0x10016d78c`, `CBlueJayTD::ModeSwitchHandler` @ `0x10010ac2c`) is device teardown/recreate lifecycle (opaque↔integrated), not the per-enable feature send — not needed to start streaming.

## Caveat to verify live
- Report type is **Output (kIOHIDReportTypeOutput=1)** and report **ID 0x06** — this differs from the digitizer's Feature reports (0x83/0x84/0x87) you parsed. The `CHIDInterface`/`MacHidDevice` writes to the HID device it opened via `CMacHIDInterface::OpenDevice` (`0x10006d488`); confirm this is the same `056a:0355` top-level collection you opened, or a sibling vendor collection on the same device. If your `IOHIDManager` opened the digitizer collection, the Output report 0x06 should still route to the device.

### How to verify
1. From your IOHIDManager client, after opening `056a:0355`, call:
   `IOHIDDeviceSetReport(dev, kIOHIDReportTypeOutput, 0x06, {06,06,00,06,02, 0…}, 64)`
   then `IOHIDDeviceSetReport(dev, kIOHIDReportTypeOutput, 0x06, {06,06,00,01,03, 0…}, 64)`.
2. Watch for input report ID `0x81` finger packets to begin.
3. If Output is rejected, retry the same two buffers as **Feature** (`kIOHIDReportTypeFeature`, reportID 0x06) — cheap fallback, though the disassembly says Output.
4. If still idle, capture the real driver with a USB/HID bus trace (e.g. `IOHIDFamily` logging / a PacketLogger-style capture) to confirm on-wire report type/ID; the payload bytes above are exact.

# CDTH2420 Driver Decompilation — Mode-Switch & Report Path

Target: `recon/WacomTabletDriver.arm64` (unstripped C++, arm64, loaded at vaddr base `0x100000000`).
Method: static RE with radare2 (`s <vaddr>; af; pdf`), vtable pointer resolution, RTTI walking.
Date: 2026-07-12. All addresses below are runtime vaddrs (file offset = vaddr − 0x100000000).

---

## TL;DR — the mode-switch (highest-value result)

At device startup the driver puts the pen into full high-res "Wacom mode" by writing a **HID FEATURE report**:

> **Report ID `0x02`, payload byte `0x02`** — i.e. SET_FEATURE with the 2-byte buffer **`02 02`**.

Concretely: `IOHIDDeviceSetReport(device, kIOHIDReportTypeFeature, /*reportID*/0x02, {0x02,0x02}, 2)`, retried up to 6×.

Companion commands on the same control channel (all FEATURE writes, `buffer[0]` = report ID):
| Purpose | Method | FEATURE bytes | Notes |
|---|---|---|---|
| **Enter Wacom (high-res) mode** | `CUSBCommInterface::SetToWacomMode()` | **`02 02`** | ← sent at init via `SetHidMode(true)` |
| Enter HID/boot (mouse-compat) mode | `CUSBCommInterface::SetToHIDMode()` | `02 01` | the reverse switch |
| Data-rate mode (full rate) | `CUSBCommInterface::SetDataRateMode(bool)` | `04 <!en>` | init sends `04 00` |
| Pen scan enable | `SetScanModePen` / `GD16SetScanModePen(bool)` | `0D <!en>` | `0D 00` = pen scanning on |
| Pen scan (single-byte variant) | `SetPenScanMode(bool)` | `04 <!en>` | |
| Pen+Touch scan | `SetScanModePenTouch(pen,touch,x)` | `0D <bits>` | bit0=!pen, bit1=touch, bit2=x |

`<!en>` = logical NOT of the bool arg (the code does `eor w,w,1`), so passing `true` writes `0x00`.

**Confidence: HIGH** for the `02 02` / `02 01` mode register and that it is sent at init. These are
built from immediate constants and written through a fully-traced FEATURE-report path (below).
The one soft spot: `SetToWacomMode()` early-returns unless `CCommInterface::GetKernelDriver()==3`
(a transport/driver-kind gate) — see "Caveat" at the end.

---

## Goal 1 — The SetReport / SetFeature wrapper chain

The write path, from high level to the syscall:

```
CUSBCommInterface::Set*Mode()                     // builds vector<uchar> payload
  -> vtable[+0xe0] = CMacHIDCommInterface::SendUSBCommand(EUSBCommand, vector<uchar>&, ulong retries, double sleep [, bool])
       -> (cmd==9) MacHidDevice::SendFeature(const uchar* data, ulong len)
       -> (cmd==1) MacHidDevice::GetFeature(uchar* data, ulong len)
            -> MacHidDevice::SendReport(IOHIDReportType type, const uchar* data, ulong len)
                 -> IOHIDDeviceSetReport(mDevice, type, /*reportID=*/data[0], data, len)
```

Key wrapper signatures & addresses (mangled symbols in `rabin2 -s`):

- **`MacHidDevice::SendReport(IOHIDReportType type, const unsigned char* data, unsigned long len)`** — `0x1002cde60`
  This is the terminal SetReport wrapper. Disassembly proves the ABI:
  ```
  0x1002cdea4  ldrb w2, [x8], 1        ; w2 = reportID = data[0]  (post-increment)
  0x1002cdeac  csel x3, x21, x8, ne    ; report buf = data (full) if data[0]!=0, else data+1
  0x1002cdeb4  sub  x4, x19, x8        ; len -= (data[0]==0 ? 1 : 0)
  0x1002cdeb8  ldr  x0, [x20, 8]       ; x0 = IOHIDDeviceRef (this+0x8)
  0x1002cdec0  bl   imp.IOHIDDeviceSetReport   ; (dev, type=w1, reportID=w2, buf=x3, len=x4)
  0x1002cdec4  str  w0, [x20, 0x50]    ; this+0x50 = mLastIOReturn
  ```
  Returns `-1` on IOReturn!=0, else `len`. `IOHIDReportType`: 0=Input, 1=Output, **2=Feature**.
- **`MacHidDevice::SendFeature(const unsigned char* data, unsigned long len)`** — `0x1002cddcc`
  Thin shim → `SendReport(type=2 /*Feature*/, data, len)`.
- **`MacHidDevice::GetFeature(unsigned char* data, unsigned long len)`** — `0x1002cdf30` (GET_FEATURE read).
- **`MacHidDevice::GetReport(...)`** — `0x1002cdff8`.
- **`CMacHIDCommInterface::SendUSBCommand(EUSBCommand, vector<uchar>&, ulong, double)`** — `0x1000a2f1c`
  (4-arg tail-calls 5-arg `0x1000a2fc8`). Behaviour of the 5-arg body:
  - `EUSBCommand == 9` → `MacHidDevice::SendFeature(payload.data(), payload.size())` (SET_FEATURE)
  - `EUSBCommand == 1` → `MacHidDevice::GetFeature(...)` then `TriggerReadCallback` (GET_FEATURE)
  - `payload[0]` is logged as the report ID; retries `retries` times, `WacSleep(sleep)` between,
    until `MacHidDevice::GetLastIOReturn()==0`.
- `IOHIDDeviceSetReport` / `IOHIDDeviceGetReport` imports at `0x10080b07c` / `0x10080b028`.

There is also a vector-based path `CMacVcpHIDConnector::SetFeature(vector<uchar>&)` `0x1003079b8`
(and `CVcpHIDConnector` `0x3e9ec4`) used for the VCP/OLED/DDC side — **not** the pen mode-switch.

Note: `CMacHIDCommInterface::SetWISDHIDMode(bool)` `0x1000a3120` looks like a candidate by name
but is effectively a **debug/log stub** on macOS: its `$_0` lambda (`0x1000a5150`) only emits a
`WacLog::Debug("CMacHIDCommInterface::SetWISDHIDMode")` string. The real switch is `SetToWacomMode`
(below), reached through the `CGD16GraphicsTablet::SetHidMode` → CommInterface vtable route.

---

## Goal 2 — CDTH2420 construction, init, and the startup command sequence

### Class identity & init entry points
- `CDTH2420GraphicsTablet::CDTH2420GraphicsTablet()` — `0x1003fb76c` (C2) / `0x1003fb7d8` (C1)
- **`CDTH2420GraphicsTablet::Init()`** — `0x1003fb840`. What it does:
  1. Installs a `WacomMT` raw callback ptr.
  2. Reads a `double` pref via `CTabletDriver::GetDoubleForXPath(...)` and stores it at `this+0x8a0`
     (used later by the report-0x11 long-press handler).
  3. `GetUSBCommInterface(this)` then **`CUSBCommInterface::SetPacketSize(0x1b)`** → **packet/report
     length = 27 bytes** (this is the report-0x10 pen packet size).
  4. Tail-delegates to **`CGraphicsTablet::Init()`** (`0x1000466a0`).
  `Init()` itself does **not** send the mode-switch — that happens in `DeviceStart` when the USB
  device is actually attached.

### The mode-switch call site: `CGD16GraphicsTablet::DeviceStart()` — `0x100307d74`
Ordered call sequence (virtuals resolved against the `CDTH2420GraphicsTablet` vtable `0x100b6e788`
and the `CMacHIDCommInterface` vtable `0x100b501d0`):

1. `CGraphicsTablet::DeviceStart()` (base) — `0x100064bc4`.
2. **`SetMaxPressureLevels(0x2000)`** — `0x1000e5f34`. **0x2000 = 8192 levels** → pressure range
   **0..8191**, matching the spec.
3. tablet-vtable `[+0x290]` = **`CGD16GraphicsTablet::SetHidMode(true)`** (`0x10030b458`).
   `SetHidMode(true)` tail-calls CommInterface vtable `[+0x100]` = **`CUSBCommInterface::SetToWacomMode()`**
   (`0x100381570`) → **writes FEATURE `02 02`** (see below). ← THE MODE-SWITCH.
4. tablet-vtable `[+0x288]` = **`CGD16GraphicsTablet::SetDataRateMode(true)`** (`0x10030b42c`) →
   CommInterface `SetDataRateMode(bool)` (`0x100381898`) → **writes FEATURE `04 00`**.
5. tablet-vtable `[+0x100]` = `CGraphicsTablet::GetInWirelessMode()` (`0x1000692f8`); if wireless,
   the remaining USB reads are skipped.
6. A run of GET_FEATURE reads on the CommInterface (identification only, not mode):
   `[+0x240]`=`GD16GetOffsetReport`, `[+0x238]`=`GD16GetOEMReport`, `[+0x230]`=`GD16GetSerialNumber`,
   `[+0x110]`=`GetVersionReport`.

### The mode-switch payload, proven from disassembly

`CUSBCommInterface::SetToWacomMode()` `0x100381570` (called by `SetHidMode(true)`):
```
0x100381584  bl CCommInterface::GetKernelDriver()   ; gate
0x100381588  cmp w0, 3 ; b.ne -> return 0           ; only proceeds when kernelDriver==3
...
0x1003815d0  mov  w20, 2
0x1003815ec  vector::operator[](0) ; strb w20 -> buf[0] = 0x02   ; report ID
0x1003815fc  vector::operator[](1) ; strb w20 -> buf[1] = 0x02   ; value
0x100381608  ldr  x8, [x8, 0xe0]                    ; = SendUSBCommand
0x100381618  mov  w1, 9   ; EUSBCommand = 9 (SET_FEATURE)
0x10038161c  mov  w3, 6   ; retries = 6
0x100381610  fmov d0, 1.0 ; sleep = 1.0 (ms/units) between retries
0x100381620  blr  x8      ; SendUSBCommand(9, {02,02}, 6, 1.0)
```
=> **SET_FEATURE, reportID 0x02, buffer `02 02`.**

`CUSBCommInterface::SetToHIDMode()` `0x100381484` is byte-identical except `buf = {02, 01}` and
retries=1 (`mov w20,2` then `mov w20,1`; `SendUSBCommand(9,{02,01},1,1.0)`). This is the reverse
(back to HID/boot mouse mode), reached via `SetHidMode(false)` (CommInterface vtable `[+0xf8]`).

`SetDataRateMode(bool)` `0x100381898`: `buf[0]=0x04`, `buf[1]=arg^1`; `SendUSBCommand(9,·,1,1.0)`.
`SetScanModePen(bool)`/`GD16SetScanModePen(bool)` `0x100381c48`/`0x100382d34`: `buf[0]=0x0D`,
`buf[1]=arg^1`. `SetPenScanMode(bool)` `0x1003822ac`: `buf[0]=0x04`, `buf[1]=arg^1`.
`SetScanModePenTouch(pen,touch,x)` `0x100381cf0`: `buf[0]=0x0D`, `buf[1]= (!pen) | (touch?2:0) | (x?4:0)`.

### Recommended clean-room init sequence (mirror of the stock driver)
```
SetReport(Feature, 0x02, {0x02, 0x02})   // enter Wacom high-res mode  (retry up to 6x until IOReturn==0)
SetReport(Feature, 0x04, {0x04, 0x00})   // full data-rate mode
// (optional, if pen scanning is not auto-on):
SetReport(Feature, 0x0D, {0x0D, 0x00})   // enable pen scan
```
Only `02 02` is strictly proven as the report-0x10 enabler; `04 00` / `0D 00` are the adjacent
init writes the stock driver issues and are safe to replicate. **Verify live** with a USB bus
capture (Wireshark/usbmon or macOS `PacketLogger`/IORegistry HID trace) while `TabletDriver`
launches — you should see a SET_FEATURE(0x02)=02 on the pen interface (PID 0x0351).

---

## Goal 3 — Report 0x10 (pen) parsing

CDTH2420 does **not** override the pen parse. Dispatch:

- `CDTH2420GraphicsTablet::ProcessDataPacket(vector<uchar>&)` — `0x1003fbbc0`.
  Only special-cases **report ID 0x11** (on-tablet control / ExpressKeys long-press): it reads
  `packet[1]` into a `bitset<8>` stored at `this+0x898`, and if `GetLongPressTouchKeysOption()` is
  set and `bitset.any()`, invokes a virtual long-press handler using the `double` at `this+0x8a0`.
  **Everything else (including report 0x10) tail-calls `CGD16GraphicsTablet::ProcessDataPacket`.**
- `CGD16GraphicsTablet::ProcessDataPacket(vector<uchar>&)` — `0x1003087c4`. Switches on `packet[0]`:
  IDs `0x03/0x07/0x0C` → `ProcessTabletControls` (`SetOEMCode`, `SetTabletUniqueIdentifier`,
  `GetSensorID`, serial/version); IDs `0x11/0x13/0x14` → pad/controls; **`0x10` and the proximity
  branch → `CGraphicsTablet::ProcessDataPacket` (`0x100064720`)**, the shared/generic parser.
  When entering proximity it also builds a synthetic report with `buf[0]=0x10` and stamps the
  transducer serial (`StoredTransID`/`GetUniqueSerialNumber`) into it (offsets +0x11..).

Field extraction confirmation: on macOS the field decode for report 0x10 is **HID-element / usage
driven**, not hardcoded byte-shifting. Evidence: `CMacHIDCommInterface::CopyDigitizerElementsFromDevice(uint)`
(`0x1000a3568`) plus `ElementWithPage_Usage(CFArray*,int,int)` — the driver copies IOHIDElements by
usage-page/usage and reads their values, so it never hand-parses the 24-bit X/Y from raw bytes.
Consequences for our driver:
- The spec's report-0x10 byte offsets (X 24-bit, Y 24-bit, pressure 16-bit 0..8191, tiltX/Y 8-bit,
  button/prox bits) are correct as derived from the HID **report descriptor** — the stock Mac driver
  relies on that same descriptor via IOHID, which is consistent with our spec.
- Confirmed corroborating constants from code: **pressure max 0x2000 (8192 levels ⇒ 0..8191)** and
  **packet length 27 (0x1b) bytes**. These match the spec exactly.
- We may implement report-0x10 decode either by manual byte offsets (per spec) or by IOHIDValue
  per element (as the stock driver does). Both are valid; manual offsets are simpler and already
  documented.

**Confidence: HIGH** that report 0x10 = pen and is parsed by the generic `CGraphicsTablet`/IOHID
element path; **MEDIUM** on exact intra-report byte offsets from the binary alone (they come from
the HID descriptor, already captured in the spec — confirm with a live draw/press capture).

---

## Goal 4 — Class hierarchy for CDTH2420

Verified via RTTI (`__ZTI22CDTH2420GraphicsTablet` `0x100b6ea30` → base type-info → name string):

```
CWacomDevice
  └─ CGraphicsTablet            (Init 0x466a0, DeviceStart 0x64bc4, ProcessDataPacket 0x64720,
     │                            SetTabletMode 0x69974, SetMaxPressureLevels 0xe5f34)
     └─ CGD20GraphicsTablet     (shared GD-series base; ProcessDataPacket lambda referenced)
        └─ CGD16GraphicsTablet  (DeviceStart 0x307d74  ← issues the mode-switch;
           │                      ProcessDataPacket 0x3087c4; SetHidMode 0x30b458;
           │                      SetDataRateMode 0x30b42c; SendTabletMode 0x30bc28;
           │                      SetTabletMode 0x30807c)
           └─ CDTH2420GraphicsTablet   (vtable 0x100b6e788)
                overrides:  Init (0x3fb840), ProcessDataPacket (0x3fbbc0, report-0x11 long-press),
                            DeviceSleep (0x3fbca0), MakeTabletVote (0x3fbad4), GetNameID (0x3fba24),
                            CreateTabletMenuArea (0x3fbb4c), ProcessLongPressTouchKeys (0x3fb990),
                            ctor/dtor.  Everything else inherited from CGD16GraphicsTablet.
```
(RTTI shows exactly one direct base: `19CGD16GraphicsTablet`.)

Transport stack used by this device: `CGraphicsTablet` → `GetUSBCommInterface()` →
`CUSBCommInterface` (base) whose concrete instance is **`CMacHIDCommInterface`** (vtable
`0x100b501d0`), backed by **`MacHidDevice`** wrapping an `IOHIDDeviceRef` (at `MacHidDevice+0x8`;
last IOReturn at `+0x50`). Report R/W = `IOHIDDeviceSetReport`/`GetReport`.

Object layout offsets observed on `CDTH2420GraphicsTablet`:
`+0x890` std::string (config XPath), `+0x898` bitset<8> (report-0x11 key state),
`+0x8a0` double (long-press pref). CommInterface vtable slots of interest:
`+0xe0`=SendUSBCommand, `+0xf8`=SetToHIDMode, `+0x100`=SetToWacomMode, `+0x110`=GetVersionReport,
`+0x230/238/240`=GD16 Serial/OEM/Offset reads.

---

## Caveat / open verification items
- `SetToWacomMode()` and `SetToHIDMode()` both early-return unless `CCommInterface::GetKernelDriver()==3`.
  That enum selects the active transport (this appears to be the direct-IOHID/userspace path). If a
  live capture shows **no** `02 02` on the wire, the device may already power up in Wacom mode on
  macOS and only the `SetHidMode`/scan writes matter — but the `02 02`/`02 01` register semantics
  still hold and are the authoritative enable/disable.
- Confirm on the wire: SET_FEATURE reportID 0x02 = 0x02 at startup on pen interface PID 0x0351.
- Confirm report-0x10 byte offsets with a live hover/press/tilt capture (already listed as open in
  the spec). Binary corroborates pressure 0..8191 and 27-byte packet length.

## Evidence index (vaddr → symbol)
```
0x1003fb840  CDTH2420GraphicsTablet::Init
0x1003fbbc0  CDTH2420GraphicsTablet::ProcessDataPacket (report 0x11 long-press; else -> CGD16)
0x100307d74  CGD16GraphicsTablet::DeviceStart          (mode-switch call site)
0x10030b458  CGD16GraphicsTablet::SetHidMode(bool)     (true -> SetToWacomMode)
0x10030b42c  CGD16GraphicsTablet::SetDataRateMode(bool)
0x1003087c4  CGD16GraphicsTablet::ProcessDataPacket    (pen 0x10 -> CGraphicsTablet::ProcessDataPacket)
0x100064720  CGraphicsTablet::ProcessDataPacket        (generic/IOHID-element pen decode)
0x1000e5f34  CGraphicsTablet::SetMaxPressureLevels     (called with 0x2000 = 8192)
0x100381570  CUSBCommInterface::SetToWacomMode()       => FEATURE 02 02  *** MODE SWITCH ***
0x100381484  CUSBCommInterface::SetToHIDMode()         => FEATURE 02 01
0x100381898  CUSBCommInterface::SetDataRateMode(bool)  => FEATURE 04 <!en>
0x100381c48  CUSBCommInterface::SetScanModePen(bool)   => FEATURE 0D <!en>
0x100382d34  CUSBCommInterface::GD16SetScanModePen     => FEATURE 0D <!en>
0x1003822ac  CUSBCommInterface::SetPenScanMode(bool)   => FEATURE 04 <!en>
0x100381cf0  CUSBCommInterface::SetScanModePenTouch    => FEATURE 0D <bits>
0x1000a2f1c  CMacHIDCommInterface::SendUSBCommand(...)  (cmd 9=SendFeature, 1=GetFeature)
0x1002cddcc  MacHidDevice::SendFeature -> SendReport(type=2)
0x1002cde60  MacHidDevice::SendReport -> IOHIDDeviceSetReport(dev,type,reportID=data[0],data,len)
0x100b6e788  vtable CDTH2420GraphicsTablet
0x100b501d0  vtable CMacHIDCommInterface
```

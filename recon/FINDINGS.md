# Phase 0 Recon — Verified Findings

Target hardware: **Wacom Cintiq Pro 24 Touch (DTH2420k0)** — pen + multitouch display.
Host: macOS (Darwin 27, Apple Silicon). Wacom driver stack **6.4.13-4**, Team ID `EG27766DY7`.
Recon date: 2026-07-12. Tablet was **NOT connected** during recon (no `0x056a` device in ioreg).

## 1. This is a userspace driver stack, not a kext / DriverKit extension

Both target apps are ordinary sandboxed `.app` background agents (`LSUIElement`, `LSBackgroundOnly`),
universal (x86_64 + arm64), hardened-runtime, sandboxed. No Wacom system extension is installed
(`systemextensionsctl list` shows only OBS + LuLu). So the stock driver injects input **from
userspace** — which means our replacement can too, no kext signing required.

### Process / component map
| Component | Path | Role |
|---|---|---|
| `TabletDriver` (daemon) | `.Tablet/TabletDriver.app` | **The actually-running pen driver daemon** (launched by `com.wacom.wacomtablet` agent, `RunAtLoad`) |
| `WacomTabletDriver.app` | `.Tablet/WacomTabletDriver.app` | 48 MB — same driver core + settings UI (`com.wacom.wacomtablet`) |
| `WacomTouchDriver.app` | `.Tablet/WacomTouchDriver.app` | 15 MB — touch driver (`com.wacom.WacomTouchDriver`) |
| `Wacom_IOManager.app` | `/Library/PrivilegedHelperTools/` | Privileged helper, Mach service `com.wacom.IOManager` — does device I/O + `CoreGraphics` event post |
| `com.wacom.DataStoreMgr.app` | `/Library/PrivilegedHelperTools/` | Preferences/settings store, Mach service `com.wacom.DataStoreMgr` |
| `com.wacom.UpdateHelper.app` | `/Library/PrivilegedHelperTools/` | Updater (root LaunchDaemon) |

LaunchAgents: `com.wacom.wacomtablet`, `com.wacom.IOManager`, `com.wacom.DataStoreMgr`.
IPC is **Mach services** (XPC-style) between the driver and the privileged I/O manager.

### Entitlements (both drivers)
`app-sandbox`, `device.usb`, `device.bluetooth`, `network.client/server`, `apple-events`,
app-groups `EG27766DY7.com.wacom.WacomTabletDriver` / `com.wacom.TabletDriver`.
→ USB access is via the **sandboxed USB entitlement + IOKit userspace** (IOUSBLib / IOHIDManager), not a driver.

## 2. The binaries are UNSTRIPPED C++ — decompilation will be highly productive

- `WacomTabletDriver` arm64 symbol table: **122,735 symbols**, **4,234** containing `GraphicsTablet`.
- Full C++ mangled method names present (e.g. `CMacHIDCommInterface::GetTabletProductID`).
- **Leaked build path** in strings reveals the source tree layout:
  `/Volumes/Data_I/development/R_6.4.13/Wacom/Mac/.../Wacom/Common/TabletDriver/*.cpp`

### Class architecture (recovered from symbols)
- Base: `CGraphicsTablet` → transport variants `CGeneralUSBGraphicsTablet`, `CGeneralBTGraphicsTablet`.
- **Per-model class for the target device: `CDTH2420GraphicsTablet`** (source `CDTH2420GraphicsTablet.cpp`).
- Pen/transducer hierarchy: `C…PressureStylus`, `C…Pen`, `C…Transducer` (per pen model).
- Tablet controls (ExpressKeys/touch ring): `CCTTabletControls`, `CDTH271TabletControls`, etc.
- Transport / HID: `CMacHIDCommInterface`, `CMacVcpHIDConnector`, `CCommInterface`, `MacHidDevice`.
- Top-level: `CMacTabletDriver`.

## 3. Input injection uses the legacy macOS tablet-event path (CoreGraphics/NXEvent)

Strings show `NXTabletPointData`, `ProximityEvent.vendorID`, `CLLMouseEvent::PostEvent`,
`CLLKeyDownEvent/KeyUp::PostEvent`, `NXEvent.*`. This is the classic
`CGEventCreate` + `kCGEventTabletProximity` / `kCGTabletEventPointData` (a.k.a. `NXEventData`
tablet fields) injection route. `Wacom_IOManager` links **CoreGraphics** and **IOKit** only —
it is the process that reads HID and posts synthesized events. This is a fully documented,
reproducible injection path (`CGEventCreate`, `CGEventPost`, tablet event fields).

## 4. Touch has a PUBLIC, documented SDK — major shortcut

`WacomTouchDriver` links `/Library/Frameworks/WacomMultiTouch.framework`, which ships **public
headers**: `WacomMultiTouch.h`, `WacomMultiTouchTypes.h`. C API:
`WacomMTInitialize`, `WacomMTGetAttachedDeviceIDs`, `WacomMTGetDeviceCapabilities`,
`WacomMTRegisterFingerReadCallback` (→ `WacomMTFingerCollection`), blob + raw callbacks.
→ Touch finger data can be consumed via a **supported API** without reverse engineering the
touch USB protocol at all (though raw HID is still an option).

## 5. USB identity constants

Wacom USB vendor ID is `0x056a` (1386). Binary references `GetTabletProductID`, `idVendor:0x%04x`,
`GET_PRODUCTID(sensorInfo->mSensorID)`. The concrete PID for the DTH2420k0 must be read from the
device when connected (see Phase 3) — Wacom Cintiq Pro 24 Touch is commonly `0x0357`/`0x0358`
region but MUST be confirmed live, not assumed.

## Implications for the build
1. No kernel/DriverKit work strictly required — a userspace daemon (IOHIDManager read →
   CGEvent tablet-event post) mirrors exactly what the stock stack does.
2. The pen protocol is model-specific and lives in `CDTH2420GraphicsTablet` +
   its `CommInterface`/report-parsing — this is the primary decompilation target.
3. Touch is reachable through the public `WacomMultiTouch` framework OR raw HID.
4. Because binaries are unstripped, Ghidra/Hopper will name most functions for us — the
   protocol decode is mostly a matter of reading `CDTH2420GraphicsTablet::*` and the shared
   report parser, then confirming against live HID captures.

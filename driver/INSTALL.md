# Installing the driver as a persistent LaunchAgent

The driver runs as a per-user LaunchAgent, packaged as an `.app` bundle. The `.app`
identity is **required** — TCC's Accessibility service (needed to post cursor/pressure
events) does not reliably honor grants for a bare CLI binary, though Input Monitoring
does. Wrapping the executable in a signed `.app` fixes this.

**Sign with a stable self-signed identity, not ad-hoc.** Ad-hoc (`codesign -s -`)
changes the code hash on every rebuild, which resets the Privacy (TCC) grants and forces
re-adding the app to Input Monitoring + Accessibility each time. A stable self-signed
Code Signing certificate keeps the grants across rebuilds.

One-time cert setup (Keychain Access → Certificate Assistant → Create a Certificate):
name `modfox-codesign`, Identity Type **Self Signed Root**, Certificate Type **Code Signing**.
Then sign with `codesign -s modfox-codesign …` (self-signed/untrusted is fine for local TCC).

## Layout (as installed)
- App bundle: `~/Applications/Nib.app` (executable at `Contents/MacOS/nib`)
- LaunchAgent: `~/Library/LaunchAgents/com.modfox.nib.plist` (`run` at load, KeepAlive)
- Logs: `~/Library/Logs/nib.log`
- Calibration: `~/.config/nib/calibration.json`

## Build + install / update
```
cd driver
swift build -c release
APP="$HOME/Applications/Nib.app"
mkdir -p "$APP/Contents/MacOS"
cp .build/release/nib "$APP/Contents/MacOS/nib"
# Info.plist is committed under packaging/ — copy it if recreating the bundle.
codesign -s modfox-codesign --force --deep --identifier com.modfox.nib "$APP"
launchctl kickstart -k gui/$(id -u)/com.modfox.nib   # if already loaded
```
Signing with the stable `modfox-codesign` identity keeps the TCC grants across rebuilds —
verified: re-sign + reload leaves `Accessibility trusted = true` with no re-granting.

## First-time setup
1. Disable the (non-functional-on-this-macOS) stock vendor driver permanently:
   ```
   launchctl bootout  gui/$(id -u)/com.wacom.wacomtablet 2>/dev/null
   launchctl bootout  gui/$(id -u)/Wacom_IOManager 2>/dev/null
   launchctl disable  gui/$(id -u)/com.wacom.wacomtablet
   launchctl disable  gui/$(id -u)/Wacom_IOManager
   ```
2. Load our agent: `launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.modfox.nib.plist`
3. Grant **Nib.app** in System Settings › Privacy & Security:
   - **Input Monitoring** (read pen HID + send mode-switch)
   - **Accessibility** (post cursor/pressure events)
   Then reload: `launchctl bootout … && launchctl bootstrap …` (or kickstart -k).
4. Verify: `tail -f ~/Library/Logs/nib.log` should show
   `Accessibility trusted = true` and `mode-switch sent (0x02=ok, 0x04=ok)`.

## Calibrate
```
launchctl bootout gui/$(id -u)/com.modfox.nib   # stop the running agent
~/Applications/Nib.app/Contents/MacOS/nib calibrate
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.modfox.nib.plist
```

## Uninstall / revert to nothing
```
launchctl bootout gui/$(id -u)/com.modfox.nib
rm ~/Library/LaunchAgents/com.modfox.nib.plist
rm -rf ~/Applications/Nib.app
```

## TODO for a distributable build
- Sign with a Developer ID identity + notarize so the cdhash is stable and grants persist
  across updates (ad-hoc re-signing currently resets TCC).

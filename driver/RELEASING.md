# Releasing a signed, notarized build

Distributable builds are **signed with a Developer ID Application certificate and
notarized by Apple**, then published as a `.dmg` on GitHub Releases. Notarization
is what lets other people download `Nib.app` and open it without Gatekeeper
warnings — and, because the code hash is stable across notarized updates, it keeps
the Input Monitoring + Accessibility (TCC) grants from resetting on every update
(the problem called out in `INSTALL.md`).

This requires an **Apple Developer Program** membership ($99/yr).

---

## One-time setup

### 1. Create the Developer ID Application certificate

In Xcode: **Settings → Accounts → (your team) → Manage Certificates → `+` →
Developer ID Application**. (Or create it at
<https://developer.apple.com/account/resources/certificates>.)

Confirm it's installed and note the exact identity string:

```
security find-identity -v -p codesigning
# -> "Developer ID Application: Your Name (TEAMID)"
```

That full string (including the `(TEAMID)`) is your **`SIGNING_IDENTITY`**.

### 2. Create an App Store Connect API key (for notarization)

`notarytool` authenticates with an API key instead of your Apple ID + password —
better for CI (no 2FA prompts). At
<https://appstoreconnect.apple.com/access/integrations/api> → **Keys** → `+`:

- Access role: **Developer** is sufficient for notarization.
- Download the `AuthKey_XXXXXXXX.p8` (**you can only download it once**).
- Note the **Key ID** and the **Issuer ID** shown on that page.

### 3. Verify the whole pipeline locally (recommended before wiring CI)

Store the notarization credentials as a reusable keychain profile:

```
xcrun notarytool store-credentials nib-notary \
  --key /path/to/AuthKey_XXXXXXXX.p8 \
  --key-id  <KEY_ID> \
  --issuer  <ISSUER_ID>
```

Then build → sign → notarize → staple in one go:

```
cd driver
scripts/build-app.sh build
SIGNING_IDENTITY="Developer ID Application: Your Name (TEAMID)" \
NOTARY_PROFILE=nib-notary \
  scripts/release.sh build
# -> build/Nib-<version>.dmg  (signed, notarized, stapled)
```

A green run ends with `The staple and validate action worked!` and a Gatekeeper
`accepted` line. That same DMG is exactly what CI produces.

---

## CI setup (GitHub Actions)

The `.github/workflows/release.yml` workflow runs on any `v*` tag: it imports the
cert into an ephemeral keychain, builds the universal app, signs + notarizes +
staples the DMG, and publishes it to a GitHub Release.

> **The workflow is dormant by default.** Its job is gated on
> `if: vars.RELEASE_ENABLED == 'true'`, so a `v*` tag push does nothing until you
> opt in. When you're ready, set a repository **variable** `RELEASE_ENABLED` to
> `true` (Settings → Secrets and variables → Actions → **Variables**). Removing the
> variable (or setting it to anything else) disables releases again.

Add these under **Settings → Secrets and variables → Actions → New repository
secret**:

| Secret                     | How to produce it |
| -------------------------- | ----------------- |
| `MACOS_CERTIFICATE`        | Export the Developer ID cert **with its private key** from Keychain Access as a `.p12`, then `base64 -i cert.p12 \| pbcopy`. |
| `MACOS_CERTIFICATE_PWD`    | The password you set when exporting the `.p12`. |
| `MACOS_SIGNING_IDENTITY`   | The full `Developer ID Application: Your Name (TEAMID)` string. |
| `KEYCHAIN_PASSWORD`        | Any random string — names the throwaway CI keychain. |
| `NOTARY_KEY`               | `base64 -i AuthKey_XXXXXXXX.p8 \| pbcopy`. |
| `NOTARY_KEY_ID`            | The API key's Key ID. |
| `NOTARY_ISSUER`            | The App Store Connect Issuer ID. |

> Exporting the `.p12`: in **Keychain Access**, expand the certificate so its
> private key shows, select **both** rows, right-click → *Export 2 items…* →
> Personal Information Exchange (.p12).

### Cut a release

```
git tag v0.2.0
git push origin v0.2.0
```

The workflow builds, notarizes, and attaches `Nib-0.2.0.dmg` to a new
`v0.2.0` Release with auto-generated notes. The version string is derived from
the tag (`v0.2.0` → `0.2.0`), so no need to hand-edit `Info.plist`.

---

## How versioning works

`scripts/build-app.sh` stamps the bundle from git at build time and never mutates
the committed `packaging/Info.plist`:

- `CFBundleShortVersionString` ← latest tag with the `v` stripped (`VERSION` env overrides).
- `CFBundleVersion` ← commit count (`BUILD_NUM` env overrides).

## Notes

- The app is signed with the **Hardened Runtime** (required for notarization) and
  an empty `packaging/entitlements.plist` — Nib needs no special entitlements
  (HID + CGEvent access is granted at runtime via TCC, not entitlements) and must
  **not** be sandboxed, which would block raw HID access.
- Local dev installs (`INSTALL.md`) still use the self-signed `modfox-codesign`
  identity — that's fine for a single machine. Developer ID + notarization is only
  needed for the artifacts you hand to other people.

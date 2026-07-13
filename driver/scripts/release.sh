#!/usr/bin/env bash
#
# Sign (Developer ID + Hardened Runtime), package as a DMG, notarize, and staple.
# Produces a notarized  build/Nib-<version>.dmg  ready to attach to a GitHub Release.
#
# Assumes scripts/build-app.sh has already produced build/Nib.app.
#
# Required env:
#   SIGNING_IDENTITY   "Developer ID Application: Your Name (TEAMID)"
#
# Notarization credentials — provide ONE of:
#   NOTARY_PROFILE     name of a stored `notarytool store-credentials` profile   (local)
#   -- or --                                                                     (CI)
#   NOTARY_KEY_PATH    path to the App Store Connect API key .p8
#   NOTARY_KEY_ID      the key's Key ID
#   NOTARY_ISSUER      the App Store Connect issuer UUID
#
set -euo pipefail

cd "$(dirname "$0")/.."                    # -> driver/

OUT="${1:-build}"
APP="$OUT/Nib.app"
[[ -d "$APP" ]] || { echo "error: $APP not found — run scripts/build-app.sh first" >&2; exit 1; }

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
DMG="$OUT/Nib-$VERSION.dmg"

: "${SIGNING_IDENTITY:?set SIGNING_IDENTITY to your Developer ID Application identity}"

# --- notarytool credential args (profile locally, API key in CI) -------------
notary_args=()
if [[ -n "${NOTARY_PROFILE:-}" ]]; then
  notary_args=(--keychain-profile "$NOTARY_PROFILE")
else
  : "${NOTARY_KEY_PATH:?set NOTARY_PROFILE or the NOTARY_KEY_* trio}"
  : "${NOTARY_KEY_ID:?}"
  : "${NOTARY_ISSUER:?}"
  notary_args=(--key "$NOTARY_KEY_PATH" --key-id "$NOTARY_KEY_ID" --issuer "$NOTARY_ISSUER")
fi

echo "==> Codesign app (Hardened Runtime, secure timestamp)"
codesign --force --options runtime --timestamp \
  --entitlements packaging/entitlements.plist \
  --sign "$SIGNING_IDENTITY" \
  "$APP"
codesign --verify --strict --verbose=2 "$APP"

echo "==> Notarize the app, then staple the ticket into the bundle"
# Staple the .app itself so it launches offline once copied out of the DMG.
APP_ZIP="$OUT/Nib.app.zip"
ditto -c -k --keepParent "$APP" "$APP_ZIP"
xcrun notarytool submit "$APP_ZIP" "${notary_args[@]}" --wait
xcrun stapler staple "$APP"
rm -f "$APP_ZIP"

echo "==> Build DMG from the stapled app"
STAGE="$(mktemp -d)"
cp -R "$APP" "$STAGE/Nib.app"
ln -s /Applications "$STAGE/Applications"          # drag-to-install affordance
rm -f "$DMG"
hdiutil create -volname "Nib" -srcfolder "$STAGE" -ov -format UDZO "$DMG"
rm -rf "$STAGE"

echo "==> Sign, notarize, and staple the DMG"
codesign --force --timestamp --sign "$SIGNING_IDENTITY" "$DMG"
xcrun notarytool submit "$DMG" "${notary_args[@]}" --wait
xcrun stapler staple "$DMG"
xcrun stapler validate "$DMG"

echo "==> Gatekeeper assessment"
spctl -a -t open --context context:primary-signature -v "$DMG" || true

echo ""
echo "Done: $DMG"

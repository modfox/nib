#!/usr/bin/env bash
#
# Build the release binary and assemble an *unsigned* Nib.app bundle.
# Shared by local dev and the release workflow; signing is done separately
# (scripts/release.sh) so this step needs no certificates.
#
# Usage:  scripts/build-app.sh [OUTPUT_DIR]        (default OUTPUT_DIR=build)
# Env:
#   VERSION    CFBundleShortVersionString (default: latest git tag, sans "v")
#   BUILD_NUM  CFBundleVersion            (default: git commit count)
#
set -euo pipefail

cd "$(dirname "$0")/.."                    # -> driver/

OUT="${1:-build}"
APP="$OUT/Nib.app"

VERSION="${VERSION:-$(git describe --tags --abbrev=0 2>/dev/null | sed 's/^v//' || echo 0.0.0)}"
BUILD_NUM="${BUILD_NUM:-$(git rev-list --count HEAD 2>/dev/null || echo 1)}"

echo "==> Building Nib.app  (version=$VERSION  build=$BUILD_NUM)"

# Universal binary so the DMG runs on both Apple Silicon and Intel.
ARCHS=(--arch arm64 --arch x86_64)
swift build -c release "${ARCHS[@]}"
BIN="$(swift build -c release "${ARCHS[@]}" --show-bin-path)/nib"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN"                      "$APP/Contents/MacOS/nib"
cp packaging/Info.plist        "$APP/Contents/Info.plist"
cp packaging/Nib.icns          "$APP/Contents/Resources/Nib.icns"

# Stamp the version into the copied plist (never mutate the committed template).
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD_NUM"          "$APP/Contents/Info.plist"

echo "==> Assembled $APP"

#!/bin/bash
# Packages build/Icicle.app into a drag-to-Applications disk image: build/Icicle.dmg (or the path given).
# Needs dmgbuild; the first run installs it into a private virtualenv next to the signing keychain.
set -euo pipefail
cd "$(dirname "$0")"

OUT="${1:-build/Icicle.dmg}"
APP="build/Icicle.app"
[[ -d "$APP" ]] || { echo "Build the app first: ./build.sh" >&2; exit 1; }

TOOLS_DIR="$HOME/Library/Application Support/Icicle Build"
VENV="$TOOLS_DIR/venv"
if [[ ! -x "$VENV/bin/dmgbuild" ]]; then
    echo "Installing dmgbuild…"
    python3 -m venv "$VENV"
    "$VENV/bin/pip" install -q --disable-pip-version-check dmgbuild
fi

echo "Rendering disk image background…"
WORK="build/dmg"
rm -rf "$WORK" && mkdir -p "$WORK"
swiftc -O tools/make_dmg_background.swift -o "$WORK/make_background"
"$WORK/make_background" "$WORK"
# One TIFF holding both resolutions, so the window is sharp on Retina displays.
tiffutil -cathidpicheck "$WORK/background.png" "$WORK/background@2x.png" -out "$WORK/background.tiff" 2>/dev/null

VERSION="$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "$APP/Contents/Info.plist")"
rm -f "$OUT"
"$VENV/bin/dmgbuild" -s tools/dmg_settings.py \
    -D app="$APP" -D background="$WORK/background.tiff" -D icon="$APP/Contents/Resources/AppIcon.icns" \
    "Icicle $VERSION" "$OUT" >/dev/null

# Same local identity as the app (see build.sh), so the image's signature matches its contents.
KEYCHAIN="$TOOLS_DIR/signing.keychain-db"
if [[ -f "$KEYCHAIN" ]]; then
    security unlock-keychain -p icicle "$KEYCHAIN"
    codesign --force --keychain "$KEYCHAIN" --sign "Icicle Local Signing" "$OUT"
fi
echo "Built $OUT"

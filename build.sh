#!/bin/bash
# Builds build/Icicle.app. Pass --install to copy it into /Applications afterwards.
set -euo pipefail
cd "$(dirname "$0")"

APP="build/Icicle.app"
SDK="$(xcrun --show-sdk-path)"
ARCH="$(uname -m)"

rm -rf build
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

echo "Compiling…"
swiftc -O -swift-version 5 \
    -sdk "$SDK" -target "$ARCH-apple-macos14.0" \
    -framework AppKit -framework SwiftUI -framework Carbon -framework ServiceManagement \
    Sources/*.swift \
    -o "$APP/Contents/MacOS/Icicle"

cp Info.plist "$APP/Contents/Info.plist"

echo "Rendering icon…"
swiftc -O -sdk "$SDK" -target "$ARCH-apple-macos14.0" tools/make_icon.swift -o build/make_icon
build/make_icon build/AppIcon.iconset
iconutil -c icns build/AppIcon.iconset -o "$APP/Contents/Resources/AppIcon.icns"

codesign --force --sign - "$APP"

if [[ "${1:-}" == "--install" ]]; then
    pkill -x Icicle || true
    rm -rf /Applications/Icicle.app
    cp -R "$APP" /Applications/
    echo "Installed to /Applications/Icicle.app"
fi

echo "Built $APP"

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
    Sources/*.swift Sources/LockScreen/*.swift \
    -o "$APP/Contents/MacOS/Icicle"

cp Info.plist "$APP/Contents/Info.plist"

# The screen saver that puts the lock screen on the real macOS lock screen: the same views, compiled as a
# loadable bundle. It keeps Glass Lock's name and identifier so an existing choice in System Settings carries over.
echo "Compiling screen saver…"
SAVER="$APP/Contents/Resources/Glass Lock.saver"
mkdir -p "$SAVER/Contents/MacOS"
swiftc -O -swift-version 5 -parse-as-library -module-name GlassLockSaver \
    -sdk "$SDK" -target "$ARCH-apple-macos14.0" \
    -emit-library -Xlinker -bundle -framework ScreenSaver \
    Sources/LockScreen/*.swift Saver/GlassLockSaverView.swift \
    -o "$SAVER/Contents/MacOS/GlassLockSaver"
VERSION="$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" Info.plist)"
BUILD="$(/usr/libexec/PlistBuddy -c "Print CFBundleVersion" Info.plist)"
# The build number carries a timestamp: the app replaces the installed copy whenever the two differ.
sed -e "s#__VERSION__#$VERSION#g" -e "s#__BUILD__#$BUILD.$(date +%s)#g" -e "s#__BUNDLE_ID__#io.github.local.glasslock#g" \
    Saver/Info.plist > "$SAVER/Contents/Info.plist"
plutil -lint "$SAVER/Contents/Info.plist" >/dev/null

echo "Rendering icon…"
swiftc -O -sdk "$SDK" -target "$ARCH-apple-macos14.0" tools/make_icon.swift -o build/make_icon
build/make_icon build/AppIcon.iconset
iconutil -c icns build/AppIcon.iconset -o "$APP/Contents/Resources/AppIcon.icns"

# Sign with a local self-signed identity kept in its own keychain. Unlike ad-hoc signing, the signature
# stays the same across rebuilds, so macOS keeps the Accessibility permission after every update.
SIGN_DIR="$HOME/Library/Application Support/Icicle Build"
KEYCHAIN="$SIGN_DIR/signing.keychain-db"
IDENTITY="Icicle Local Signing"
if [[ ! -f "$KEYCHAIN" ]]; then
    echo "Creating local signing identity…"
    mkdir -p "$SIGN_DIR"
    TMP="$(mktemp -d)"
    printf '[req]\ndistinguished_name=dn\nx509_extensions=ext\nprompt=no\n[dn]\nCN=%s\n[ext]\nbasicConstraints=critical,CA:false\nkeyUsage=critical,digitalSignature\nextendedKeyUsage=critical,codeSigning\n' "$IDENTITY" > "$TMP/cert.cnf"
    openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -config "$TMP/cert.cnf" -keyout "$TMP/key.pem" -out "$TMP/cert.pem" 2>/dev/null
    openssl pkcs12 -export -legacy -inkey "$TMP/key.pem" -in "$TMP/cert.pem" -out "$TMP/id.p12" -passout pass:icicle 2>/dev/null \
        || openssl pkcs12 -export -inkey "$TMP/key.pem" -in "$TMP/cert.pem" -out "$TMP/id.p12" -passout pass:icicle
    security create-keychain -p icicle "$KEYCHAIN"
    security unlock-keychain -p icicle "$KEYCHAIN"
    security import "$TMP/id.p12" -k "$KEYCHAIN" -P icicle -T /usr/bin/codesign >/dev/null
    security set-key-partition-list -S apple-tool:,apple: -s -k icicle "$KEYCHAIN" >/dev/null
    rm -rf "$TMP"
fi
security unlock-keychain -p icicle "$KEYCHAIN"
codesign --force --keychain "$KEYCHAIN" --sign "$IDENTITY" "$SAVER"
codesign --force --keychain "$KEYCHAIN" --sign "$IDENTITY" "$APP"

if [[ "${1:-}" == "--install" ]]; then
    pkill -x Icicle || true
    rm -rf /Applications/Icicle.app
    cp -R "$APP" /Applications/
    echo "Installed to /Applications/Icicle.app"
fi

echo "Built $APP"

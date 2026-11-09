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
codesign --force --keychain "$KEYCHAIN" --sign "$IDENTITY" "$APP"

if [[ "${1:-}" == "--install" ]]; then
    pkill -x Icicle || true
    rm -rf /Applications/Icicle.app
    cp -R "$APP" /Applications/
    echo "Installed to /Applications/Icicle.app"
fi

echo "Built $APP"

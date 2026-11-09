#!/bin/bash
# Publishes a new version: bumps the version, builds and installs the app, tags it,
# and creates a GitHub Release with a drag-to-install Icicle.dmg (plus a zip).
#
#   ./release.sh            # 1.2.3 -> 1.2.4
#   ./release.sh minor      # 1.2.3 -> 1.3.0
#   ./release.sh major      # 1.2.3 -> 2.0.0
#   ./release.sh 1.5.0      # exact version
#
# Set RELEASE_TRAILER to append a trailer line (e.g. Co-Authored-By) to the release commit.
set -euo pipefail
cd "$(dirname "$0")"

if [[ -n "$(git status --porcelain)" ]]; then
    echo "Commit your changes first; the release is built from what's committed." >&2
    exit 1
fi

PLIST=Info.plist
CURRENT="$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "$PLIST")"
IFS=. read -r MAJOR MINOR PATCH <<< "$CURRENT"
MAJOR=${MAJOR:-1}; MINOR=${MINOR:-0}; PATCH=${PATCH:-0}

case "${1:-patch}" in
    major) VERSION="$((MAJOR + 1)).0.0" ;;
    minor) VERSION="$MAJOR.$((MINOR + 1)).0" ;;
    patch) VERSION="$MAJOR.$MINOR.$((PATCH + 1))" ;;
    [0-9]*.[0-9]*.[0-9]*) VERSION="$1" ;;
    *) echo "Usage: $0 [major|minor|patch|X.Y.Z]" >&2; exit 1 ;;
esac
TAG="v$VERSION"
if git rev-parse -q --verify "refs/tags/$TAG" >/dev/null; then
    echo "$TAG already exists." >&2
    exit 1
fi

BUILD_NUMBER="$(( $(/usr/libexec/PlistBuddy -c "Print CFBundleVersion" "$PLIST") + 1 ))"
/usr/libexec/PlistBuddy -c "Set CFBundleShortVersionString $VERSION" -c "Set CFBundleVersion $BUILD_NUMBER" "$PLIST"
echo "Releasing Icicle $VERSION (build $BUILD_NUMBER)"

./build.sh --install
DMG="build/Icicle-$TAG.dmg"
./make_dmg.sh "$DMG"
ZIP="build/Icicle-$TAG.zip"
ditto -c -k --keepParent build/Icicle.app "$ZIP"

# Notes: every change since the previous release.
PREVIOUS="$(git describe --tags --abbrev=0 2>/dev/null || true)"
RANGE="${PREVIOUS:+$PREVIOUS..}HEAD"
NOTES="$(mktemp)"
{
    echo "## What's new"
    echo
    git log --no-merges --format='- %s' "$RANGE" | grep -v '^- Release v' || true
    echo
    echo "## Install"
    echo
    echo "Download **Icicle-$TAG.dmg**, open it and drag **Icicle** onto the Applications folder."
    echo "(Icicle-$TAG.zip has the same app, if you prefer.)"
    echo
    echo "It isn't notarized by Apple, so the first time macOS may refuse to open it: go to"
    echo "System Settings → Privacy & Security and click **Open Anyway**. Or build it yourself with \`./build.sh --install\`."
} > "$NOTES"

git add "$PLIST"
git commit -q -m "Release $TAG" ${RELEASE_TRAILER:+-m "$RELEASE_TRAILER"}
git tag -a "$TAG" -m "Icicle $VERSION"
git push -q origin HEAD "$TAG"

gh release create "$TAG" "$DMG" "$ZIP" --title "Icicle $VERSION" --notes-file "$NOTES"
rm -f "$NOTES"

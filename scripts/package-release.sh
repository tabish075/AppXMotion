#!/bin/zsh
# Builds a universal "AppX Motion.app" and packages it as a drag-to-install DMG in ./dist.
#   scripts/package-release.sh 1.0.0
set -euo pipefail
cd "$(dirname "$0")/.."
VERSION=${1:?usage: scripts/package-release.sh <version>}

/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" Resources/Info.plist
scripts/build-app.sh --universal

mkdir -p dist
STAGE=$(mktemp -d)
cp -R "build/AppX Motion.app" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
DMG="dist/AppX-Motion-$VERSION-macOS.dmg"
rm -f "$DMG"
hdiutil create -volname "AppX Motion $VERSION" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
rm -rf "$STAGE"
(cd dist && ditto -c -k --keepParent ../"build/AppX Motion.app" "AppX-Motion-$VERSION-macOS.zip")
shasum -a 256 "$DMG" "dist/AppX-Motion-$VERSION-macOS.zip"

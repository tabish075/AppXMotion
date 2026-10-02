#!/bin/zsh
# Builds "AppX Motion.app" (release) into ./build.
#   scripts/build-app.sh                → build/AppX Motion.app for this Mac
#   scripts/build-app.sh --universal    → Apple Silicon + Intel in one app
#   scripts/build-app.sh --install      → also copies it to /Applications
set -euo pipefail
cd "$(dirname "$0")/.."

UNIVERSAL=0
INSTALL=0
for arg in "$@"; do
  case $arg in
    --universal) UNIVERSAL=1 ;;
    --install) INSTALL=1 ;;
  esac
done

mkdir -p build
if [[ $UNIVERSAL == 1 ]]; then
  swift build -c release --arch arm64
  swift build -c release --arch x86_64
  BIN=build/AppXMotion-universal
  lipo -create .build/arm64-apple-macosx/release/AppXMotion .build/x86_64-apple-macosx/release/AppXMotion -output "$BIN"
else
  swift build -c release
  BIN="$(swift build -c release --show-bin-path)/AppXMotion"
fi

APP="build/AppX Motion.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/AppXMotion"
cp Resources/Info.plist "$APP/Contents/Info.plist"

# App icon (drawn by scripts/make-icon.swift)
if [[ ! -f build/AppIcon.icns ]]; then
  ICONSET=build/AppIcon.iconset
  rm -rf "$ICONSET" && mkdir -p "$ICONSET"
  swift scripts/make-icon.swift build/icon-1024.png >/dev/null
  for s in 16 32 128 256 512; do
    sips -z $s $s build/icon-1024.png --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
    sips -z $((s*2)) $((s*2)) build/icon-1024.png --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
  done
  iconutil -c icns "$ICONSET" -o build/AppIcon.icns
fi
cp build/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

codesign --force --deep --sign - "$APP" >/dev/null
echo "Built $APP ($(lipo -archs "$APP/Contents/MacOS/AppXMotion"))"

if [[ $INSTALL == 1 ]]; then
  rm -rf "/Applications/AppX Motion.app"
  cp -R "$APP" "/Applications/AppX Motion.app"
  echo "Installed to /Applications/AppX Motion.app"
fi

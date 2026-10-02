#!/bin/zsh
# Rebuilds the debug binary into build/AppXMotionDev.app and launches it.
#   scripts/dev-run.sh [file1 [file2]]
set -euo pipefail
cd "$(dirname "$0")/.."
swift build 2>&1 | grep -E "error:|Build complete" || true
pkill -f "AppXMotionDev.app" 2>/dev/null || true
DEV=build/AppXMotionDev.app
mkdir -p $DEV/Contents/MacOS $DEV/Contents/Resources
cp .build/debug/AppXMotion $DEV/Contents/MacOS/AppXMotion
sed 's/com.evolvosofts.appxmotion/com.evolvosofts.appxmotion.dev/' Resources/Info.plist > $DEV/Contents/Info.plist
[[ -f build/AppIcon.icns ]] && cp build/AppIcon.icns $DEV/Contents/Resources/
codesign --force -s - $DEV 2>/dev/null
sleep 0.5
ARGS=(-n $DEV)
[[ $# -gt 0 ]] && ARGS+=(--env "APPXMOTION_OPEN=${(j:|:)@}")
[[ -n "${APPXMOTION_DEBUG:-}" ]] && ARGS+=(--env "APPXMOTION_DEBUG=$APPXMOTION_DEBUG")
open "${ARGS[@]}"

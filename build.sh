#!/bin/zsh
# Builds an Apple Silicon release, wraps it into build/CPUMemoryMonitor.app (ad-hoc signed)
# and packages it as build/CPUMemoryMonitor.dmg with an Applications shortcut for drag-to-install.
set -euo pipefail
cd "$(dirname "$0")"

swift build -c release --arch arm64

APP=build/CPUMemoryMonitor.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp .build/release/CPUMemoryMonitor "$APP/Contents/MacOS/"
cp Resources/Info.plist "$APP/Contents/"
codesign --force --sign - "$APP"

DMG=build/CPUMemoryMonitor.dmg
STAGING=build/dmg
rm -rf "$STAGING" "$DMG"
mkdir -p "$STAGING"
cp -R "$APP" "$STAGING/"
ln -s /Applications "$STAGING/Applications"
hdiutil create -volname "CPU Memory Monitor" -srcfolder "$STAGING" -format UDZO -ov "$DMG" >/dev/null
rm -rf "$STAGING"

echo "Built $APP and $DMG"

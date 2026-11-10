#!/bin/bash
# Builds Dropster.app (release, ad-hoc signed) into ./build.
set -euo pipefail
cd "$(dirname "$0")/.."
CONFIG="${1:-release}"
VERSION="$(cat VERSION 2>/dev/null || echo 0.1.0)"

swift build -c "$CONFIG" --product Dropster
swift build -c "$CONFIG" --product dropster-cli
BIN="$(swift build -c "$CONFIG" --show-bin-path)"

APP="build/Dropster.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/bin"
cp "$BIN/Dropster" "$APP/Contents/MacOS/Dropster"
cp "$BIN/dropster-cli" "$APP/Contents/Resources/bin/dropster"

sed "s/__VERSION__/$VERSION/g" Packaging/Info.plist > "$APP/Contents/Info.plist"
# Brand assets (regenerate with: swift scripts/make-icon.swift).
# The Icon Composer document compiles to Assets.car (macOS 26+ renders it natively) plus a
# fallback AppIcon.icns; without actool, the pre-rendered .icns is used.
if xcrun --find actool >/dev/null 2>&1; then
  xcrun actool Packaging/AppIcon.icon --compile "$APP/Contents/Resources" --platform macosx \
    --minimum-deployment-target 15.0 --app-icon AppIcon --output-partial-info-plist /dev/null >/dev/null
else
  cp Packaging/AppIcon.icns "$APP/Contents/Resources/"
fi
cp Packaging/MenuBarIcon.png Packaging/MenuBarIcon@2x.png "$APP/Contents/Resources/"
codesign --force --sign - --options runtime --entitlements Packaging/Dropster.entitlements "$APP"
echo "Built $APP ($VERSION)"

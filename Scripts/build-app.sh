#!/bin/bash
# Builds a universal (x86_64 + arm64) Clementine.app with only the Command Line Tools.
#   Scripts/build-app.sh [version] [--single]   # --single: current arch only (faster)
set -euo pipefail
cd "$(dirname "$0")/.."
VERSION="${1:-0.1.0}"
if [[ "${2:-}" == "--single" ]]; then
  swift build -c release
  BIN=".build/release/Clementine"
else
  swift build -c release --arch x86_64 --arch arm64
  BIN=".build/apple/Products/Release/Clementine"
fi

APP="dist/Clementine.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Clementine"
cp Resources/AppIcon.icns "$APP/Contents/Resources/"   # regenerate: swift Scripts/make-icon.swift
sed "s/__VERSION__/$VERSION/g" Resources/Info.plist > "$APP/Contents/Info.plist"
echo -n "APPL????" > "$APP/Contents/PkgInfo"
codesign --force --deep --sign - "$APP"
echo "built $APP ($(lipo -archs "$APP/Contents/MacOS/Clementine" 2>/dev/null || echo single-arch))"
echo "run:   open $APP        (menu-bar icon appears; drag a file in Finder and hold Shift)"
echo "test:  $APP/Contents/MacOS/Clementine --selftest"

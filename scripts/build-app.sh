#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
swift build -c release --product Dabber
APP=build/Dabber.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/Dabber "$APP/Contents/MacOS/Dabber"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cp Resources/Info.plist "$APP/Contents/Info.plist"
codesign --force --sign "Dabber Dev" "$APP"
codesign -d -r- "$APP" 2>&1 | grep designated

#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
ID=local.dabber.tonehelper
APP=build/ToneHelper.app
rm -rf "$APP"
cp -R build/Dabber.app "$APP"
plutil -replace CFBundleIdentifier -string "$ID" "$APP/Contents/Info.plist"
plutil -replace CFBundleName -string "Dabber Tone Helper" "$APP/Contents/Info.plist"
codesign --force --sign "Dabber Dev" "$APP"
codesign -d -r- "$APP" 2>&1 | grep designated
echo "$APP"

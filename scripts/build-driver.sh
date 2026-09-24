#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
OUT=build/DabberMic.driver
rm -rf "$OUT"
mkdir -p "$OUT/Contents/MacOS"
cp Driver/Info.plist "$OUT/Contents/Info.plist"
defines=(
  -DkDriver_Name='"Dabber"'
  -DkHas_Driver_Name_Format=false
  -DkPlugIn_BundleID='"local.dabber.DabberMic"'
  -DkManufacturer_Name='"Dabber"'
  -DkDevice_Name='"Dabber Mic"'
  -DkDevice_HasInput=true
  -DkDevice_HasOutput=false
  -DkDevice_IsHidden=false
  -DkDevice2_Name='"Dabber Feed"'
  -DkDevice2_HasInput=false
  -DkDevice2_HasOutput=true
  -DkDevice2_IsHidden=true
  -DkNumber_Of_Channels=2
  -DkSampleRates=48000
)
clang -arch arm64 -mmacosx-version-min=26.0 -Os -Wno-format-extra-args -bundle \
  "${defines[@]}" \
  -framework CoreAudio -framework CoreFoundation -framework Accelerate \
  -o "$OUT/Contents/MacOS/DabberMic" Driver/BlackHole/BlackHole/BlackHole.c
codesign --force --sign "Dabber Dev" "$OUT"
codesign --verify --strict "$OUT"
codesign -d -r- "$OUT" 2>&1 | grep designated

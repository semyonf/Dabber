#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
DEST=/Library/Audio/Plug-Ins/HAL/DabberMic.driver
ID=local.dabber.DabberMic
if [ "$(id -u)" -eq 0 ]; then
  echo "run without sudo: signing needs your login keychain; the script asks for the password itself"
  exit 1
fi
if [ -e "$DEST" ] && [ "$(plutil -extract CFBundleIdentifier raw "$DEST/Contents/Info.plist" 2>/dev/null)" != "$ID" ]; then
  echo "refusing: $DEST exists and is not $ID"
  exit 1
fi
scripts/build-driver.sh
echo "installing $DEST: sudo asks for your password, then all sound stops for a few seconds"
sudo rm -rf "$DEST"
sudo cp -R build/DabberMic.driver "$DEST"
sudo chown -R root:wheel "$DEST"
codesign --verify --strict "$DEST"
sudo killall coreaudiod
for _ in {1..20}; do pgrep -x coreaudiod >/dev/null && break; sleep 0.5; done
sleep 2
echo "installed"

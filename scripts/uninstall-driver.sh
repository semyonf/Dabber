#!/bin/bash
set -euo pipefail
DEST=/Library/Audio/Plug-Ins/HAL/DabberMic.driver
ID=local.dabber.DabberMic
if [ ! -e "$DEST" ]; then
  echo "not installed: $DEST"
  exit 0
fi
if [ "$(plutil -extract CFBundleIdentifier raw "$DEST/Contents/Info.plist" 2>/dev/null)" != "$ID" ]; then
  echo "refusing: $DEST is not $ID"
  exit 1
fi
echo "removing $DEST: sudo asks for your password, then all sound stops for a few seconds"
sudo rm -rf "$DEST"
sudo killall coreaudiod
for _ in {1..20}; do pgrep -x coreaudiod >/dev/null && break; sleep 0.5; done
echo "removed"

#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
DEST=/Applications/Dabber.app
ID=local.dabber.Dabber
if [ -e "$DEST" ] && [ "$(plutil -extract CFBundleIdentifier raw "$DEST/Contents/Info.plist" 2>/dev/null)" != "$ID" ]; then
  echo "refusing: $DEST exists and is not $ID"
  exit 1
fi
scripts/build-app.sh
if pgrep -f "$DEST/Contents/MacOS/Dabber" >/dev/null; then
  osascript -e "tell application id \"$ID\" to quit"
  for _ in {1..40}; do pgrep -f "$DEST/Contents/MacOS/Dabber" >/dev/null || break; sleep 0.5; done
fi
rm -rf "$DEST"
ditto build/Dabber.app "$DEST"
codesign --verify --strict "$DEST"
echo "installed $DEST"

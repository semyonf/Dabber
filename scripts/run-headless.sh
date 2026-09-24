#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p "$(dirname "$1")"
LOG="$(cd "$(dirname "$1")" && pwd)/$(basename "$1")"; shift
rm -f "$LOG"
open -W -n "${DABBER_APP:-build/Dabber.app}" --args --log "$LOG" "$@"
cat "$LOG"
tail -1 "$LOG" | grep -q ' EXIT 0$'

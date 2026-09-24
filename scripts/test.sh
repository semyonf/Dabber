#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
exec swift test -Xswiftc -plugin-path -Xswiftc "$(xcode-select -p)/usr/lib/swift/host/plugins/testing" "$@"

#!/bin/bash
# Creates DabberSpike.xcodeproj for your Apple developer team. Needs XcodeGen (brew install xcodegen).
# Usage: ./make-project.sh TEAM_ID [bundle.id.prefix]
# TEAM_ID: developer.apple.com > Account > Membership details > Team ID (10 characters).
set -euo pipefail
cd "$(dirname "$0")"
team="${1:?usage: ./make-project.sh TEAM_ID [bundle.id.prefix]}"
prefix="${2:-pro.vlads.dabber}"
cat > Local.xcconfig <<CONFIG
DEVELOPMENT_TEAM = $team
DABBER_BUNDLE_PREFIX = $prefix
DABBER_APP_GROUP = group.$prefix.spike
CONFIG
command -v xcodegen >/dev/null || { echo "XcodeGen is missing: brew install xcodegen" >&2; exit 1; }
xcodegen generate
open DabberSpike.xcodeproj

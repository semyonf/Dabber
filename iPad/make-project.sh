#!/bin/bash
# Creates DabberPad.xcodeproj for your Apple developer team. Needs XcodeGen (brew install xcodegen).
# Usage: iPad/make-project.sh TEAM_ID [bundle.id]
# TEAM_ID: developer.apple.com > Account > Membership details > Team ID (10 characters).
set -euo pipefail
cd "$(dirname "$0")"
team="${1:?usage: iPad/make-project.sh TEAM_ID [bundle.id]}"
bundle="${2:-pro.vlads.dabber.ipad}"
cat > Local.xcconfig <<CONFIG
DEVELOPMENT_TEAM = $team
DABBER_BUNDLE_PREFIX = $bundle
DABBER_APP_GROUP = group.$bundle
CONFIG
command -v xcodegen >/dev/null || { echo "XcodeGen is missing: brew install xcodegen" >&2; exit 1; }
xcodegen generate
open DabberPad.xcodeproj

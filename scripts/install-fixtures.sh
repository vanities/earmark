#!/usr/bin/env bash
# Copies the generated fixtures into the simulator app's Documents folder, which
# Earmark exposes as "On My iPhone › Earmark" and scans automatically.
#
#   scripts/install-fixtures.sh [SIMULATOR_UDID|booted]
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
FIXTURES="$ROOT/fixtures"
BUNDLE_ID="com.vanities.earmark"
UDID="${1:-booted}"

[ -d "$FIXTURES" ] || "$ROOT/scripts/make-fixtures.sh" "$FIXTURES"
CONTAINER="$(xcrun simctl get_app_container "$UDID" "$BUNDLE_ID" data)"
DEST="$CONTAINER/Documents"
mkdir -p "$DEST"
cp -R "$FIXTURES"/. "$DEST"/
echo "[$(date +%T)] installed $(find "$FIXTURES" -type f | wc -l | tr -d ' ') files into $DEST" >&2

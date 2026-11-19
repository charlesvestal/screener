#!/bin/bash
# Prints the app's log (Library/Caches/Logs/screener.log) from a paired device.
# Device: SCREENER_DEVICE_UDID (environment or Tools/local.env).
set -euo pipefail
source "$(dirname "$0")/local-env.sh"
require_env SCREENER_DEVICE_UDID "xcrun devicectl list devices"
OUT=$(mktemp -d)
xcrun devicectl device copy from --device "$SCREENER_DEVICE_UDID" --domain-type appDataContainer \
  --domain-identifier "$SCREENER_BUNDLE_ID" --source Library/Caches/Logs/screener.log \
  --destination "$OUT/screener.log" >/dev/null
cat "$OUT/screener.log"

#!/bin/bash
# Live check on the paired iPad (DEBUG build), the device twin of sim-connect.sh.
#
#   Tools/ipad-connect.sh <host> [seconds]
#     host     Screen Sharing host (IPv4 address or name; required)
#     seconds  -autoDisconnectAfter (default 30)
#
# Device: SCREENER_DEVICE_UDID (environment or Tools/local.env).
#
# Credentials come from ~/.screener-test.env (SCREENER_TEST_ENV overrides),
# parsed line by line (never sourced), mode 600, and handed to the app only via
# DEVICECTL_CHILD_* environment variables, so they never appear in argv.
# Nothing secret is echoed: no `set -x`.
#
# WARNING: a live HP session turns on display privacy on the target Mac until
# the app disconnects. When the user is home, ask before running this.
set -euo pipefail
set +x

source "$(dirname "$0")/local-env.sh"
require_env SCREENER_DEVICE_UDID "xcrun devicectl list devices"
DEVICE=$SCREENER_DEVICE_UDID
BUNDLE=$SCREENER_BUNDLE_ID
[[ $# -ge 1 && -n $1 ]] || { echo "usage: $0 <host> [seconds]" >&2; exit 2; }
HOST=$1
AFTER=${2:-30}
ENV_FILE=${SCREENER_TEST_ENV:-$HOME/.screener-test.env}

[[ $AFTER =~ ^[0-9]+$ ]] || { echo "seconds must be a whole number" >&2; exit 2; }
[[ -f $ENV_FILE ]] || { echo "Refusing: $ENV_FILE not found (Tools/make-test-env.sh)." >&2; exit 2; }
[[ $(stat -f '%Lp' "$ENV_FILE") == 600 ]] || { echo "Refusing: $ENV_FILE must be mode 600." >&2; exit 2; }
[[ $(stat -f '%u' "$ENV_FILE") == $(id -u) ]] || { echo "Refusing: $ENV_FILE is not owned by you." >&2; exit 2; }

U= P=
while IFS= read -r line || [[ -n $line ]]; do
  [[ $line == *=* ]] || continue
  key=${line%%=*}; value=${line#*=}; value=${value%$'\r'}
  case $key in
    SCREENER_USER) U=$value ;;
    SCREENER_PASS) P=$value ;;
  esac
done < "$ENV_FILE"
[[ -n $U && -n $P ]] || { echo "Refusing: $ENV_FILE must define SCREENER_USER and SCREENER_PASS." >&2; exit 2; }

cd "$(dirname "$0")/.."
xcodegen generate >/dev/null
xcodebuild -project Screener.xcodeproj -scheme Screener -configuration Debug \
  -destination "id=$DEVICE" -derivedDataPath build -allowProvisioningUpdates build -quiet
xcrun devicectl device install app --device "$DEVICE" build/Build/Products/Debug-iphoneos/Screener.app >/dev/null

echo "Launching on iPad: -autoConnect $HOST -autoDisconnectAfter $AFTER"
DEVICECTL_CHILD_SCREENER_USER=$U DEVICECTL_CHILD_SCREENER_PASS=$P \
  xcrun devicectl device process launch --terminate-existing --device "$DEVICE" "$BUNDLE" \
  -autoConnect "$HOST" -autoDisconnectAfter "$AFTER" >/dev/null
unset U P

sleep $((AFTER + 5))
"$(dirname "$0")/fetch-ipad-log.sh"

#!/bin/bash
# Unattended live check in the iPad simulator (DEBUG build).
#
#   Tools/sim-connect.sh [host] [seconds] [startup-order]
#     host           Screen Sharing host (default 127.0.0.1 = this Mac)
#     seconds        -autoDisconnectAfter (default 20)
#     startup-order  reference (default) | native — ControlSession.StartupOrder
#
# SCREENER_LOCAL_ADDR=<ipv4> (env) pins the app's TCP + UDP source address
# (-localAddress). HP media goes to the TCP peer address on the server's own
# port numbers, so testing against THIS Mac needs two local IPs: connect to
# one from the other (e.g. host=192.0.2.54 SCREENER_LOCAL_ADDR=192.0.2.33).
#
# Credentials come from ~/.screener-test.env (override the path with
# SCREENER_TEST_ENV), which the user creates (Tools/make-test-env.sh):
#   SCREENER_USER=<value>
#   SCREENER_PASS=<value>
# Values are raw (not shell-quoted). The file is parsed line by line — never
# sourced — and must be mode 600. Nothing secret is echoed: no `set -x`.
#
# WARNING: a live HP session turns on display privacy on the target Mac until
# the app disconnects (after `seconds`).
set -euo pipefail
set +x

UDID=00000000-0000-0000-0000-000000000000
BUNDLE=com.vestal.screener
HOST=${1:-127.0.0.1}
AFTER=${2:-20}
ORDER=${3:-}
ENV_FILE=${SCREENER_TEST_ENV:-$HOME/.screener-test.env}

[[ $AFTER =~ ^[0-9]+$ ]] || { echo "seconds must be a whole number" >&2; exit 2; }
if [[ -n $ORDER && $ORDER != reference && $ORDER != native ]]; then
  echo "startup-order must be 'reference' or 'native'" >&2; exit 2
fi

# --- credentials (checked before any build work) ---
if [[ ! -f $ENV_FILE ]]; then
  echo "Refusing: $ENV_FILE not found. Create it with Tools/make-test-env.sh." >&2
  exit 2
fi
mode=$(stat -f '%Lp' "$ENV_FILE")
if [[ $mode != 600 ]]; then
  echo "Refusing: $ENV_FILE has mode $mode; it must be 600 (chmod 600 \"$ENV_FILE\")." >&2
  exit 2
fi
if [[ $(stat -f '%u' "$ENV_FILE") != $(id -u) ]]; then
  echo "Refusing: $ENV_FILE is not owned by you." >&2
  exit 2
fi
SCREENER_USER_VALUE=
SCREENER_PASS_VALUE=
while IFS= read -r line || [[ -n $line ]]; do
  [[ $line == *=* ]] || continue
  key=${line%%=*}
  value=${line#*=}
  value=${value%$'\r'}
  case $key in
    SCREENER_USER) SCREENER_USER_VALUE=$value ;;
    SCREENER_PASS) SCREENER_PASS_VALUE=$value ;;
  esac
done < "$ENV_FILE"
if [[ -z $SCREENER_USER_VALUE || -z $SCREENER_PASS_VALUE ]]; then
  echo "Refusing: $ENV_FILE must define SCREENER_USER and SCREENER_PASS." >&2
  exit 2
fi

cd "$(dirname "$0")/.."

# --- simulator + build + install ---
xcrun simctl bootstatus "$UDID" -b >/dev/null
xcodegen generate >/dev/null
xcodebuild -project Screener.xcodeproj -scheme Screener -configuration Debug \
  -destination "platform=iOS Simulator,id=$UDID" -derivedDataPath build-sim build -quiet
APP=build-sim/Build/Products/Debug-iphonesimulator/Screener.app
xcrun simctl install "$UDID" "$APP"

# --- launch (credentials go only into the child's environment) ---
args=(-autoConnect "$HOST" -autoDisconnectAfter "$AFTER")
[[ -n $ORDER ]] && args+=(-startupOrder "$ORDER")
[[ -n ${SCREENER_LOCAL_ADDR:-} ]] && args+=(-localAddress "$SCREENER_LOCAL_ADDR")
echo "Launching $BUNDLE: ${args[*]}"
SIMCTL_CHILD_SCREENER_USER=$SCREENER_USER_VALUE SIMCTL_CHILD_SCREENER_PASS=$SCREENER_PASS_VALUE \
  xcrun simctl launch --terminate-running-process "$UDID" "$BUNDLE" "${args[@]}" >/dev/null
unset SCREENER_USER_VALUE SCREENER_PASS_VALUE

sleep $((AFTER + 5))

DATA=$(xcrun simctl get_app_container "$UDID" "$BUNDLE" data)
echo "----- $DATA/Documents/screener.log -----"
cat "$DATA/Documents/screener.log"

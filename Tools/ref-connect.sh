#!/bin/bash
# Known-good comparison: run the Python reference client (iShareScreen
# submodule) headless against a Screen Sharing host with the same test
# credentials as Tools/sim-connect.sh.
#
#   Tools/ref-connect.sh [host] [seconds] [pcap-path]
#     host       default 127.0.0.1 (this Mac)
#     seconds    --auto-quit-secs smoke duration (default 15)
#     pcap-path  optional --record path (still-encrypted wire bytes)
#
# Credentials come from ~/.screener-test.env (SCREENER_USER / SCREENER_PASS,
# override with SCREENER_TEST_ENV). The file is parsed line by line, never
# sourced; the password reaches the reference only through stdin
# (--password-stdin, via the printf builtin), never argv. No `set -x`.
#
# WARNING: like sim-connect.sh, a live HP session curtains the target Mac
# for the run duration.
set -euo pipefail
set +x

HOST=${1:-127.0.0.1}
SECS=${2:-15}
PCAP=${3:-}
ENV_FILE=${SCREENER_TEST_ENV:-$HOME/.screener-test.env}
[[ $SECS =~ ^[0-9]+$ ]] || { echo "seconds must be a whole number" >&2; exit 2; }

if [[ ! -f $ENV_FILE ]]; then
  echo "Refusing: $ENV_FILE not found. Create it with Tools/make-test-env.sh." >&2
  exit 2
fi
if [[ $(stat -f '%Lp' "$ENV_FILE") != 600 || $(stat -f '%u' "$ENV_FILE") != $(id -u) ]]; then
  echo "Refusing: $ENV_FILE must be mode 600 and owned by you." >&2
  exit 2
fi
U=
P=
while IFS= read -r line || [[ -n $line ]]; do
  [[ $line == *=* ]] || continue
  key=${line%%=*}
  value=${line#*=}
  value=${value%$'\r'}
  case $key in
    SCREENER_USER) U=$value ;;
    SCREENER_PASS) P=$value ;;
  esac
done < "$ENV_FILE"
if [[ -z $U || -z $P ]]; then
  echo "Refusing: $ENV_FILE must define SCREENER_USER and SCREENER_PASS." >&2
  exit 2
fi

cd "$(dirname "$0")/../Reference/iShareScreen"
args=(--host "$HOST" -u "$U" --password-stdin --headless -v --auto-quit-secs "$SECS")
[[ -n $PCAP ]] && args+=(--record "$PCAP")
# The username is argv (as for the reference CLI generally); the password is not.
printf '%s\n' "$P" | uv run --python 3.12 python -c \
  'import logging, sys; from isharescreen.cli import main; sys.exit(main())' "${args[@]}"

#!/bin/bash
# Creates ~/.screener-test.env for Tools/sim-connect.sh. Run it yourself (e.g.
# over VNC); it prompts for the Mac account to test against and prints nothing
# secret. Format: raw `KEY=value` lines (not shell-quoted), mode 600.
set -euo pipefail
set +x
umask 077

ENV_FILE=${SCREENER_TEST_ENV:-$HOME/.screener-test.env}

read -r -p "macOS username: " u
read -r -s -p "macOS password: " p
echo
if [[ -z $u || -z $p ]]; then
  echo "Username and password must not be empty; nothing written." >&2
  exit 1
fi

tmp=$(mktemp "${ENV_FILE}.XXXXXX")
trap 'rm -f "$tmp"' EXIT
printf 'SCREENER_USER=%s\nSCREENER_PASS=%s\n' "$u" "$p" > "$tmp"
unset u p
chmod 600 "$tmp"
mv -f "$tmp" "$ENV_FILE"
trap - EXIT
echo "Wrote $ENV_FILE (mode 600)."

#!/bin/zsh
set -euo pipefail
DEVICE=00000000-0000000000000000
OUT=$(mktemp -d)
xcrun devicectl device copy from --device $DEVICE --domain-type appDataContainer \
  --domain-identifier com.vestal.screener --source Documents/screener.log --destination "$OUT/screener.log" >/dev/null
cat "$OUT/screener.log"

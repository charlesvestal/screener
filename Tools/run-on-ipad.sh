#!/bin/zsh
set -euo pipefail
cd "$(dirname "$0")/.."
DEVICE=00000000-0000000000000000
xcodegen generate >/dev/null
xcodebuild -project Screener.xcodeproj -scheme Screener -configuration Debug \
  -destination "id=$DEVICE" -derivedDataPath build -allowProvisioningUpdates build | tail -3
APP=build/Build/Products/Debug-iphoneos/Screener.app
xcrun devicectl device install app --device $DEVICE "$APP"
xcrun devicectl device process launch --terminate-existing --device $DEVICE com.vestal.screener "$@"

#!/bin/bash
# Builds (Debug), installs and launches the app on a paired device; extra
# arguments go to the app (see Screener/App/DebugLaunch.swift).
# Device: SCREENER_DEVICE_UDID (environment or Tools/local.env). Signing comes
# from Local.xcconfig (see Local.xcconfig.example).
set -euo pipefail
source "$(dirname "$0")/local-env.sh"
require_env SCREENER_DEVICE_UDID "xcrun devicectl list devices"
cd "$(dirname "$0")/.."
DEVICE=$SCREENER_DEVICE_UDID
xcodegen generate >/dev/null
xcodebuild -project Screener.xcodeproj -scheme Screener -configuration Debug \
  -destination "id=$DEVICE" -derivedDataPath build -allowProvisioningUpdates build | tail -3
APP=build/Build/Products/Debug-iphoneos/Screener.app
xcrun devicectl device install app --device "$DEVICE" "$APP"
xcrun devicectl device process launch --terminate-existing --device "$DEVICE" "$SCREENER_BUNDLE_ID" "$@"

#!/usr/bin/env bash
#
# Regenerates the Xcode project, builds Nova, and installs + launches it on
# an iOS Simulator — the command-line equivalent of open Nova.xcodeproj +
# hit run in Xcode. Prefer Xcode itself for day-to-day debugging (breakpoints,
# console); this script is for a quick headless build/verify loop, or for
# scripting a WebSocket test client against a freshly launched app.
#
# Requires: xcodegen (`brew install xcodegen`), a full Xcode install, and the
# native XCFrameworks already built under NativeCores/*/build-apple/ — see
# ios/scripts/build-*.sh and ios/spikes/*/README.md if those are missing.
#
# Usage:
#   ios/scripts/run-simulator.sh                    # uses the default device below
#   ios/scripts/run-simulator.sh "iPhone 17"        # pick a specific simulator by name
#   ios/scripts/run-simulator.sh "iPhone 17" --screenshot out.png
set -e
cd "$(dirname "${BASH_SOURCE[0]}")/.."

DEVICE_NAME="${1:-iPhone 17 Pro}"
BUNDLE_ID="cz.macek.nova"
SCHEME="Nova"

SCREENSHOT_PATH=""
if [ "$2" = "--screenshot" ] && [ -n "$3" ]; then
    SCREENSHOT_PATH="$3"
fi

echo "==> xcodegen generate"
xcodegen generate

echo "==> Booting simulator: $DEVICE_NAME"
DEVICE_ID=$(xcrun simctl list devices available | grep -F "$DEVICE_NAME (" | grep -v unavailable | head -1 | grep -oE '[0-9A-F-]{36}')
if [ -z "$DEVICE_ID" ]; then
    echo "error: no available simulator named '$DEVICE_NAME' — run 'xcrun simctl list devices available' to see options" >&2
    exit 1
fi
xcrun simctl bootstatus "$DEVICE_ID" -b >/dev/null 2>&1 || xcrun simctl boot "$DEVICE_ID"
open -a Simulator --args -CurrentDeviceUDID "$DEVICE_ID" >/dev/null 2>&1 || true

echo "==> xcodebuild build (this can take a while the first time)"
xcodebuild -project Nova.xcodeproj -scheme "$SCHEME" \
    -destination "platform=iOS Simulator,id=$DEVICE_ID" \
    -configuration Debug build

APP_PATH=$(find ~/Library/Developer/Xcode/DerivedData/Nova-*/Build/Products/Debug-iphonesimulator/Nova.app -maxdepth 0 2>/dev/null | tail -1)
if [ -z "$APP_PATH" ]; then
    echo "error: build succeeded but Nova.app wasn't found in DerivedData" >&2
    exit 1
fi

echo "==> Installing + launching $BUNDLE_ID on $DEVICE_NAME"
xcrun simctl install "$DEVICE_ID" "$APP_PATH"
xcrun simctl launch "$DEVICE_ID" "$BUNDLE_ID"

if [ -n "$SCREENSHOT_PATH" ]; then
    sleep 3
    xcrun simctl io "$DEVICE_ID" screenshot "$SCREENSHOT_PATH"
    echo "==> Screenshot saved to $SCREENSHOT_PATH"
fi

echo "==> Done. WebSocket server listening at ws://localhost:8765 while the app is running."
echo "    App container: $(xcrun simctl get_app_container "$DEVICE_ID" "$BUNDLE_ID" data 2>/dev/null)"

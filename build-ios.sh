#!/bin/sh
# Build the iOS / iPadOS app into ./build/ios (signed for development devices).
# Usage: ./build-ios.sh [team id]      Install: xcrun devicectl device install app --device <udid> build/ios/Nakami.app
set -e
cd "$(dirname "$0")"
TEAM="${1:-$NAKAMI_TEAM}"
[ -n "$TEAM" ] || { echo "usage: ./build-ios.sh <team id>   (or set NAKAMI_TEAM)"; exit 2; }
xcodegen generate --quiet
xcodebuild -project Nakami.xcodeproj -scheme Nakami -configuration Release -destination 'generic/platform=iOS' \
  -derivedDataPath build/dd-ios -allowProvisioningUpdates DEVELOPMENT_TEAM="$TEAM" -quiet build
rm -rf build/ios
mkdir -p build/ios
cp -R build/dd-ios/Build/Products/Release-iphoneos/Nakami.app build/ios/Nakami.app
rm -rf build/dd-ios
echo "built build/ios/Nakami.app"

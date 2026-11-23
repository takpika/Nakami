#!/bin/sh
# Builds the Mac App Store variant: every part sandboxed, no command-line tool, no launcher helper.
#
#   scripts/build-mas.sh test      a development-signed build in build/mas/Nakami.app, for trying the sandbox locally
#   (App Store uploads are done by scripts/store.sh mac upload)
#
#   NAKAMI_TEAM                      Apple Developer team ID
set -e
cd "$(dirname "$0")/.."
MODE="${1:-test}"
[ -n "$NAKAMI_TEAM" ] || { echo "set NAKAMI_TEAM"; exit 2; }
xcodegen generate --quiet
# The app target embeds the three extensions; one entitlements file (sandbox + read-only access to
# files the user chose) fits all four.
COMMON="-project Nakami.xcodeproj -scheme Nakami -configuration Release -destination generic/platform=macOS -allowProvisioningUpdates \
  CODE_SIGNING_ALLOWED=YES CODE_SIGN_STYLE=Automatic DEVELOPMENT_TEAM=$NAKAMI_TEAM CODE_SIGN_ENTITLEMENTS=App/Sandbox.entitlements ENABLE_HARDENED_RUNTIME=YES"
if [ "$MODE" = "test" ]; then
  xcodebuild $COMMON -derivedDataPath build/dd-mas SWIFT_ACTIVE_COMPILATION_CONDITIONS="MAS NAKAMI_SELFTEST" -quiet build
  rm -rf build/mas && mkdir -p build/mas
  cp -R build/dd-mas/Build/Products/Release/Nakami.app build/mas/Nakami.app
  rm -rf build/dd-mas
  codesign -d --entitlements - build/mas/Nakami.app 2>/dev/null | grep -c "app-sandbox" >/dev/null && echo "built build/mas/Nakami.app (sandboxed)"
  exit 0
fi
echo "to upload, use: scripts/store.sh mac upload"; exit 2

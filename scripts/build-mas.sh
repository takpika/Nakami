#!/bin/sh
# Builds the Mac App Store variant: every part sandboxed, no command-line tool, no launcher helper.
#
#   scripts/build-mas.sh test      a development-signed build in build/mas/Nakami.app, for trying the sandbox locally
#   scripts/build-mas.sh upload    archive and upload to App Store Connect
#
#   NAKAMI_TEAM                      Apple Developer team ID
#   upload only: ASC_KEY, ASC_KEY_ID, ASC_ISSUER   App Store Connect API key (.p8 path, key ID, issuer ID)
#                NAKAMI_BUILD        optional build number (defaults to a timestamp)
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
[ -n "$ASC_KEY" ] && [ -n "$ASC_KEY_ID" ] && [ -n "$ASC_ISSUER" ] || { echo "set ASC_KEY, ASC_KEY_ID and ASC_ISSUER"; exit 2; }
BUILD="${NAKAMI_BUILD:-$(date +%Y%m%d%H%M)}"
AUTH="-authenticationKeyPath $ASC_KEY -authenticationKeyID $ASC_KEY_ID -authenticationKeyIssuerID $ASC_ISSUER"
rm -rf build/mas-archive
xcodebuild $COMMON $AUTH -archivePath build/mas-archive/Nakami.xcarchive SWIFT_ACTIVE_COMPILATION_CONDITIONS="MAS" CURRENT_PROJECT_VERSION="$BUILD" -quiet archive
cat > build/mas-archive/export.plist <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>method</key><string>app-store-connect</string>
  <key>destination</key><string>upload</string>
  <key>teamID</key><string>$NAKAMI_TEAM</string>
  <key>signingStyle</key><string>automatic</string>
</dict></plist>
PLIST
xcodebuild -exportArchive -archivePath build/mas-archive/Nakami.xcarchive -exportOptionsPlist build/mas-archive/export.plist \
  -exportPath build/mas-archive/out -allowProvisioningUpdates $AUTH
echo "uploaded build $BUILD"

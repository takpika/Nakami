#!/bin/sh
# Archives the iOS / iPadOS app and uploads it to App Store Connect (TestFlight).
#
#   NAKAMI_TEAM                      Apple Developer team ID
#   ASC_KEY, ASC_KEY_ID, ASC_ISSUER  App Store Connect API key (.p8 path, key ID, issuer ID)
#   NAKAMI_BUILD                     optional build number (defaults to a timestamp)
set -e
cd "$(dirname "$0")/.."
[ -n "$NAKAMI_TEAM" ] && [ -n "$ASC_KEY" ] && [ -n "$ASC_KEY_ID" ] && [ -n "$ASC_ISSUER" ] || { echo "set NAKAMI_TEAM, ASC_KEY, ASC_KEY_ID and ASC_ISSUER"; exit 2; }
BUILD="${NAKAMI_BUILD:-$(date +%Y%m%d%H%M)}"
AUTH="-authenticationKeyPath $ASC_KEY -authenticationKeyID $ASC_KEY_ID -authenticationKeyIssuerID $ASC_ISSUER"
xcodegen generate --quiet
rm -rf build/ios-archive
xcodebuild -project Nakami.xcodeproj -scheme Nakami -configuration Release -destination 'generic/platform=iOS' \
  -archivePath build/ios-archive/Nakami.xcarchive -allowProvisioningUpdates $AUTH \
  DEVELOPMENT_TEAM="$NAKAMI_TEAM" CURRENT_PROJECT_VERSION="$BUILD" -quiet archive
cat > build/ios-archive/export.plist <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>method</key><string>app-store-connect</string>
  <key>destination</key><string>upload</string>
  <key>teamID</key><string>$NAKAMI_TEAM</string>
  <key>signingStyle</key><string>automatic</string>
</dict></plist>
PLIST
xcodebuild -exportArchive -archivePath build/ios-archive/Nakami.xcarchive -exportOptionsPlist build/ios-archive/export.plist \
  -exportPath build/ios-archive/out -allowProvisioningUpdates $AUTH
echo "uploaded build $BUILD"

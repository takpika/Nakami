#!/bin/sh
# Builds an App Store build of Nakami and exports or uploads it, signing with an explicit certificate
# and provisioning profiles (no Xcode account needed, so it also runs in CI).
#
#   scripts/store.sh ios|mac export     sign and write the package into build/store-<platform>/out
#   scripts/store.sh ios|mac upload     the same, then upload to App Store Connect
#
# Needs in the keychain: "Apple Distribution" (and for mac "Mac Installer Distribution") for NAKAMI_TEAM,
# and the provisioning profiles named below installed. For upload: ASC_KEY (.p8 path), ASC_KEY_ID, ASC_ISSUER
# of an App Store Connect API key that may upload builds (App Manager is enough).
set -e
cd "$(dirname "$0")/.."
PLATFORM="$1"; MODE="${2:-export}"
[ -n "$NAKAMI_TEAM" ] || { echo "set NAKAMI_TEAM"; exit 2; }
case "$PLATFORM" in
  ios) DEST='generic/platform=iOS'; P=iOS; EXTRA="" ;;
  mac) DEST='generic/platform=macOS'; P=Mac
       EXTRA="CODE_SIGNING_ALLOWED=YES CODE_SIGN_ENTITLEMENTS=App/Sandbox.entitlements ENABLE_HARDENED_RUNTIME=YES SWIFT_ACTIVE_COMPILATION_CONDITIONS=MAS" ;;
  *) echo "usage: scripts/store.sh ios|mac [export|upload]"; exit 2 ;;
esac
BUILD="${NAKAMI_BUILD:-$(date +%Y%m%d%H%M)}"
OUT="build/store-$PLATFORM"
rm -rf "$OUT"; mkdir -p "$OUT"
xcodegen generate --quiet
xcodebuild -project Nakami.xcodeproj -scheme Nakami -configuration Release -destination "$DEST" -archivePath "$OUT/Nakami.xcarchive" \
  CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="Apple Distribution" DEVELOPMENT_TEAM="$NAKAMI_TEAM" CURRENT_PROJECT_VERSION="$BUILD" \
  NAKAMI_PROFILE_APP="Nakami App $P App Store" NAKAMI_PROFILE_PREVIEW="Nakami Preview $P App Store" \
  NAKAMI_PROFILE_THUMBNAIL="Nakami Thumbnail $P App Store" NAKAMI_PROFILE_SPOTLIGHT="Nakami Spotlight $P App Store" \
  $EXTRA -quiet archive
INSTALLER=""
[ "$PLATFORM" = mac ] && INSTALLER="<key>installerSigningCertificate</key><string>3rd Party Mac Developer Installer</string>"
cat > "$OUT/export.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>method</key><string>app-store-connect</string>
  <key>destination</key><string>$MODE</string>
  <key>teamID</key><string>$NAKAMI_TEAM</string>
  <key>signingStyle</key><string>manual</string>
  <key>signingCertificate</key><string>Apple Distribution</string>
  $INSTALLER
  <key>provisioningProfiles</key><dict>
    <key>jp.takpika.Nakami</key><string>Nakami App $P App Store</string>
    <key>jp.takpika.Nakami.Preview</key><string>Nakami Preview $P App Store</string>
    <key>jp.takpika.Nakami.Thumbnail</key><string>Nakami Thumbnail $P App Store</string>
    <key>jp.takpika.Nakami.Spotlight</key><string>Nakami Spotlight $P App Store</string>
  </dict>
</dict></plist>
PLIST
AUTH=""
if [ "$MODE" = upload ]; then
  [ -n "$ASC_KEY" ] && [ -n "$ASC_KEY_ID" ] && [ -n "$ASC_ISSUER" ] || { echo "set ASC_KEY, ASC_KEY_ID and ASC_ISSUER to upload"; exit 2; }
  AUTH="-authenticationKeyPath $ASC_KEY -authenticationKeyID $ASC_KEY_ID -authenticationKeyIssuerID $ASC_ISSUER"
fi
xcodebuild -exportArchive -archivePath "$OUT/Nakami.xcarchive" -exportOptionsPlist "$OUT/export.plist" -exportPath "$OUT/out" $AUTH
echo "$MODE finished: build $BUILD ($PLATFORM)"

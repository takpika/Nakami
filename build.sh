#!/bin/sh
# Build Nakami.app into ./build and sign it. Usage: ./build.sh [signing identity]
set -e
cd "$(dirname "$0")"
# With no identity given, the first one in the keychain is used; "-" signs ad hoc (runs on this Mac only).
# (Developer ID if there is one, else a development identity — never an App Store distribution one.)
DEFAULT=$(security find-identity -v -p codesigning | awk '/Developer ID Application/{print $2; exit}')
[ -n "$DEFAULT" ] || DEFAULT=$(security find-identity -v -p codesigning | awk '/Apple Development/{print $2; exit}')
IDENTITY="${1:-${NAKAMI_IDENTITY:-$DEFAULT}}"
[ -n "$IDENTITY" ] || IDENTITY="-"
# Releases need a secure timestamp; ad-hoc signatures cannot have one.
TS="--timestamp"; [ "$IDENTITY" = "-" ] && TS="--timestamp=none"

xcodegen generate --quiet
# The app (with both Quick Look extensions), then the two macOS-only helpers.
for scheme in Nakami NakamiLauncher nakami-cli; do
  xcodebuild -project Nakami.xcodeproj -scheme "$scheme" -configuration Release -destination 'generic/platform=macOS' \
    -derivedDataPath build/dd -quiet build
done

P=build/dd/Build/Products/Release
APP=build/Nakami.app
rm -rf "$APP"
cp -R "$P/Nakami.app" "$APP"
mkdir -p "$APP/Contents/Helpers" "$APP/Contents/PlugIns/NakamiPreview.appex/Contents/XPCServices"
cp "$P/nakami-cli" "$APP/Contents/Helpers/nakami"
cp -R "$P/NakamiLauncher.xpc" "$APP/Contents/PlugIns/NakamiPreview.appex/Contents/XPCServices/"

codesign -f $TS -s "$IDENTITY" -o runtime --entitlements Launcher/Launcher.entitlements "$APP/Contents/PlugIns/NakamiPreview.appex/Contents/XPCServices/NakamiLauncher.xpc"
for x in NakamiPreview NakamiThumbnail NakamiSpotlight; do
  codesign -f $TS -s "$IDENTITY" -o runtime --entitlements Preview/Extension.entitlements "$APP/Contents/PlugIns/$x.appex"
done
codesign -f $TS -s "$IDENTITY" -o runtime "$APP/Contents/Helpers/nakami"
codesign -f $TS -s "$IDENTITY" -o runtime "$APP"
codesign --verify --deep --strict "$APP"

# Keep only the finished app.
rm -rf build/dd
echo "built $APP"

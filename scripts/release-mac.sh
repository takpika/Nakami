#!/bin/sh
# Builds, signs with a Developer ID, notarizes and packages the macOS app.
#
#   NAKAMI_IDENTITY   "Developer ID Application: Name (TEAMID)" — must be in the keychain
#   notarization, either  NOTARY_PROFILE  (a profile saved with `xcrun notarytool store-credentials`)
#                 or      NOTARY_KEY (path to an App Store Connect API key .p8), NOTARY_KEY_ID, NOTARY_ISSUER
#
# Output: build/Nakami-<version>.zip and its SHA-256.
set -e
cd "$(dirname "$0")/.."
[ -n "$NAKAMI_IDENTITY" ] || { echo "set NAKAMI_IDENTITY to a Developer ID Application identity"; exit 2; }
case "$NAKAMI_IDENTITY" in "Developer ID Application"*) ;; *) echo "warning: \"$NAKAMI_IDENTITY\" is not a Developer ID identity; notarization will refuse it" ;; esac

./build.sh "$NAKAMI_IDENTITY"
APP=build/Nakami.app
VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP/Contents/Info.plist")
ZIP="build/Nakami-$VERSION.zip"
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"

if [ -n "$NOTARY_PROFILE" ]; then
  xcrun notarytool submit "$ZIP" --keychain-profile "$NOTARY_PROFILE" --wait
elif [ -n "$NOTARY_KEY" ]; then
  xcrun notarytool submit "$ZIP" --key "$NOTARY_KEY" --key-id "$NOTARY_KEY_ID" --issuer "$NOTARY_ISSUER" --wait
else
  echo "no notarization credentials given: $ZIP is signed but NOT notarized"; exit 3
fi
# Attach the ticket to the app, then package the stapled app.
xcrun stapler staple "$APP"
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"
spctl --assess --type execute -v "$APP"
shasum -a 256 "$ZIP"
echo "release ready: $ZIP"

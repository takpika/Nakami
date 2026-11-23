#!/bin/sh
# Copy build/Nakami.app into /Applications and (re)register its Quick Look extensions.
set -e
cd "$(dirname "$0")"
A=/Applications/Nakami.app
rm -rf "$A"
cp -R build/Nakami.app "$A"
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f -R "$A"
for x in NakamiPreview NakamiThumbnail NakamiSpotlight; do pluginkit -a "$A/Contents/PlugIns/$x.appex"; done
pkill -f NakamiThumbnail || true
pkill -f NakamiPreview || true
qlmanage -r cache >/dev/null 2>&1 || true
# Registration sometimes does not stick on the first try (an extension silently goes missing and
# Quick Look stops working), so check each one and register again until it is listed.
for x in Preview Thumbnail Spotlight; do
  n=0
  until pluginkit -m -A -i "jp.takpika.Nakami.$x" | grep -q "jp.takpika.Nakami.$x"; do
    n=$((n + 1))
    [ "$n" -gt 5 ] && { echo "WARNING: jp.takpika.Nakami.$x is not registered"; break; }
    pluginkit -a "$A/Contents/PlugIns/Nakami$x.appex"
    sleep 2
  done
done
pluginkit -m -A -i jp.takpika.Nakami.Preview
pluginkit -m -A -i jp.takpika.Nakami.Thumbnail

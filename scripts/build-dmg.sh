#!/bin/sh
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$root"
"$root/scripts/build-native.sh"
app="$root/build/Cue.app"
version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app/Contents/Info.plist")
arch=$(uname -m)
output="$root/build/Cue-$version-$arch.dmg"
stage=$(mktemp -d "$root/build/.dmg-XXXXXX")
image=$(mktemp -d "$root/build/.image-XXXXXX")
trap 'rm -rf "$stage" "$image"' EXIT HUP INT TERM
codesign --verify --deep --strict "$app"
ditto "$app" "$stage/Cue.app"
ln -s /Applications "$stage/Applications"
cp docs/dmg-setup.txt "$stage/Read Me.txt"
extension="$app/Contents/Resources/CallAssistant_CallAssistant.bundle/Contents/Resources/Extension"
test -f "$extension/manifest.json"
ditto "$extension" "$stage/Cue Extension"
hdiutil create -volname Cue -srcfolder "$stage" -format UDZO -ov "$image/Cue.dmg"
if [ "${CUE_SIGNING_IDENTITY:--}" != "-" ]; then
    codesign --force --timestamp --sign "$CUE_SIGNING_IDENTITY" "$image/Cue.dmg"
    codesign --verify --strict "$image/Cue.dmg"
fi
hdiutil verify "$image/Cue.dmg"
mv -f "$image/Cue.dmg" "$output"
(cd "$root/build" && shasum -a 256 "$(basename "$output")") > "$output.sha256"
printf '%s\n' "$output"

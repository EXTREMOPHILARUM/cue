#!/bin/sh
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$root"
npm ci --prefix canvas --ignore-scripts
npm run build --prefix canvas
swift scripts/generate-icons.swift
iconutil -c icns assets/AppIcon.iconset -o assets/AppIcon.icns
node scripts/bundle-extension.mjs native/Sources/CallAssistant/Resources/Extension
swift build --package-path native -c release
app="$root/build/Cue.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
bin=$(swift build --package-path native -c release --show-bin-path)
cp "$bin/CallAssistant" "$app/Contents/MacOS/Cue"
cp -R "$bin/CallAssistant_CallAssistant.bundle" "$app/Contents/Resources/"
cp assets/AppIcon.icns "$app/Contents/Resources/AppIcon.icns"
cp native/Info.plist "$app/Contents/Info.plist"
cp scripts/cue.mjs "$app/Contents/Resources/cue.mjs"
cp scripts/call-assistant.mjs "$app/Contents/Resources/call-assistant.mjs"
# Old build folders may still contain the formerly bundled provider tools.
rm -rf "$app/Contents/Resources/AgentRuntime"
codesign --force --deep --sign - "$app"
printf '%s\n' "$app"

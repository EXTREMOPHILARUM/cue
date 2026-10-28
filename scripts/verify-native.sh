#!/bin/sh
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$root"
npm ci --prefix canvas --ignore-scripts
npm run build --prefix canvas
npm test --prefix canvas
node --test scripts/call-context.test.mjs scripts/popup.test.mjs scripts/extension-design.test.mjs scripts/runtime-manifests.test.mjs scripts/native-extension.test.mjs scripts/call-assistant.test.mjs scripts/popup-history.test.mjs scripts/browser-outbox.test.mjs scripts/call-media.test.mjs scripts/meet-speakers.test.mjs scripts/meet-routing.test.mjs scripts/meet-presence.test.mjs scripts/call-records.test.mjs
if [ -n "${CALL_CONTEXT_TEST_CHROME:-}" ]; then
  node --test scripts/automatic-capture.integration.test.mjs scripts/group-capture.integration.test.mjs
fi
node scripts/bundle-extension.mjs native/Sources/CallAssistant/Resources/Extension
node --test scripts/bundle-extension.test.mjs
swift test --package-path native
npm audit --prefix canvas
git diff --check

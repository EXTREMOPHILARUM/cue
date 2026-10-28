#!/bin/sh
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$root"
# These voices are written to files; this never plays audio or attaches to your normal Chrome profile.
say -v Samantha -r 165 -o /tmp/call-assistant-local.aiff 'We should agree on the next step before ending the call. The customer needs a clear timeline, a named owner, and a successful pilot. Please send the proposal tomorrow morning so the engineering team can review the requirements.'
afconvert -f WAVE -d LEI16@16000 /tmp/call-assistant-local.aiff /tmp/call-assistant-local.wav
say -v Daniel -r 165 -o /tmp/call-assistant-remote.aiff 'Our budget is twenty thousand dollars for the first quarter. We need to connect the calendar, review the security requirements, and schedule a demonstration. Can you confirm the delivery date and send a written summary after this meeting?'
afconvert -f WAVE -d LEI16@16000 /tmp/call-assistant-remote.aiff /tmp/call-assistant-remote.wav
export CALL_CONTEXT_TEST_CHROME='/Applications/Google Chrome.app/Contents/MacOS/Google Chrome'
node --test scripts/automatic-capture.integration.test.mjs scripts/call-media.test.mjs
CALL_ASSISTANT_ENCODED_TEST=1 CALL_ASSISTANT_SPEECH_OUTPUT=/tmp/call-assistant-webrtc-speech.json node --test scripts/automatic-capture.integration.test.mjs
CALL_ASSISTANT_WEBRTC_FIXTURE=/tmp/call-assistant-webrtc-speech.json CALL_ASSISTANT_BENCHMARK=1 swift test --package-path native

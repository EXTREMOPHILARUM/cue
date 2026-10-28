# Architecture

The Manifest V3 Chrome extension observes Google Meet captions, participant/device mappings, and audio. `cue-content.js` handles isolated-world caption capture; `meet-speakers.js`, `meet-routing.js`, and `call-media.js` observe media and attribution in the page world. Original Meet tracks and handlers must remain intact.

`background.js` serializes call-history mutations. Joined-call lifecycle creates an independent occurrence; reconnecting while joined preserves it, while leaving and rejoining creates another. `native-background.js` connects occurrences to browser document IDs and forwards durable snapshots and queued audio to Cue. The browser retains pending data until the desktop acknowledges persistence.

The Swift app exposes a loopback WebSocket bridge. `CallCore/SessionStore.swift` stores raw audio, evidence, captions, and transcripts in SQLite. WhisperKit performs local transcription. Ambiguous sources remain Unknown; recording a waveform is not proof of speaker identity.

Summaries and coaching use separate persistent ACP sessions for Codex and Claude. Provider output is bounded and schema/source validated. Summary jobs wait for pending audio, reject stale results, and preserve full transcript coverage across chunks. Refined turns link back to original source segments rather than replacing the originals.

A local OpenUI canvas renders coaching in a native floating panel. Native preferences control translucency, collapse, and visibility. Panel placement remains pinned to the selected display. Screen sharing can expose the panel.

Optional EventKit access reads nearby calendar events only after an explicit connection action and macOS consent. App behavior does not create or edit calendar events. Exact Meet code and occurrence timing are required for matching.

Local project research is bounded excerpt search, not a live database, billing, or web lookup. Common credential filenames are excluded, but secrets embedded in ordinary project files are not guaranteed to be detected.

The build packages the extension, native executable, canvas, and provider download manifests. Models and provider tools live outside the application bundle and are downloaded separately. Original Cue code is MIT licensed; Apache-2.0 notices remain with adapted capture/protocol code.

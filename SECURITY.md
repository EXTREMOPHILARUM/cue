# Security and privacy

Do not post credentials, recordings, private transcripts, or exploitable vulnerability details in public issues. Use GitHub's private vulnerability reporting for this repository when enabled.

Cue stores call data in local application/browser storage. The app's WebSocket bridge binds to 127.0.0.1:17373, checks the configured browser extension's exact origin, and trusts other local programs without authentication. This is not a boundary against hostile software running on your computer.

Optional AI features send transcripts and explicitly attached context to the selected provider. Project research excludes common credential filenames but cannot identify every secret embedded in an ordinary file. Review attachments before enabling AI.

Provider tools download from pinned manifests. Node archives are SHA-256 checked, npm packages use lockfile integrity verification, and installation scripts are disabled. Provider sign-in and upstream service security remain separate concerns.

Call capture, speaker labels, and generated output require human review. Coaching may appear in screen sharing. Local builds use ad-hoc signing by default. Distributed releases identify their Developer ID signing and Apple notarization status in the release notes.

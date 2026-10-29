# Setup and development

Build with `scripts/build-native.sh` for an app bundle, or `scripts/build-dmg.sh` for an installable disk image. Both package the extension and canvas. Builds are architecture-specific and ad-hoc signed by default. To sign a release with a Developer ID Application identity installed in your Keychain:

```sh
CUE_SIGNING_IDENTITY="Developer ID Application: Your Name (TEAMID)" scripts/build-dmg.sh
```

This signs the app with hardened runtime and a secure timestamp, and also signs the DMG. Apple notarization and stapling are separate steps; consult the release notes for the distributed image’s status. Never commit signing keys, passwords, or notarization credentials.

The app uses `~/Library/Application Support/Cue/` for its local database, model cache, downloaded AI tools, and prepared extension. Do not load an unpacked extension directly from a mounted disk image. In Settings → Connect Chrome, choose **Open Cue Chrome**. Cue opens a dedicated Chrome profile, automatically loads its extension, and links the exact returned ID. Sign in to Google there and use that window for calls. No Developer mode, folder picker, or ID copying is needed. Reopen this profile through Cue each time: Chrome does not restore automatically loaded extensions after a browser restart. Your sign-in and extension storage are retained.

Cue keeps this profile under `~/Library/Application Support/Cue/CueChrome` and the extension under the adjacent `AutomaticExtension` directory. If that profile is already running with the same loaded build, the button opens a Meet window without reinstalling. For an update or a session reopened outside Cue, quit Cue Chrome (⌘Q) and retry. Regular Chrome windows can stay open. The installer refuses to reload a running profile. **Manual setup in your existing Chrome profile** remains available for users who prefer their current browser profile; keep its existing ID and folder to retain browser history.

Automatic setup uses Chrome’s extension-loading API with a random loopback debugging port and `--enable-unsafe-extension-debugging`. Cue disconnects after installation, but Chrome retains the local debugging endpoint until that browser exits. Cue never attaches this installer to the normal Chrome profile. This is local loading, not Chrome Web Store publication. The installation/relaunch/storage-retention flow was tested with Chrome 156 in a disposable profile; fresh-user Google sign-in and live Meet acceptance remain unverified.

The public build uses a Cue-specific bundle identity and data directory. It does not automatically migrate data from earlier development builds. Keep backups before changing installations. Never reload the extension or restart capture during a call.

## Model and AI tools

WhisperKit downloads `VocaHQ/whisperkit-coreml` / `vocahq_voca-hinglish_820MB` on first launch. Downloads are approximately 824 MB; CoreML preparation can take several minutes. Settings provides model status and a load/download retry button. No call audio is uploaded for transcription.

Codex and Claude tools download independently on first use or through Settings. Node.js 24.16.0 archives are verified against pinned SHA-256 values. npm installs the selected provider's integrity-locked dependencies with lifecycle scripts disabled. Installations are staged and cached by architecture, Node version, and lockfile digest. Failed attempts leave complete caches intact. Settings reports phases and errors. Provider authentication is separate from downloading the tools; use your provider's supported sign-in flow.

## Checks

Run `scripts/verify-native.sh` for canvas, extension, packaging, native checks, dependency audit, and whitespace checks. Optional fixture-dependent tests skip when fixtures are absent. All public fixtures are synthetic.

To download both providers and check their ACP initialization without sending a transcript:

```sh
CUE_RUNTIME_DOWNLOAD_SMOKE=1 swift test --package-path native --filter RuntimeDownloadTests/testRealDownloadsAndUnauthenticatedInitializeWhenEnabled
```

Signed-in provider generation tests additionally require `CUE_ACP_SMOKE=1`. These may use your account and must be explicitly enabled. Browser integration tests require a disposable Chrome profile; never attach to an active meeting.

## Local CLI

With Cue running, use `node scripts/cue.mjs status`, `list`, or `read --session SESSION_ID --after CURSOR`. Calls are separate dated occurrences, even when they share a Meet link. Reads are cursor-paginated and may contain revised segments; replace older segments with the same ID rather than concatenating revisions.

The legacy browser helper is retained for development and isolated integration tests. Normal app access uses the localhost CLI, without attaching to Chrome.

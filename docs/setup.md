# Setup and development

Build with `scripts/build-native.sh` for an app bundle, or `scripts/build-dmg.sh` for an installable disk image. Both package the extension and canvas. Builds are architecture-specific and ad-hoc signed by default. To sign a release with a Developer ID Application identity installed in your Keychain:

```sh
CUE_SIGNING_IDENTITY="Developer ID Application: Your Name (TEAMID)" scripts/build-dmg.sh
```

This signs the app with hardened runtime and a secure timestamp, and also signs the DMG. Apple notarization and stapling are separate steps; consult the release notes for the distributed image’s status. Never commit signing keys, passwords, or notarization credentials.

The app uses `~/Library/Application Support/Cue/` for its database, model cache, and downloaded AI tools. New prepared extensions go in **`~/Cue Extension`**, a visible folder in your Home directory. Do not load an unpacked extension from a mounted disk image.

## First-run readiness and permissions

Cue opens Settings → **Setup** until recording permission is granted. The Readiness section shows the extension connection, speech model, and selected provider’s installed tools. The library toolbar keeps a **Finish setup** indicator while required setup or enabled AI tooling is incomplete.

Recording permission and optional AI processing are separate, explicit choices. Recording consent starts off; the app and updated extension reject new audio/captions until it is granted. Turning it off pauses capture and intake without deleting previous recordings. The extension caches the last granted recording choice for offline browser backup; when connected, it follows the app’s permission/pause state. Existing calls can still receive an end timestamp after permission is revoked. Optional AI consent allows call text and attached context to go to the selected provider; it starts off and revocation cancels running AI work. Existing users also review these choices on first launch of this version.

Chrome owns Meet’s microphone permission. Cue does not need separate macOS microphone or screen-recording access for this capture path. Optional Calendar access is requested through macOS only when you press Connect / refresh Calendar.

## Connect your existing Chrome profile

1. Outside a call, open Settings → Connect Chrome → **Prepare extension and open Chrome**. Cue reveals the prepared folder in Finder and opens Chrome’s extensions page. This prepares files; it does not install the extension.
2. In the Chrome profile you use for Meet, enable **Developer mode** and click **Load unpacked**. For a new install, press **⌘⇧H** in the folder picker, select **Cue Extension**, and click **Open**. Alternatively, use **Copy folder path** in Cue, press **⌘⇧G** in the picker, paste, and press Return, then Open.
3. Copy the extension’s 32-letter ID into Cue. The sheet confirms the bridge connection automatically; retries can take up to 30 seconds.

Existing linked installations retain their previously prepared Application Support path. Cue’s **Show extension folder** and **Copy folder path** buttons make that location accessible without navigating hidden folders. Keep an existing extension’s ID and folder; reload its existing card outside a call after updating. Moving an unpacked extension or loading a second copy can change its ID and separate its browser history. Cue refuses to overwrite a folder whose manifest does not identify it as a Cue extension.

The separate-profile automatic installer has been removed. Cue does not create or launch a new Chrome profile. Any profile created by version 0.1.4 and its browser data are left on disk; this update does not delete or migrate them. To use your regular profile, load the prepared extension there using the steps above. Automatic installation into a regular Chrome profile without Developer mode requires Chrome Web Store distribution, which is not implemented.

The public build uses a Cue-specific bundle identity and data directory. It does not automatically migrate data from earlier development builds. Keep backups before changing installations. Never reload the extension or restart capture during a call.

## Model and AI tools

Setup checks for the existing `VocaHQ/whisperkit-coreml` / `vocahq_voca-hinglish_820MB` model. Complete cached files are reused; missing model files are downloaded only when you choose Download speech model. Downloads are approximately 824 MB; CoreML preparation can take several minutes. Settings provides model status and a load/download retry button. No call audio is uploaded for transcription.

Setup checks Cue’s versioned Codex and Claude ACP runtime caches locally, without downloading or generating a provider request. Complete cached installations are marked already installed; only the selected provider’s missing tools are offered for download. An existing standalone Codex/Claude CLI is not a substitute for Cue’s pinned ACP adapter, although its account sign-in can be reused. Tools download on an explicit Setup action or first permitted AI use. Node.js 24.16.0 archives are verified against pinned SHA-256 values. npm installs the selected provider's integrity-locked dependencies with lifecycle scripts disabled. Installations are staged and cached by architecture, Node version, and lockfile digest. Failed attempts leave complete caches intact. Settings reports phases and errors. Provider authentication is separate from downloading the tools; use your provider's supported sign-in flow.

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

## Transport recovery checks

Version 0.1.5 accepts Chrome Opus decoder timestamps rounded by one microsecond, avoiding stale packet identities and false decoder-stall warnings. The real Chromium WebRTC regression failed with repeated stall warnings before the fix and passed after it; genuine decoder-stall and backpressure fallback checks remain in place.

ACP input uses a one-chunk handoff with pipe backpressure instead of dropping chunks while the UI is busy. The 2 MB message bound applies to each framed or unfinished message, rather than a batch of valid messages. A synthetic provider burst exceeding 4 MB is covered alongside oversized-output rejection, cancellation, and stalled-pipe tests. Provider error codes now retain a bounded message for diagnosis. These checks do not establish live coaching accuracy or provider quota availability.

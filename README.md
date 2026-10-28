# Cue

Cue is a local-first macOS call assistant for Google Meet. A Chrome extension captures captions and call audio; the desktop app stores recordings and transcripts locally, groups recurring calls, and displays a private coaching panel.

## Features

- Local Roman Hinglish and English transcription with WhisperKit.
- Separate microphone and remote audio, with speaker-attribution evidence. Ambiguous speech stays Unknown.
- Call history, summaries, source-linked transcript refinement, and recurring project context.
- Optional Codex or Claude coaching and summaries using your configured provider account.
- Configurable translucent coaching panel.
- Bundled Chrome extension with an offline capture queue.
- On-demand downloads for the speech model and selected AI provider tools.
- Optional read-only Calendar matching after explicit macOS permission.

## Requirements

macOS 14 or later, Google Chrome, and an internet connection for initial model/tool downloads. AI features require a separately configured provider account. Current packaged builds target Apple Silicon; Intel is not yet verified.

## Build and install

Development requires Xcode Command Line Tools (Swift 5.10 or newer) and Node.js 22 or newer with npm.

```sh
git clone https://github.com/EXTREMOPHILARUM/cue.git
cd cue
scripts/build-dmg.sh
```

The disk image is created under `build/`. Drag Cue into Applications and launch it. The speech model downloads on first launch (approximately 824 MB). Settings shows its status and provides a retry button.

In Settings, open **Connect Chrome**. Prepare the bundled extension, enable Developer mode in `chrome://extensions`, load the persistent folder Cue reveals, and enter the extension ID in Cue. Install or reload only outside a call. Chrome Web Store installation is not provided.

Provider tools download when first used, or through **Download / check AI tools** in Settings. Only the selected provider is installed. Downloads use pinned manifests and integrity checks; completed tools are cached for reuse.

The build scripts use local ad-hoc signing. These builds are not notarized public macOS releases.

## Privacy and limitations

Audio, transcripts, and browser queues stay on your machine. Enabling AI sends call text and explicitly attached context to the selected provider. Model and tool downloads contact their upstream hosts. Calendar titles and times are not included in AI prompts.

The localhost bridge trusts local programs; it checks browser extension origins but does not authenticate other local processes. Keep this in mind before using Cue for sensitive conversations. Follow applicable recording and participant-consent requirements.

Captions, transcription, summaries, refinement, and speaker attribution can be wrong. Meet changes can break capture. Coaching can be visible during full-screen sharing. Synthetic tests do not establish real-call accuracy or reliability across every device.

See [setup](docs/setup.md), [architecture](docs/architecture.md), and [security](SECURITY.md).

## Development

```sh
scripts/verify-native.sh
```

This builds and tests the canvas, extension, packaging, and native app. Private audio fixtures and signed-in provider tests are opt-in; defaults do not require real call data. Use disposable browser profiles for browser integration tests.

The native CLI supports local call access:

```sh
node scripts/cue.mjs status
node scripts/cue.mjs list
node scripts/cue.mjs read --session SESSION_ID --after 0
```

Keep private databases, recordings, provider credentials, and transcripts outside this repository. See [contributing](CONTRIBUTING.md).

## License

Cue's original code is MIT licensed. Adapted capture/protocol code retains its Apache-2.0 licensing and attribution; see [NOTICE](NOTICE) and `docs/licenses/`. Downloaded dependencies and model weights retain their respective upstream licenses.

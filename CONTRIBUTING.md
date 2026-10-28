# Contributing

Use small, focused changes and run `scripts/verify-native.sh` before submitting a pull request. Describe the behavior changed, checks run, and any unverified real-call behavior.

Use synthetic fixtures. Never submit recordings, transcripts, call exports, credentials, account identifiers, private project excerpts, or screenshots containing personal information.

Preserve original audio and attribution evidence. Do not infer speaker identity from a title, partial roster, or apparent voice similarity. Keep capture cancellation, queue durability, and stale-callback protections intact.

Use disposable browser profiles for capture tests. Do not reload extensions or restart capture in a live call. Test model/provider downloads only when explicitly opting into network-dependent checks.

Third-party notices must stay with adapted code. New contributions are provided under the repository's MIT license unless a file carries a different existing license.

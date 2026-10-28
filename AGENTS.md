# Repository guidance

- Read the current source before changing behavior. Preserve concurrent work.
- Keep private call data, databases, audio, transcripts, credentials, and project excerpts outside Git. Use synthetic test fixtures.
- Use `gh` for GitHub operations. Use `uv run` for Python project commands.
- For changes across more than three files or multiple systems, propose numbered chunks and verification steps.
- Run `scripts/verify-native.sh` before claiming completion. `scripts/build-dmg.sh` creates an architecture-specific local disk image.
- Preserve raw audio, timestamp/source evidence, durable browser queues, and independent call occurrences. Ambiguous speakers remain Unknown.
- Preserve cancellation, stale-callback protection, output bounds, provider isolation, and permission/origin checks.
- Do not install/reload capture extensions during a live call. Browser integration tests must use a disposable profile.
- Put supporting documentation under `docs/`. Preserve upstream notices and file licenses.

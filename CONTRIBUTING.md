# Contributing to gob.lin

Use macOS 26 or newer and Xcode 26 (Swift 6.2). Build the signed development app with `scripts/build.sh`; the first run creates a dedicated local signing identity. See the README for signing and permission recovery.

Keep `GoblinCore` portable: Foundation is allowed, AppKit and macOS services belong in `GoblinApp`. Speech engines implement the shared `SpeechEngine` boundary so the app and CLI use the same processing rules. Do not copy implementation code from reference dictation apps.

Work in a feature branch or worktree. Include the problem, resulting behavior, verification commands, and screenshots for visible changes in the pull request. Build with `swift build`, run `scripts/smoke.sh`, and run the focused safety tests with `swift test` when a test target exists. Tests should protect meaningful invariants, especially correction guardrails, clipboard ownership, and persistent data. Cosmetic changes do not need new tests.

Keep recordings, transcripts, API keys, signing credentials, and model weights out of commits. Add synthetic fixtures only, unless the recording's owner explicitly authorized redistribution. Run `python3 scripts/check-repository.py` before publishing; it scans tracked files and reachable Git history without printing secret values. Download speech models at runtime into Application Support after the engine is selected, preserving upstream licence and attribution information.

When introducing a dependency, update `THIRD_PARTY_NOTICES.md` and include its required licence files. Keep user errors visible and do not log transcript text or authorization headers.

# gob.lin

An independently implemented native macOS dictation app.

## Project

The roadmap and acceptance criteria live in [gob.lin v0.1 — minimal app on Linear](https://linear.app/goblink/project/goblin-v01-minimal-app-5d9bf4e3bece).

This repository currently contains the project overview. Application code, build tooling, and tests are still to be implemented.

## Planned architecture

Native Swift, macOS 26+, distributed as a direct download.

- **GoblinCore:** portable, pure Swift pipeline, settings, history, dictionary, and rewrite client; no AppKit.
- **GoblinEngines:** speech engines behind a shared protocol; Parakeet through FluidAudio is the initial candidate, subject to the engine spike.
- **GoblinApp:** SwiftUI and AppKit menu bar application.
- **goblin CLI:** the same transcription pipeline, with replay and evaluation on real recordings.

## v0.1 scope

- On-device dictation with hold-to-talk, tap-to-toggle, and reliable insertion into the focused app.
- A live transcription pill with the goblin mascot.
- A user dictionary with recognizer biasing and measured, guarded corrections.
- Optional LLM rewriting, global tone controls, and recoverable history with raw text, final text, and audio.
- Settings for microphone, hotkeys, model status, dictionary, rewriting, tone, and history retention.

Stats, learning from corrections, context integration, per-app styles, snippets, file transcription, on-device rewriting, and additional model selection are tracked for later in Linear.

## Milestones

1. **M0 Foundations:** project skeleton, stable signing, and speech engine evaluation.
2. **M1 Dictation loop:** hotkey → capture → recognition → insertion.
3. **M2 Core features:** overlay, live text, dictionary, rewriting, tone, history, settings, and branding.
4. **M3 Dogfood-ready:** CLI evaluations, diagnostics, distribution, updates, and open-source readiness.

The starting tickets are [GOB-5: project skeleton](https://linear.app/goblink/issue/GOB-5/project-skeleton-swift-packages-menu-bar-app-stable-signing-licence) and [GOB-6: speech engine spike](https://linear.app/goblink/issue/GOB-6).

## References

- Local UX research screenshots: shortcuts, microphone controls, history, models, advanced options, post-processing, and app information.
- `reference/wispr flow/screenshots/`: dictation history, insights, dictionary, snippets, tone, and cleanup controls.

These screenshots are local research material and are excluded from version control.

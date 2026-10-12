# gob.lin

An independently implemented native macOS dictation app.

## Project

The roadmap and acceptance criteria live in [gob.lin v0.1 — minimal app on Linear](https://linear.app/goblink/project/goblin-v01-minimal-app-5d9bf4e3bece).

The foundation includes the native menu bar app, Swift packages, command-line
companion, Xcode project, stable local signing, and a macOS build workflow.

## Build and run

Requires macOS 26+ and Xcode 26.3+ (Swift 6.2). No third-party dependencies.
The signing scripts use the tools included with macOS; Homebrew is not required.

```sh
scripts/build.sh
open .build/app/gob.lin.app
```

The first build creates a dedicated `gob.lin Local Development` signing
certificate in your login keychain. macOS may ask you to approve its trust and
codesign access. Keep that certificate and private key across builds: the bundle
identifier and certificate-based designated requirement stay stable, so macOS
can preserve microphone and Accessibility grants. The app runs without a Dock
icon; its menu contains Settings, History, Paste last transcript, and Quit.

If an Accessibility grant becomes stale, quit gob.lin, run
`tccutil reset Accessibility app.goblin.dictation`, then grant it again in
System Settings → Privacy & Security → Accessibility. This resets only gob.lin's
grant. Build scripts never reset or request privacy permissions.

For an existing local or Developer ID certificate:

```sh
GOBLIN_SIGNING_IDENTITY='Your certificate name' scripts/build.sh
```

Ad-hoc signing is deliberately rejected. Local certificates are for development;
public distribution requires Developer ID signing and notarization. The app is
not sandboxed because dictation must interact with other applications through
Accessibility. Hardened runtime and the microphone entitlement are enabled.

To inspect or work in Xcode, open `Goblin.xcodeproj`; run
`scripts/setup-signing.sh` first. The committed project builds without generators.
If its structure changes, `project.yml` is the XcodeGen source of truth.

```sh
swift build                       # unsigned binaries for development and CI
swift run goblin --help
scripts/smoke.sh                   # package, CLI, and bundle metadata checks
```

## Source layout

- `Sources/GoblinCore`: portable Swift domain and pipeline code; no AppKit.
- `Sources/GoblinEngines`: shared `SpeechEngine` protocol and engine adapters.
- `Sources/GoblinApp`: SwiftUI/AppKit menu bar app and windows.
- `Sources/GoblinCLI`: `goblin` command-line companion.
- `Resources`: app metadata and hardened-runtime entitlements.

The engine protocol accepts a local audio file and returns recognized text.
No engine or live dictation is bundled until the speech benchmark selects one.

## History

History uses the system SQLite library in `~/Library/Application Support/gob.lin/`.
The database and its migration version persist across app updates. Each dictation
keeps raw and final text, tone, target app, timestamps, duration, word count,
model, and stage timings. Original, untrimmed captures are copied into `audio/`
under unique UUID filenames before their metadata is saved.

The History window supports transcript/app search, copying either text, audio
playback, stars, deletion, and optional count/age retention. Both limits start
unset, so history is kept by default; starred entries survive retention cleanup.
Re-transcription and rewrite actions create a new entry and keep the original.
Re-transcription stays visibly unavailable until a speech engine is configured.
Rewrite becomes available when the shell supplies its configured rewrite callback.

Failed saves retain the raw text and capture URL in memory and show copy/retry
actions. Copy or retry unsaved entries before quitting. The pipeline must keep
its original capture until `HistoryModel.record` returns success.

`scripts/smoke.sh` includes narrowly scoped history safety assertions for schema
migrations, retention, audio boundaries, and paged access to 1,000 synthetic
entries. It never uses your recordings or history folder.

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

## License

Apache-2.0; see [LICENSE](LICENSE) and [NOTICE](NOTICE). No third-party source,
fonts, or model weights are bundled in this foundation.

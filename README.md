# gob.lin

A native macOS dictation app with a menu bar interface, configurable shortcuts, and local transcript history.

## Project

The roadmap and acceptance criteria live in [gob.lin v0.1 — minimal app on Linear](https://linear.app/goblink/project/goblin-v01-minimal-app-5d9bf4e3bece).

The foundation includes the native menu bar app, Swift packages, command-line
companion, Xcode project, stable local signing, and a macOS build workflow.

## Build and run

Requires macOS 26+ and Xcode 26.3+ (Swift 6.2). No third-party dependencies.
The signing scripts use the tools included with macOS; Homebrew is not required.

```sh
scripts/build.sh
scripts/launch.sh
```

The first build creates a dedicated `gob.lin Local Development` signing
certificate in your login keychain. macOS may ask you to approve its trust and
codesign access. Keep that certificate and private key across builds: the bundle
identifier and certificate-based designated requirement stay stable, so macOS
can preserve microphone and Accessibility grants. The app runs without a Dock
icon; its menu contains Settings, History, Paste last transcript, and Quit.

`scripts/launch.sh` verifies the exact bundle and its certificate signature,
prints its absolute path and designated requirement, and refuses to launch
while another `GoblinApp` process is running. It does not select an app by name
or bundle identifier. Use `scripts/launch.sh --check` to inspect without launching.
Quit your current app before rebuilding/relaunching; do not grant permissions
to unsigned SwiftPM executables or ad-hoc validation bundles.

If a System Settings toggle is on but gob.lin reports a permission unavailable,
check the individual row in Permissions & onboarding and its **Running app**
path. After opening System Settings through gob.lin's **Settings**/**Allow**
buttons, return to gob.lin to refresh statuses and retry an unavailable shortcut.
If you opened System Settings independently, choose **Check again** to refresh
and retry, even when statuses are unchanged. If needed, quit and reopen the same
signed bundle: some permission changes require a process restart. A shortcut-tap
failure alone is not evidence of a stale Accessibility grant. See
[permissions and recovery](docs/permissions.md) before changing any grants.
Build and launch scripts never reset or request privacy permissions.

For an existing local or Developer ID certificate:

```sh
GOBLIN_SIGNING_IDENTITY='Your certificate name' scripts/build.sh
```

Use an exact certificate name or its full SHA-1 fingerprint from
`security find-identity -v -p codesigning`. If multiple valid certificates share
the same name, the build lists their fingerprints and asks you to choose one.

Ad-hoc signing is deliberately rejected. Local certificates are for development;
public distribution requires Developer ID signing and notarization. The app is
not sandboxed because dictation must interact with other applications through
Accessibility. Hardened runtime and the microphone entitlement are enabled.

To inspect or work in Xcode, open `Goblin.xcodeproj`; run
`scripts/setup-signing.sh` first. The committed project builds without generators.
For a deterministic signed Xcode launch outside the debugger:

```sh
xcodebuild -project Goblin.xcodeproj -scheme Goblin -configuration Release \
  -derivedDataPath .build/xcode build
scripts/launch.sh .build/xcode/Build/Products/Release/gob.lin.app
```

Inspect either Xcode configuration with `scripts/launch.sh --check <bundle>`.
Do not use `CODE_SIGNING_ALLOWED=NO` or `CODE_SIGN_IDENTITY=-` for a permission
check. If its structure changes, `project.yml` is the XcodeGen source of truth.

Debug builds include Xcode's debugger entitlement; Release builds exclude it.
Xcode Debug uses a normal executable so the local certificate works with
hardened-runtime library validation; debug-dylib-dependent SwiftUI previews
are unavailable in that configuration.

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

## CLI evaluation

```sh
swift run goblin transcribe recording.wav
swift run goblin replay ./recordings
swift run goblin replay history
swift run goblin replay ./recorded-transcripts --recorded > replay.jsonl
swift run goblin replay history --recorded --history-dir /path/to/data > history.jsonl
swift run goblin eval A.jsonl B.jsonl
swift run goblin eval A.jsonl B.jsonl --json > report.json
```

Audio transcription/replay uses the shared `RecordedAudioPipeline` and
`SpeechEngine` boundary. Until the benchmark selects and registers an adapter,
these commands return a structured `engine_not_configured` error with exit 3.
They never substitute fabricated recognition. The optional postprocessor keeps
raw text and a visible error in the output when rewriting fails.

`--recorded` reads existing transcript JSONL files from a directory, or exports
saved History entries. It labels each row `source: "recorded_transcript"` and
preserves existing text and timings; it does not perform or time recognition.
Each JSONL row requires `id`, `rawText`, and `finalText`. Optional fields are
`referenceText`, `jargon` (preferred phrases), `ordinaryWords` (individual words),
`model`, `timings`, and `postprocessingError`. Stage timings use
`DictationTimings` milliseconds; absent timings remain unavailable.

Evaluation joins A and B by ID, reports missing IDs, and rejects duplicates or
conflicting ground truth. WER is weighted by reference word count and ignores
case/punctuation. Jargon hits count annotated reference occurrences. Ordinary
word regressions are replacements/deletions of annotated raw words that were
already correct in the reference. Without ground truth/annotations those
accuracy metrics are unavailable. Percentiles use nearest-rank p50/p90/p95/p99;
processing latency excludes capture duration and sums trim, ASR, rewrite, and
insertion. JSONL input is limited to 64 MiB per file; word diff matrices are
limited to 4,000,000 cells to bound memory and computation.

The small synthetic fixture set in `Tests/EvaluationSmoke/fixtures` demonstrates
that a jargon improvement can still be a regression: B corrects “Dev review”
but incorrectly changes “like” to “Lisa” and “at” to “auth”. CI exercises these
accuracy checks and the command protocol using only synthetic data and a
temporary History directory. Real-recording throughput/accuracy remains a
benchmark acceptance item, with no measurements claimed by these fixtures.

CLI exit codes: 0 success, 1 operation/data failure, 2 usage error, 3 missing
speech engine. Errors are JSON on stderr; transcript/report output is stdout.
The command-protocol smoke checks additionally require Python 3 and use only
its standard library.

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

## License

Apache-2.0; see [LICENSE](LICENSE) and [NOTICE](NOTICE). No third-party engine source or model weights are bundled.

Workbench and VT323 are bundled under SIL OFL 1.1; their licence texts ship with the fonts in `Sources/GoblinApp/Assets/Workbench-OFL.txt` and `VT323-OFL.txt`.

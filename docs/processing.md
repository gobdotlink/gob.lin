# Shared transcript processing

`TranscriptPostprocessor` lives in portable GoblinCore. It preserves the original ASR text, applies exact dictionary aliases, and formats the selected tone without a provider when cleanup is disabled. Fuzzy correction remains disabled. If enabled provider cleanup fails, the final text is the exact original ASR text and a typed warning is returned. App History rewrite and RecordedAudioPipeline consume this same result.

The app loads credentials only for enabled cleanup. The CLI processes audio locally by default once an engine is configured; `--rewrite` explicitly opts into the configured provider and its saved key. Recorded replay exports existing text unchanged unless `--process`, `--tone`, `--dictionary`, or `--rewrite` is supplied. Recorded postprocessing marks `source` as `recorded_postprocessing` and reports only the new processing duration; it does not claim to rerun recognition or insertion. `--dictionary <JSON>` accepts the app's versioned dictionary format.

There is no speech adapter selected yet. Native hotkeys cancel immediately and surface permissions, Secure Input, or the pending-engine reason. Audio CLI commands return `engine_not_configured`; recorded replay and evaluation work independently.

One app DiagnosticsModel supplies the menu, warning pill, diagnostics page, and copied report. Only static typed errors enter logs. Saving a History entry records the same stage timings in history and diagnostics. Failed saves retain raw text in the pending queue. Quit checks pending text and recoverable clipboard contents, then stops hotkeys, permission monitoring, insertion, playback, and audio preview.

Run `scripts/smoke.sh` for isolated synthetic persistence, evaluator, shared processing fallback, CLI protocol, and diagnostic redaction checks. No live recording, provider request, or permission modification is required.

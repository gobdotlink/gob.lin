# Shared transcript processing

`TranscriptPostprocessor` lives in portable GoblinCore. It preserves the original ASR text, applies exact dictionary aliases, and formats the selected tone without a provider when cleanup is disabled. Fuzzy correction remains disabled. If enabled provider cleanup fails, the final text is the exact original ASR text and a typed warning is returned. App History rewrite and RecordedAudioPipeline consume this same result.

From key-up to text, the app overlaps what it can:

- **Connection:** pressing the talk key opens the cleanup provider's connection, with an address-only `HEAD` that carries no key or text, so the request at key-up skips the TLS handshake.
- **Pauses:** each pause the live transcriber settles while the key is still held starts AI cleanup of the text so far. If the take ends there, that cleanup is usually finished by key-up. As a result, **AI cleanup can receive the beginning of a dictation before the talk key is released**; each later pause replaces the request.
- **Key-up:** a cleanup also starts for anything said since the last pause. If the original recording has to be recognized, another starts from the live window's draft.
- **Keeping one:** a cleanup that started from text other than the final transcript is kept only when the final transcript has the same words, or the same words in different case or edge punctuation once that cleanup polished them. Otherwise the final transcript is cleaned up. Without AI cleanup nothing starts early, so draft punctuation never reaches the text.
- **Clipboard:** the clipboard is saved while the text is prepared. Pasting rereads it only if it changed.
- **Measuring:** the development log marks `captureStopped`, `transcriptReady`, `draftCleanupUsed` or `draftCleanupDiscarded`, and `pasteSent` (Command-V sent), so key-up to text can be measured stage by stage.

The app loads credentials only for enabled cleanup. The CLI processes audio locally by default once an engine is configured; `--rewrite` explicitly opts into the configured provider and its saved key. Recorded replay exports existing text unchanged unless `--process`, `--tone`, `--dictionary`, or `--rewrite` is supplied. Recorded postprocessing marks `source` as `recorded_postprocessing` and reports only the new processing duration; it does not claim to rerun recognition or insertion. `--dictionary <JSON>` accepts the app's versioned dictionary format.

There is no speech adapter selected yet. Native hotkeys cancel immediately and surface permissions, Secure Input, or the pending-engine reason. Audio CLI commands return `engine_not_configured`; recorded replay and evaluation work independently.

One app DiagnosticsModel supplies the menu, warning pill, diagnostics page, and copied report. Only static typed errors enter logs. Saving a History entry records the same stage timings in history and diagnostics. Failed saves retain raw text in the pending queue. Quit checks pending text and recoverable clipboard contents, then stops hotkeys, permission monitoring, insertion, playback, and audio preview.

Run `scripts/smoke.sh` for isolated synthetic persistence, evaluator, shared processing fallback, CLI protocol, and diagnostic redaction checks. No live recording, provider request, or permission modification is required.

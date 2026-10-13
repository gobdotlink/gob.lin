# Speech models

Parakeet TDT v3 is the default and only supported model. Its FluidAudio runtime accepts files and bounded 16 kHz mono PCM windows, with automatic language detection across 25 languages. The catalog reports native streaming and recognizer vocabulary biasing as unsupported. Application live transcription and dictionary processing use their own existing boundaries.

The acquisition store uses FluidAudio's download-only API. The model lives in `Application Support/gob.lin/models/parakeet-tdt-0.6b-v3`; completed and partial downloads remain there between attempts. The SDK validates response type and published size, retries transient network failures, resumes safe partial transfers and detects stalled transfers. A separate two-minute guard covers an unresponsive initial file listing, retrying it once before showing a recoverable failure. Once transfer begins, the SDK owns its stall/retry policy. Compilation has no download watchdog or fixed timeout.

After download, a local SHA256 inventory records required model files. Complete staged SDK caches can also be adopted locally. The next launch verifies the inventory without network access. This detects changes to installed bytes; it is not an upstream authenticity signature. Validation runs once per store lifetime so idle reloads do not rehash the model. Successful local runtime preparation establishes model compatibility. A damaged inventory fails visibly: Retry keeps existing downloads, while Download again replaces the dedicated cache. Unload frees runtime memory and keeps downloaded files.

The model service starts preparation at launch. Session leases pin the model before capture begins and remain held through recognition and file fallback. Capture can run while the service acquires or reloads the model; its caller owns ordered buffering and final drain. Selection, cancellation and repair cannot disturb active sessions. Idle unloading defaults to 15 minutes and supports Never, 5, 15 and 60 minutes. The maintenance task remains active during capture, and the last lease release resets the idle interval. A hotkey during an in-progress unload queues preparation behind it.

Model settings show download progress, indeterminate Core ML preparation with elapsed time, and measured new-install/cached-file runtime load durations. The labels describe the observed file-cache path rather than assuming macOS has already compiled the model.

## App integration

Create one `ParakeetModelStore(directory:)` and one `ParakeetSpeechEngine(modelDirectory:)` with the same exact directory. Inject both into `SpeechModelService(engine:store:defaults:)`. Include the service's `objectWillChange` in AppModel child subscriptions and call `preload()` when application services are enabled. Pass it to `SettingsView(model:speechModels:)`.

Acquire `try beginSession()` synchronously before starting capture. Start capture immediately and await `readyEngine(for:)` only in recognition work. Keep every lease through capture, streaming/tail work and batch recovery, then call `endSession(_:)` exactly once after the last worker exits, including cancellation and error paths. Queued recognition and a new recording each need their own lease. Stop and drain sessions before awaiting service `shutdown()`.

SwiftPM discovers the new files automatically. The Xcode project adds the two app files in its Models group and Sources build phase; engine files remain inside the existing package product. No project regeneration is required.

## Validation limits

Build and focused lifecycle checks do not establish microphone buffering, first-dictation success, cached reload latency or integrated capture/inference timing. Those require the signed application and real local model/capture evidence. This lane does not claim native streaming, a sub-second reload, or a fixed first-compilation duration.

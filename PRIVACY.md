# Privacy

gob.lin is designed for local dictation. Microphone access begins only after permission is granted and a dictation is started. Speech recognition runs on the selected on-device engine; this implementation does not select or download an engine before the benchmark is complete.

Dictionary entries, settings, and history live on your Mac under gob.lin's Application Support directory. History can include the raw transcript, final text, target app information, timing information, and the original audio. Starred entries are kept when applying retention. You can delete entries and their audio from History. Local history is sensitive: people or software with access to your account may be able to read it.

Cloud rewriting is optional and off by default. When you enable it, gob.lin sends the transcript, chosen tone, cleanup instructions, and preferred dictionary spellings to the provider endpoint you configure. The provider's own privacy and retention terms apply. API keys are stored in macOS Keychain, separate from settings and history. Disable rewriting to keep transcript processing local. Provider failures preserve the raw transcript and show an error.

Accessibility is used to insert text into the focused field and confirm insertion. Input Monitoring supports global dictation shortcuts. These permissions do not authorize background collection of the contents of unrelated apps. Diagnostics report software versions, permission and device status, timing, and sanitized errors; they must not contain dictation text or API keys. Inspect copied diagnostics before sharing them, since device and application names can identify your setup.

gob.lin does not include analytics or telemetry. No account is needed for local dictation. Future update or model-download features must document their network behavior before they ship.

Development lifecycle events are kept only on this Mac in `~/Library/Logs/gob.lin`, bounded to three 1 MiB files. They include build identity, launch/operation IDs, safe status/error codes, and device tokens that change each launch. They contain no audio, transcripts, clipboard contents, typed keys, credentials, or raw device names/UIDs. Diagnostics can reveal or export this trail; full macOS crash reports are shared separately after inspection. See [collection instructions](docs/diagnostics.md).

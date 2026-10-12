# Settings

One native settings window exposes General, Audio, Model, Dictionary, Post-processing, Tone, History, Overlay and About. Existing feature views share the same services as the menu bar and history. Changes persist under stable preference keys and apply without a restart; shortening retention requires Apply to prevent deletion while editing.

Microphones are stored by Core Audio UID, with a follow-system option. The explicit local level preview requires an existing microphone grant, becomes ready only after its first buffer, and stops when leaving the page or permission is revoked. A missing saved device falls back without erasing the preference. Preview callbacks are session guarded. This is a level preview, not the GOB-8 capture engine.

Login Items uses SMAppService and reports approval/errors. Audio capture, sounds, model download and recognizer binding remain separate benchmark/capture work; model selection clearly shows this pending state. Dictionary, rewrite credentials, tone, insertion space and clipboard recovery are real controls; no live provider request is made by opening settings.

Checked: SwiftPM build, signed app verification, Xcode debug compilation. Permission changes and login-item registration are user actions and are not toggled during automated verification.

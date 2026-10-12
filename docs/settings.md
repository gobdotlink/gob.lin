# Settings

One native settings window exposes General, Audio, Model, Dictionary, Post-processing, Tone, History, Overlay and About. Existing feature views share the same services as the menu bar and history. Changes persist under stable preference keys and apply without a restart; shortening retention requires Apply to prevent deletion while editing.

Dictionary's List and the Post-processing/Overlay forms fill the detail pane directly. General, Audio, Model, Tone, History retention and About provide their own page scroll view, so nested scrolling does not collapse the Dictionary rows.

Microphones are stored by Core Audio UID, with a follow-system option. The explicit local level preview requires an existing microphone grant, becomes ready only after its first buffer, and stops when leaving the page or permission is revoked. A missing saved device falls back without erasing the preference. Preview callbacks are session guarded. This is a level preview, not the GOB-8 capture engine.

The meter displays the loudest channel's RMS as device input, so a microphone on a later interface channel is visible. This does not select or downmix a recognizer input. An audio-engine format/configuration change stops the current preview and explains that it must be started again; callbacks from an older preview cannot change the new session.

Login Items uses SMAppService and reports approval/errors. Audio capture, sounds, model download and recognizer binding remain separate benchmark/capture work; model selection clearly shows this pending state. Dictionary, rewrite credentials, tone, insertion space and clipboard recovery are real controls; no live provider request is made by opening settings.

Login Items status refreshes when General appears, when gob.lin becomes active, and after each attempted change. History's count picker distinguishes no limit from zero unstarred entries, preserves custom saved counts, and reloads a newly saved policy from the History window.

Checked: SwiftPM build, signed app verification, Xcode debug compilation. Permission changes and login-item registration are user actions and are not toggled during automated verification.

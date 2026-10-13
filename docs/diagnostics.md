# Diagnostics and development logs

`DiagnosticFailure` remains the typed source of visible warnings and Apple unified-log failures. `DiagnosticsModel` deduplicates ongoing warnings, retains the latest 50 UI errors, and uses one `DevelopmentLog` shared with AppModel, microphone preview, and hotkeys. Clearing the UI error list leaves warnings and persistent logs intact. Permission refresh reads status without requesting grants.

## Retrieve a previous launch

Open **Settings → Diagnostics → Development logs**:

- **Reveal logs** opens `~/Library/Logs/gob.lin`.
- **Export recent logs…** saves one private text file containing current diagnostics, build identity, candidate crash-report filenames, and the retained JSONL event trail, oldest first. The previous session does not disappear on relaunch.
- **Reveal crash reports** selects the latest gob.lin report in `~/Library/Logs/DiagnosticReports`, or opens that folder if none is found. The export lists up to five candidates. Match their timestamp and `pid`/process name against a log launch before attaching a report. A filename is a candidate, not proof of association. macOS creates these reports asynchronously; refresh/export again if the report has not appeared yet.

Full macOS crash reports are excluded from export because they can contain paths and other system details. Review and attach the matching `.ips` separately when needed. SIGKILL does not create a macOS crash report, and an abrupt exit has no `appStopped` event.

For terminal collection, without launching the app or changing permissions:

```sh
open "$HOME/Library/Logs/gob.lin"
open "$HOME/Library/Logs/DiagnosticReports"
# Rotation order is events.2.jsonl, events.1.jsonl, then events.jsonl.
# Skip archives that are not present yet.
for file in events.2.jsonl events.1.jsonl events.jsonl; do
  if [ -f "$HOME/Library/Logs/gob.lin/$file" ]; then
    cat "$HOME/Library/Logs/gob.lin/$file"
  fi
done > goblin-recent-events.jsonl
```

Search that file for `previewRequested`, select its `operationID`, and follow events with the same `launchID` and operation. `sequence` orders events within a launch even when timestamps share a millisecond. `pid` and UTC timestamps support matching the crash report. UI export includes current active warnings, safe stage timings, and the candidate filenames in addition to the events.

Apple unified logs remain available as a supplementary source:

```sh
/usr/bin/log show --last 1h --style compact \
  --predicate 'subsystem BEGINSWITH "app.goblin.dictation"'
```

## Event trail and privacy

Three JSONL files retain at most 1 MiB each (3 MiB total); the oldest archive is removed on rotation. Files are created with mode 0600 in a mode-0700 directory. Every completed event is written and synchronized before its caller continues. Logging runs on the main actor at lifecycle transitions, never on an audio callback. There is no network logging, signal handler, raw-buffer logging, or per-key trail. Storage failure is visible in Diagnostics and emits a static unified-log error; export errors are also shown.

Each event includes a fractional UTC timestamp, sequence, severity, subsystem, app/version/bundle build, configuration, build UUID/time, source revision/dirty flag, launch UUID, PID, and an operation UUID for preview, processing, or insertion. The shared `BuildIdentity` package plugin generates the compiled stamp for both `swift build` and Xcode's local `GoblinCore` package. Gitless source archives explicitly report `unknown`; runtime Git and source paths are not used. Build UUIDs change when the plugin stamps a build. Use the Xcode project's signing settings rather than a global `CODE_SIGN_IDENTITY` override, which also changes the plugin target's signing requirements.

Preview records request/selection mode, inventory count, selected and resolved device tokens, missing-device fallback, device-selection/read OSStatus, channels/sample rate, tap installation, engine startup, the first usable UI-delivered buffer, configuration notification, failure, stop reason, and teardown completion. Tokens use a random per-launch HMAC key: the same UID has the same token within a launch, but cannot be linked between launches. Names and raw UIDs are never persisted. A failed device resolution is marked `succeeded:false`; it is not a guessed device.

Underlying errors retain only up to three numeric codes and allowlisted domains. Unknown domains become `other`. Error descriptions and arbitrary `userInfo` are excluded. Typed failures and safe timings also persist. Permissions/Secure Input changes, hotkey start/result/stop and action transitions, processing/rewrite results, insertion outcomes, and orderly application shutdown are covered where implemented. App dictation still awaits engine integration; logging does not claim audio capture or ASR ran when they have not.

Raw audio, transcripts, clipboard content, typed keys, credentials, authorization headers, provider payloads, target application names, and user paths never enter the event fields. The existing device-name opt-in applies only to the current environment in copied/exported diagnostics. Inspect exports before sharing.

## Focused regression probes

```sh
swift run DiagnosticsSmoke
scripts/check-development-logs.sh
scripts/smoke.sh
```

The first probe checks typed reporting and runs a console subprocess through a synthetic preview event sequence, SIGKILL, and relaunch. It checks retained ordering, correlation/build identity, device/error redaction, private file modes, torn trailing-record repair, rotation bounds, and visible I/O failure. `--evidence docs/evidence/gob-34` also writes a labeled artifact. The export probe compiles production app sources and calls the production exporter with an isolated fixture environment; it checks deduplication, prior launches, build identity, clear-list behavior, redaction, and device-name opt-in without opening UI, touching the general clipboard, reading TCC, or starting audio. These are storage/export probes, not hardware or permission validation.

For a live regression after audio integration, obtain the shared dogfood UI lock before launching one signed app. Preview → change input/stop or reproduce an error → terminate → relaunch → export. Confirm `previewRequested` → selection/fallback → format → tap/engine → `firstBuffer` → `configurationChanged` → stop/error under one operation, followed by a new launch UUID. Do not reset grants or change saved input preferences for this check. Configuration notifications are delivered onto the main actor; notifications queued during a fatal process failure may not reach the logger.

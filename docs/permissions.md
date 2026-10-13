# Permissions and recovery

gob.lin requires Microphone for audio capture and Accessibility for global shortcuts and focused-app insertion. It reads those grants and the informational Input Monitoring status at launch and every second while running. Readiness requires only Microphone + Accessibility. Onboarding has two required rows and never requests Input Monitoring. Launch can open onboarding, but never calls a permission-request API. The Accessibility Allow button makes its explicit request and opens the matching System Settings pane. Microphone Allow shows the system dialog while access is undecided, then returns to onboarding; after an earlier decision it opens the Microphone pane instead. Grants refresh the onboarding window; switching away and back also checks immediately.

Accessibility revocation calls `PermissionModel.onRevocation` before presenting recovery. The hotkey owner must stop its event tap and invalidate its run-loop source there. Microphone revocation uses the same callback so the recording owner can stop capture. `onChange` allows services to start after grants arrive. Input Monitoring changes do not revoke or cancel dictation: none of the current functionality uses a listen-only tap. No engine has been selected yet, so the under-60-second dictation acceptance remains dependent on the benchmark and engine integration.

When an event tap cannot be created, call `reportTapFailure()`. If macOS says Accessibility is enabled, onboarding explains stale grants. Toggle gob.lin off/on in System Settings and relaunch. If necessary, run:

```sh
tccutil reset Accessibility app.goblin.dictation
```

Then reopen the consistently signed app and grant access again. gob.lin does not run this destructive reset itself. Build with `scripts/build.sh debug`, then open the bundled app rather than the unsigned SwiftPM executable so TCC uses the stable app identity.

Manual checks: fresh launch shows onboarding without system permission dialogs; Allow microphone returns to onboarding; System Settings grants update live; revoking Accessibility shows recovery and removes/cancels active shortcut state. Permission changes are intentionally left to the user, rather than automated on the host machine.

## API contract

The shortcut tap uses `CGEvent.tapCreate(tap: .cgSessionEventTap, options: .defaultTap)` for key down/up and modifier flags. It modifies the stream by suppressing its keyed shortcut and Escape during recording. Apple distinguishes this Accessibility-authorized modifying tap from a `.listenOnly` tap, which requires Input Monitoring; see [WWDC19: Advances in macOS Security, synthetic events](https://developer.apple.com/videos/play/wwdc2019/701/). `CGPreflightListenEventAccess()` describes event-listening access, not whether this modifying tap will work. Its result remains visible in diagnostics as “not required” and never gates startup, event handling, recording readiness or insertion.

Shortcut recording uses `NSEvent.addLocalMonitorForEvents` within gob.lin. Apple's same presentation describes local event monitoring as available without background keyboard-monitoring approval. The keyed Secure Input fallback uses Carbon `RegisterEventHotKey`; it does not observe all keyboard input. Focused-app insertion uses Accessibility APIs and synthesized paste events, so Accessibility remains required. Microphone access is still checked before capture. There is no optional listen-only mode to request Input Monitoring for.

Accessibility preflight remains a prerequisite, and actual tap creation remains the runtime check. A failed tap reports a shortcut failure and presents existing recovery guidance; it does not infer missing Input Monitoring. Secure Input still pauses modifier-only shortcuts and rejects protected insertion. Accessibility/microphone revocation still cancels active shortcut state, stops capture through its owner, and presents onboarding. No grant resets or protection bypasses are performed by this change.

See [GOB-35 verification](evidence/gob-35/verification.md) for observed checks and uncovered hardware/permission states. Run `scripts/check-permissions.sh` for readiness combinations and diagnostic recovery assertions; these supplied snapshots do not demonstrate system grants or physical keyboard behavior.

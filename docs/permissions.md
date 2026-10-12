# Permissions and recovery

gob.lin reads microphone, Accessibility and Input Monitoring status at launch and every second while running. Launch can open onboarding, but never calls a permission-request API. The Accessibility and Input Monitoring Allow buttons make their explicit request and open the matching System Settings pane. Microphone Allow shows the system dialog while access is undecided, then returns to onboarding; after an earlier decision it opens the Microphone pane instead. Grants refresh the onboarding window; switching away and back also checks immediately.

Accessibility or Input Monitoring revocation calls `PermissionModel.onRevocation` before presenting recovery. The hotkey owner must stop its event tap and invalidate its run-loop source there. Microphone revocation uses the same callback so the recording owner can stop capture. `onChange` allows services to start after grants arrive. No engine has been selected yet, so the under-60-second dictation acceptance remains dependent on the benchmark and engine integration.

When an event tap cannot be created, call `reportTapFailure()`. If macOS says Accessibility is enabled, onboarding explains stale grants. Toggle gob.lin off/on in System Settings and relaunch. If necessary, run:

```sh
tccutil reset Accessibility app.goblin.dictation
```

Then reopen the consistently signed app and grant access again. gob.lin does not run this destructive reset itself. Input Monitoring changes can also require a relaunch. Build with `scripts/build.sh debug`, then open the bundled app rather than the unsigned SwiftPM executable so TCC uses the stable app identity.

Manual checks: fresh launch shows onboarding without system permission dialogs; Allow microphone returns to onboarding; System Settings grants update live; revoking Accessibility shows recovery and must remove an active tap once the hotkey branch is integrated. Permission changes are intentionally left to the user, rather than automated on the host machine.

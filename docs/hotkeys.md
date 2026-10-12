# Native hotkeys

The dedicated event-tap thread owns its run loop, tap, and source. Revocation sets the stop flag, stops and wakes the run loop, then removes its source and invalidates the port. A timeout re-enables the tap in its callback. There is no enabled-state polling. Permission checks use the separate onboarding monitor.

Fn/Globe and Right Option use event flags and the right-side Option device flag. Set Keyboard → Press Globe key to → Do Nothing. Non-Apple keyboards may consume Fn in firmware; use Right Option or Option+Space. Modifier events pass through so ordinary chords still work. A non-modifier key or extra modifier invalidates a modifier-only tap; a chord after the hold threshold cancels the recording state.

A 300 ms threshold distinguishes hold from tap. Key repeats are ignored; a 40 ms release hold-back absorbs repeat pairs. A raw release marks the hold as pending release immediately, so a queued threshold callback cannot convert a short tap into a hold during that interval. Escape is consumed only during a recording state. Capture starts immediately even if an earlier transcription is processing; completed captures queue for processing. The service exposes `onAction` and `processingCompleted()` for the engine pipeline. With no engine callback, it exercises shortcut state only and never claims audio is being recorded.

Secure Input is checked on the main thread every 500 ms and at Carbon press delivery. A keyed shortcut is registered with Carbon for both `kEventHotKeyPressed` and `kEventHotKeyReleased`. The paired release remains accepted if Secure Input turns off during a hold. Modifier-only shortcuts pause and show a visible warning; they cannot bypass Secure Input. Escape's Carbon registration exists only during recording. Sleep and session resignation stop capture cleanly; wake and session activation restart the tap. Callback disable notifications clear pending/recording state safely.

Shortcut preferences persist in UserDefaults. The native recorder suspends global capture while collecting local events and exposes Fn, Right Option and Option+Space presets.

Run `bash scripts/check-hotkeys.sh` for the narrowly scoped state safety checks (tap/hold/chord/Escape/processing overlap/repeats). Native hardware acceptance requires user-approved grants and keyboard interactions. Engine wiring and actual audio acceptance remain dependent on the benchmark.

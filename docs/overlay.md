# Dictation overlay

`OverlayController.begin` starts a session and returns its UUID. Pass that session ID to updates and delayed hides; stale callbacks from an earlier dictation are ignored. The header and scrolling transcript area keep the same size from arming through finalization, including empty and long transcripts. Error details stay inside that area. The settings preview is explicitly synthetic.

Audio frames drain on a separate task from UI events. Microphone levels are coalesced and rendered at most 20 times per second; they do not reorder the panel. Recoverable live revisions remain in diagnostics without replacing the recording header. A terminal preview failure latches one recording notice until the next session. Stop ends preview publication and scheduling while final capture frames still reach recognition. After a paste shortcut is sent, the overlay closes; an app that cannot verify the edit leaves the transcript on the clipboard and the previous clipboard recoverable without reporting a confirmed insertion.

The panel is non-activating and cannot become key or main, uses status-bar level, joins all Spaces, and is a full-screen auxiliary. Placement uses the pointer’s screen and its visible frame, above the Dock or below the menu bar/notch. Mouth position follows finite, clamped microphone level; motion respects Reduce Motion. Goblin and hand layers use the original brand assets.

Checks: SwiftPM and Xcode builds. Actual full-screen/Spaces/multi-monitor behavior requires a Mac with those arrangements; do not claim it from a source review alone.

Showing and hiding animate with a critically damped spring, emerging from and retreating to the screen edge the overlay sits on; Reduce Motion uses a short fade. The panel orders out once the exit settles. A `begin()` during an exit reverses from the current on-screen state, and settles the cleared content's size first: resizing the panel inside the animated update drops the animation. The pill is opaque and only its shape casts the shadow, so live text growth never changes mascot pixels.

Hiding ends the session; a later callback must call `begin()` to show a new state. Delayed hides reject stale session IDs before canceling any timer. Display changes re-resolve the stored screen number and fall back to the main screen if it is removed. Physical display removal/Spaces/fullscreen remain hardware checks.

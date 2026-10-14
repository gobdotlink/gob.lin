# Dictation overlay

`OverlayController.begin` starts a session and returns its UUID. Pass that session ID to updates and delayed hides; stale callbacks from an earlier dictation are ignored. Finalization changes phase without clearing the existing text. Microphone and live recognizer updates are connected after the engine spike. The settings preview is explicitly synthetic.

The panel is non-activating and cannot become key or main, uses status-bar level, joins all Spaces, and is a full-screen auxiliary. Placement uses the pointer’s screen and its visible frame, above the Dock or below the menu bar/notch. Mouth position follows finite, clamped microphone level; motion respects Reduce Motion. Goblin and hand layers use the original brand assets.

Checks: SwiftPM and Xcode builds. Actual full-screen/Spaces/multi-monitor behavior requires a Mac with those arrangements; do not claim it from a source review alone.

Showing and hiding animate with a critically damped spring, emerging from and retreating to the screen edge the overlay sits on; Reduce Motion uses a short fade. The panel orders out once the exit settles. A `begin()` during an exit reverses from the current on-screen state, and settles the cleared content's size first: resizing the panel inside the animated update drops the animation. The pill is opaque and only its shape casts the shadow, so live text growth never changes mascot pixels.

Hiding ends the session; a later callback must call `begin()` to show a new state. Delayed hides reject stale session IDs before canceling any timer. Display changes re-resolve the stored screen number and fall back to the main screen if it is removed. Physical display removal/Spaces/fullscreen remain hardware checks.

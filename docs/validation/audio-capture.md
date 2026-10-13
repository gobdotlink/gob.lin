# Audio capture validation

The capture service produces ordered 16 kHz mono Float32 frames and writes them to a private WAV before delivery. The settings level preview and dictation share one microphone engine. Explicit warm mode keeps up to 500 ms of pre-roll in memory and keeps the system microphone indicator on. Cold starts remain arming until actual converted samples arrive; speech before the microphone opens cannot be recovered.

## Executed checks

`scripts/check-audio-capture.sh` compiles the capture code with Swift 6 and warnings as errors. It uses the actual platform converter at 16,000, 44,100 and 48,000 Hz with stereo input and a nonzero final tail. It checks contiguous sample positions, readiness before frames, finite samples, mono 16 kHz WAV lengths, and converted sample counts within one rounding sample. The awkward boundaries produced 1,677, 1,628 and 1,626 samples respectively, all nonzero.

The same focused check verifies incremental-file recovery after an incomplete trailing sample, explicit cancellation deletion, and preservation of 1,600 samples when the input configuration is interrupted. These checks address audio loss and storage correctness; they do not simulate hardware acceptance or a long recording.

The app builds with the capture service and the settings preview adapter. No dependency or Xcode project membership changes are needed: Xcode uses the GoblinEngines package product.

## Hardware acceptance still open

A certificate-signed non-UI capture probe was attempted without replacing the running app. Its launch context reported microphone permission missing, so it stopped before capture. No permissions were reset or requested and no hardware success is claimed. The existing app was left running. A native check needs the granted app launch context coordinated with the running instance.

Not yet observed: built-in/DJI nonzero hardware capture, first-word preservation, repeated hardware stop/start and device switching, AirPods, selected-device unplug, actual computer sleep, and a 30-minute recording. No latency or zero-loss hardware claim is made from the converter checks.

## Recovery and cancellation

Completed WAV files have their header and data synchronized and are renamed before stop returns. Active files use `.partial.wav` and checkpoint approximately once per second. Recovery repairs the header from complete bytes on disk and truncates an incomplete final sample. Process-crash recovery can preserve kernel-written audio; storage or power loss cannot promise bytes not yet synchronized. Cancellation deletes the session's recording intentionally. Device, permission, callback, digital-silence, conversion and storage errors retain recoverable prior audio and require the caller to end that session before starting another.

Callbacks run on one serial processing queue and must return promptly. Actor consumers should yield into one ordered stream and bound their own buffering or fall back to the durable recording. Audio ingress is bounded to two seconds; processing overload fails explicitly rather than dropping samples silently. No content is sent to a network service by capture.

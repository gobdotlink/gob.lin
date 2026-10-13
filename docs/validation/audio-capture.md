# Audio capture validation

The capture service produces ordered 16 kHz mono Float32 frames and writes them to a private WAV before delivery. The settings level preview and dictation share one microphone engine. Explicit warm mode keeps up to 500 ms of pre-roll in memory and keeps the system microphone indicator on. Cold starts remain arming until actual converted samples arrive; speech before the microphone opens cannot be recovered.

## Executed checks

`scripts/check-audio-capture.sh` compiles the capture code with Swift 6 and warnings as errors. It uses the actual platform converter at 16,000, 44,100 and 48,000 Hz with stereo input and a nonzero final tail. It checks contiguous sample positions, readiness before frames, finite samples, mono 16 kHz WAV lengths, and converted sample counts within one rounding sample. The awkward boundaries produced 1,677, 1,628 and 1,626 samples respectively, all nonzero.

The same focused check verifies that recovery skips an active writer, incremental-file recovery of complete samples beyond a stale header while truncating an incomplete trailing sample, explicit cancellation deletion, preservation of 1,600 samples when the input configuration is interrupted, the bounded 8,000-sample pre-roll, no pre-roll leakage into the next session, overload failure, real-clock all-zero/no-callback watchdogs, and invalid storage rejection. These checks address audio loss and storage correctness; they do not simulate hardware acceptance or a long recording.

The app builds with the capture service and the settings preview adapter. No dependency or Xcode project membership changes are needed: Xcode uses the GoblinEngines package product.

## Native checks

A signed probe launched through the supported launcher reported microphone authorization granted. A direct executable invocation had previously reported missing permission; that result did not describe the proper app launch context. The previously running instance was gracefully quit with coordinator authorization after checking its exact PID and executable path. No microphone grants, certificate identities, or system microphone preferences were changed.

The native run found and corrected a device guard bug: hardware input had one channel while the engine tap had two. The guard now compares input and output with their respective startup formats and still requires the same live device, engine, and audio unit. Benign configuration notifications no longer stop this valid stream.

Selected DJI capture passed twice with contiguous frame positions and readable mono 16 kHz Float32 WAV files: 48,000 samples and 49,600 samples, nonzero peak 0.00653 and 0.00806, first converted-buffer delay 226.2 ms and 201.3 ms. Missing-UID fallback passed with 49,600 nonzero samples and a 220.3 ms first-buffer delay. Warm capture included 8,000 pre-roll samples, 24,386 total samples, and a 5.4 ms first-buffer delay. Explicit native cancellation removed its partial file. These are sample/latency measurements for this run; no first-word speech recognition claim follows from them.

The built-in microphone was attempted with the laptop lid closed. It delivered 82,764 exact-zero samples and the watchdog reported `allZeroStream`; a later open was unavailable. Built-in speech acceptance remains unverified in this hardware setup. The UI error now includes the laptop lid among the checks for digital silence.

The actual 30-minute DJI capture passed: 1,800.1977 seconds of wall-clock capture, 28,801,600 samples delivered across 18,002 ordered frames, and a finalized WAV duration of 1,800.1 seconds. The 115,206,444-byte file was reopened successfully; its Float32/16 kHz/mono header, exact byte/sample length, private 0600 mode, and nonzero windows near the beginning, middle, and end were checked. The final converter drain added 270 real samples after the last progress checkpoint. No capture errors or sample-position gaps were reported. Observed resident memory stayed between 17,520 and 21,184 KiB (17.1–20.7 MiB), independently of file growth.

The timed native executable used commit `e43f0614dede488fff9d35a31e3d9ca61bec9a19`; subsequent advisory-lock hardening in `ceac1be704e2af7731f98145ca52d2c35f7c534f` was verified separately against real file handles, including active-writer exclusion, finalization, cancellation, and stale-header recovery. The running bundle was never overwritten. The final app build, certificate signing, and launcher verification passed. Sanitized numeric evidence is in `audio-capture-results.json`; raw audio remains outside Git.

The probe closed its engine and exited normally, releasing the desktop lock. Still untested: physical first-word preservation on built-in/AirPods, built-in speech with the lid open, AirPods capture, selected-device unplug, and actual computer sleep. The full ticket acceptance remains open for these physical scenarios; the 30-minute DJI capture itself is observed and passed.

## Recovery and cancellation

Completed WAV files have their header and data synchronized and are renamed before stop returns. Active files use `.partial.wav` and checkpoint approximately once per second. Recovery takes a nonblocking exclusive writer lock, skips files that are still recording, repairs the header from complete bytes on disk and truncates an incomplete final sample. Finalization and cancellation retain the lock through the rename or deletion. Process-crash recovery can preserve kernel-written audio; storage or power loss cannot promise bytes not yet synchronized. Cancellation deletes the session's recording intentionally. Device, permission, callback, digital-silence, conversion and storage errors retain recoverable prior audio and require the caller to end that session before starting another.

Callbacks run on one serial processing queue and must return promptly. Actor consumers should yield into one ordered stream and bound their own buffering or fall back to the durable recording. Audio ingress is bounded to two seconds; processing overload fails explicitly rather than dropping samples silently. No content is sent to a network service by capture.

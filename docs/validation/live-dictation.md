# Integrated live dictation

The app now connects its actual hotkey, shared microphone owner, local Parakeet
runtime and model leases. Capture opens while preparation runs. One ordered,
bounded frame consumer feeds live recognition; original audio is written to disk.
Release drains capture and that consumer before finalizing the retained tail.
Failed, discontinuous, overflowing or empty live output recovers through the
shared full-file pipeline. Explicit cancellation suppresses that fallback.

Completed captures process in order while another capture can run. Each owns its
model lease, target app, cancellation and overlay token. Earlier completion cannot
replace a newer overlay. Finalization retains visible text and its text area.
Final output uses the shared dictionary, tone and optional rewrite processor,
existing insertion acknowledgement and clipboard recovery, and History's durable
original audio, raw/final text, model, target and timings. Cancellation after an
insertion attempt retains recovery because already-inserted text cannot be retracted.

## Candidate and measured limits

Live recognition retains at most six seconds of normalized mono 16 kHz PCM.
It schedules one decode at a time, every 400 ms until nonempty output, then every
600 ms. Timestamped words matching consecutive hypotheses commit outside a
two-second trailing margin; retained audio starts at a whole word and includes
about 1.5 seconds of overlap. Tokens can use word markers, leading spaces or
separate whitespace pieces. Changed overlap requires original-audio recovery.
There are no growing-full-recording live redecodes.

The SDK can revise a word after two matching hypotheses and the trailing margin.
The actual merger detected this on long examples. Conservative batch recovery
preserves complete final text but makes release cost depend on recording length.
This candidate does **not** establish the requested flat 150 ms release bound,
0.5-second first text across recordings, or batch-equivalent bounded-prefix accuracy.
Native streaming is not advertised by the model catalog.

Actual accelerated merger replay on Apple M4 Pro / macOS 26.6.2, 2026-10-13:

| Audio | Tail finish | Full-file decode | Result |
|---|---:|---:|---|
| 3 s | 49.8 ms | 46.7 ms | Live final exactly matched batch |
| 60 s | Required batch | 351.0 ms | Changed committed hypothesis detected |
| 300 s | Required batch | 1,237.0 ms | Changed committed hypothesis detected |

The 60-second input was completed by repeating a shorter local source; the
300-second input was an excerpt of a composite. These are recognition/merger
measurements, not native microphone-release measurements. A nil tail finish is
not successful finalization. Low live work after failure does not establish a
working continuous-stream compute budget. No human-labeled corpus accuracy or
Neural Engine energy result is claimed.

## Native checks

A certificate-signed app-context probe links the production AppModel, services,
overlay and engine. It uses a separate data directory and preferences, actual
microphone input and OS Option-Space events, a neutral spoken playback fixture,
and an isolated native text target with ordinary Edit/Paste support. It launches
through the supported exact-bundle launcher. It neither resets grants nor changes
the system microphone. Test instances close after validation; raw audio, text and
unsanitized captures remain outside Git.

Observed checks passed: live text, a non-key overlay preserving target focus,
model reload with capture ready before model readiness, two overlapping leases,
a new capture surviving earlier insertion/history completion, visible text and
stable text-area height during finalization, acknowledged paste and original
clipboard restoration, saved original audio/text/timings, shared dictionary/tone,
Escape suppressing canceled output, shared Settings preview joining/leaving capture,
and cancellation during finalization suppressing output. Three saved utterances retained the
ending and exactly matched independent full-file recognition. These observations
are fixture evidence, not general recognition accuracy.

Short native runs varied: release to final recognition text was 143.3 ms and
177.4 ms; first text from keydown was 792.7 ms and 437.6 ms. Keydown includes the
hold threshold. Warm pre-roll can contain earlier speech, so a first update from
capture readiness is not automatically a fresh speech-onset measurement.
Timed native capture observations:

| Held capture | Saved original incl. pre-roll/tail | Release to final recognition text | Release to acknowledged/saved History | Independent batch match |
|---|---:|---:|---:|---|
| 3 s | 3.625 s | 129.4 ms | 325.1 ms | Yes |
| 60 s | 60.511 s | 405.8 ms | 581.8 ms | Yes |
| 300 s | 300.623 s | 1,424.8 ms | 1,595.6 ms | Yes |

These use actual microphone capture with repeated neutral spoken playback,
not prerecorded PCM injected into the app. The one- and five-minute release
targets failed. First text from readiness was 43.4 / 432.7 / 1,631.0 ms;
the earliest case contains previous warm speech. All three inserted output and
retained original audio with raw text matching independent batch. Full aggregate
results are in `live-dictation-results.json`.
The overlay observation includes key-release handling, capture/frame drain,
recognition and queueing; acknowledged insertion and History finish are measured
separately. The final probe revision measures postprocessed text through AppModel's published
transcript rather than tentative-tail clearing; the long observations above used
the earlier recognition-text endpoint. After the readiness and notice follow-ups,
the final native recheck passed and measured **140.2 ms** release to postprocessed
text, with **2,074.5 ms** first text from keydown. The variable first-text and release
results remain acceptance limits.

Builds and focused checks cover frame ordering, word-piece parsing, commitment,
final tail, bounds, empty recovery, canceled streams, ordered processing, model
lifecycle and app Xcode membership. Actual CLI recognition of saved native audio
matched the app's raw text and final dictionary/tone output; a missing local model
returned pure structured JSON error output. Simulated assertions do not prove recognition.
Physical Fn, speech before a cold microphone opens, permission revocation,
device unplug/sleep, provider-backed rewriting, and a trusted accuracy subset
remain separate acceptance work. The capture correction checkpoint for partial-write
preservation, gated silence and preview/warm/sleep ordering is integrated. The short
native recheck passed the workflow and observed a valid session joining an actual
Settings preparation cancellation. It measured 161.1 ms release to postprocessed
text and 785.3 ms first text from keydown. All four saved utterances matched independent
batch, but the exact spoken fixture ending matched only two. The physical/acoustic
cause was not isolated; batch equality does not establish exact speech accuracy.
Physical sleep, physical gated silence and actual disk filling remain unverified.

The probe now waits for the current event tap's success callback, uses a separate
Control-Option-Shift-Grave shortcut in its private preferences, and cancels if its
reserved target loses focus. Earlier Option-Space probe attempts encountered a
target change and unacknowledged insertion; their transcripts/audio stayed in
History and those overall runs were failed. Probe-only clipboard recovery restores
only while its recorded pasteboard change count remains owned. These constraints
keep validation confined to its isolated target.

## Running the native probe

Build only after existing app/check instances close, using the project's existing
signing identity. Hold the shared build/inference and native desktop resources.

```sh
scripts/build-native-dictation-check.sh /path/to/private-check-output
open -n '/path/to/private-check-output/Native Target.app'
scripts/launch.sh /path/to/private-check-output/gob.lin.app
```

The probe writes private `results/native-result.json` and terminates. Close the
isolated target afterward. Optional `durations.json` beside the bundles, containing
`[3,60,300]`, enables actual timed captures and writes private progress. These
checks use the granted microphone and clipboard, so run them in a reserved native
session. An unsigned Xcode product is compile-only and must not request grants.

# Local speech runtime and measurements

Parakeet TDT v3 is the first/default model, using FluidAudio **0.17.7**, pinned to
`503b4bd1bbf7220882de39fe8ae6716aae4132da`. The adapter uses the int8 Core ML
encoder with the SDK's CPU/Neural Engine placement. The [model catalog](models.md)
also offers Whisper, SenseVoice and Nemotron runtimes; the measurements below cover Parakeet only.
Native streaming and recognizer vocabulary biasing remain false for these adapters.

`ParakeetModelStore` owns acquisition and cache integrity. `ParakeetSpeechEngine`
loads locally and serializes preparation, file recognition, bounded PCM recognition,
and unload. The exact compiled folder is
`~/Library/Application Support/gob.lin/models/parakeet-tdt-0.6b-v3`.
The SDK folder name differs from the upstream model ID's `-coreml` suffix.
`prepare()` must precede recognition. Unload drains in-flight work and leaves
files intact; cancellation suppresses results after the SDK returns.

`PCMSpeechEngine.transcribe(samples:)` accepts finite normalized mono Float32 at
16 kHz, with a hard **240,000-sample / 15-second** limit. Results contain text
and window-relative token pieces, timestamps, confidence, and optional token ID.
Each request uses fresh decoder state. The session layer owns bounded tail
retention, committed/tentative text, audio ordering, and original-file recovery.
File transcription uses the existing `RecordedAudioPipeline`; long files use
the SDK's disk-backed path. Full-growing-buffer live decoding is rejected.

## Actual measurements

Measured on 2026-10-13: Apple M4 Pro, 24 GB, macOS 26.6.2, release CLI.
Every build/inference/timing run held the shared compute lock; no other speech
lane ran concurrently. User desktop applications remained active (system load
around 7), so these are serialized runs on an active machine, not a fully quiet
benchmark. No microphone, live provider, or corpus upload was used.

**250 local recordings:** 3,409.542 seconds of audio, 19.131 seconds of total
recognition work (~178× aggregate real time). All files decoded; two returned
empty text. Per-file p50 **51.5 ms**, p95 **220.8 ms**, maximum **468.7 ms**.
Peak process RSS was **133.6 MB**. Empty results are not assigned an accuracy
label without human ground truth.

A successful first measured store/prepare call took **2,335.9 ms**, including
cache verification and local loading; immediate unload/reload took **119.8 ms**.
An independent process's local-only load took **219.9 ms**. Installed TDT file
sizes total **483.3 MB**. One preparation sample had RSS 8.5 MB before load,
137.5 MB loaded, and 102.6 MB after unload: SDK/Core ML caches do not promise
immediate return to the process's initial RSS. The initial download completed,
but the first preparation attempt failed on the folder mismatch; its download
and first hardware compilation time were not isolated. No cold-compile claim
is made, and no cache was deleted just to manufacture one. A later debug runtime
smoke showed about **16.2 seconds** between vocabulary loading and manager
initialization, followed by ~0.1s reloads. Warm release measurements do not
establish a universal first-load bound; capture must remain recoverable while
preparation is delayed. A final release cached-prepare sample separated **309.3 ms**
cache verification from **242.1 ms** local load, with **95.4 ms** immediate reload.
That process sampled **391.7 MB RSS** after preparation and unload. This larger
sample includes the store verification/loading path; the corpus-only 133.6 MB
measurement is not an end-to-end memory ceiling.

### Bounded-window candidates

Replay used a real 3.15-second recording and 60-/300-second excerpts from
composites assembled from the same real recordings. Long clips are not claimed
to be continuous native five-minute dictations. Replay was accelerated, measuring
recognition work and nonempty output at known sample positions; it did not
measure native key-up, capture drain, queueing, commitment, postprocessing or insertion.

At 400 ms cadence, each long-window candidate decoded 900 windows:

| Retained audio | p50 work | p95 work | Maximum | Mean work / speech time | Final decode: 60s / 300s |
|---|---:|---:|---:|---:|---:|
| 1.5s | 33.3 ms | 38.4 ms | 56.5 ms | 8.49% | 31.9 / 33.6 ms |
| 3s | 42.3 ms | 108.7 ms | 286.7 ms | 14.70% | 74.0 / 43.2 ms |
| 6s | 47.0 ms | 83.2 ms | 191.0 ms | 12.58% | 84.3 / 82.3 ms |
| 12s | 63.5 ms | 85.1 ms | 251.3 ms | 16.28% | 61.2 / 68.1 ms |

The short clip's 6s-tail final decode took **40.7 ms**. Its first nonempty output
arrived at audio position 400 ms plus 31 ms of work (~431 ms idealized). Long
composites first produced nonempty text at 1.6s plus ~34–36 ms of work for
3/6/12s windows; 1.5s windows needed 2.0s. Amplitude activity crossed RMS 0.01
at 0.14s; this threshold is not a hand-labeled speech onset.

A separately measured **6s tail / 600 ms cadence**, across all three durations,
decoded 606 windows: p50 **45.5 ms**, p95 **73.7 ms**, maximum **148.7 ms**, mean
work **7.97%**. Final decode was **41.4 / 43.3 / 49.1 ms** at 3.15 / 60 / 300s.
First output was ~631 ms on the short clip and ~1.835s on the long composites.

**Recommended candidate:** retain six seconds, use early 400 ms updates until
first text, then 600 ms updates. The combined adaptive schedule and native
session layer still need validation. Shorter tails reduce work but lack evidence
of equivalent accuracy/context. Most tail decode times fit a 150 ms recognition
budget, but outliers, first-text delays, capture/queue overhead, and original-file
recovery mean **≤150 ms release-to-text and ~0.5s first text are not established**.
No bounded-tail versus full-file accuracy equivalence is claimed. EOU streaming
and Apple diagnostic comparisons were not run; neither is another shipping model.

## From key-up to transcript

`LiveTranscriber` builds the final transcript while the user talks. Previews decode a bounded window and stitch committed words. That is fine for showing progress, but the stitched text drops and garbles words that a decode with more context keeps: 2.6–4.3% of words differed from a whole-recording decode on 21 real dictations. So the final transcript is built separately, in chunks:

- **Closing a chunk:** a chunk closes at every settled pause. Otherwise it closes once it reaches two thirds of a window, at the widest gap of at least 150 ms after its first quarter window, between committed words or the latest preview's. In fast speech whose previews keep changing, few words commit and they sit back to back, so only the latest preview shows the pauses. Within two seconds of a full window, a gap of one model frame (80 ms) will do; words with no gap between them are never split.
- **Decoding it:** each closed chunk is decoded once, in the background, from a window of up to 15 s that ends a second after its boundary. It hears the speech before it as context, and the start of what follows, so its last words aren't read as the end of an utterance. Parakeet v3 can decode a window with speech in it to nothing, depending on exactly where the audio ends; a decode that comes back empty, though the speech detector heard speech, is retried once with a quarter second of silence appended. Making room for the silence only trims context from before the chunk's words and half a second of their onset; when it can't, the retry is skipped.
- **Assigning words:** words go to chunks by where they start, with one shared threshold 100 ms before each boundary. Splitting at the gap nearest each boundary instead repeated a word at 3 seams in 40 real dictations, because a word's end can stretch to punctuation emitted after it.
- **Checking for lost words:** if a chunk's decode keeps no words where the previews heard some, key-up uses the previews' path, or the original recording, instead.
- **At key-up:** the open chunk is decoded at once from the audio received so far, for AI cleanup to start on while capture closes (`releaseText`). Once capture has stopped, the open chunk is decoded again with all of its audio and joined to the closed ones; that is the final transcript.
- **Falling back to the original recording:** happens when a chunk can't close between words before it fills a window, when audio went missing, or when a decode fails.

`goblin live-replay <recordings> --texts` replays recordings at speaking pace through this path and reports key-up timings next to a whole-recording decode. On 40 real dictations (1.4–85 s, 16 minutes in all, 30 October 2026, M4 Pro):

- **Speed:** 39 takes ended on the chunked transcript, with key-up to transcript at a median of 99 ms and a p90 of 116 ms; an earlier run of the same path measured 86 ms and 103 ms. The other take, 28 s long, filled the live window before a chunk could close and was recognized again from the recording in 601 ms. A whole-recording decode took 3–830 ms.
- **Accuracy:** 2.7% of words differed from the whole-recording decode, with errors on both sides: the chunks heard some technical terms correctly that the whole recording misheard, and the reverse.

### Vocabulary diagnostic (removed)

An earlier CLI diagnostic evaluated the SDK's acoustic rescoring path with an
auxiliary CTC 110M model. The app later shipped it behind a spelling guard as
Parakeet dictionary correction, and has since removed both; see
[Dictionary](dictionary.md#no-parakeet-correction).

With **120 available local terms** over the same 250 recordings, CTC/rescoring
added **96.628 seconds** of work: p50 **223.0 ms**, p95 **1,159.8 ms**, maximum
**3,278.4 ms**. It changed **126 transcripts**, applying **274 replacements**;
peak sampled RSS was **196.6 MB**. Changes are not known improvements or false
corrections. The available jargon examples also lack verified expected terms.
The TDT manager's direct API has no vocabulary parameter; this measured SDK
path performs acoustic-evidence rescoring rather than establishing decoder biasing.
Do not enable a blanket correction pass from these unlabeled results.

## Reproduction and remaining evidence

```
goblin prepare-model
goblin benchmark <private-recordings-directory> --repeat 1
goblin benchmark <private-clips-directory> --repeat 3 --windows 1.5,3,6,12 --cadence-ms 400
goblin benchmark <private-clips-directory> --windows 6 --cadence-ms 600
```

Benchmark JSONL contains detailed transcripts/tokens and must remain outside
Git. This document contains aggregate measurements only. `--model-dir` accepts
the exact compiled TDT folder. Explicit preparation calls the shared acquisition
store; replay/transcribe/benchmark load local models. The existing evaluation
harness can compute WER and jargon/ordinary-word regressions once trusted
annotations exist. Current machine-produced comparison transcripts cannot supply
that ground truth. Missing input: a hand-checked subset with file/ID alignment,
reference text, expected jargon occurrences and ordinary-word preservation labels.

Builds and existing CLI/evaluation smoke checks exercise local failures, window
limits, serialization, cancellation after real inference and unload/reload.
The native capture/hotkey/session/overlay/insertion/history path still needs its
integration and hardware acceptance; these runtime measurements do not substitute
for it. SDK EOU, energy/idle CPU, true cold hardware compilation, and labeled
vocabulary accuracy remain unmeasured.

The SDK and dependency notices, original/conversion model cards, Apache 2.0 and
CC BY 4.0 texts are bundled in app assets; see [third-party notices](../THIRD_PARTY_NOTICES.md).
No weights, recordings or private transcripts are committed.

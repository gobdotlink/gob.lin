---
license: openmdw-1.1
base_model: nvidia/Nemotron-3-Diarization
library_name: fluidaudio
pipeline_tag: voice-activity-detection
tags:
  - speaker-diarization
  - streaming
  - coreml
  - apple-silicon
  - ane
  - sortformer
---

# Nemotron 3 Diarization — CoreML for Apple Silicon

CoreML conversion of NVIDIA's [Nemotron 3 Diarization](https://huggingface.co/nvidia/Nemotron-3-Diarization)
(8-speaker streaming Sortformer, 100M params, 31-layer RoPE Transformer, 10 ms output
resolution), optimized for on-device inference on Apple platforms via
[FluidAudio](https://github.com/FluidInference/FluidAudio).

Runs fully on-device — Neural Engine or GPU — on macOS 14+ / iOS 17+.

## Highlights (M5 Pro)

- **Reproduces NVIDIA's model-card accuracy on-device**: AMI MHM `offline` 9.47 DER
  (card 9.25), `low` 9.75 (card 9.48) — same forced-alignment references, collar 0.
  The ~0.25 gap is the fp16 CoreML runtime against NVIDIA's bf16 GPU numbers, and it
  is consistent across presets rather than drifting.
- **`fast128` is the accuracy pick**: 9.36 DER at 546x wall real-time, and it counts
  speakers correctly on all 16 AMI test meetings — better than any row on NVIDIA's
  card, which tops out at 87.5% speaker-counting accuracy.
- **8-speaker streaming down to 1.04 s latency**, the card's own reference config.
- **100% ANE-resident W8A8 split builds at half the weight footprint**:
  `c128-split-w8a8` gives up 0.27 DER for 95 MB and keeps 16/16 speaker counting.

## Which model should I use?

| Model | Size | Audio/call | Latency | DER¹ | SCA¹ | Wall RTFx | Pros | Cons |
|---|---|---|---|---|---|---|---|---|
| `fast128` | 190 MB | 10.24 s | 10.56 s | **9.36** | **100.0** | 546x | Best accuracy and speaker counting of the set | 10.5 s latency — near-live only |
| `offline` | 190 MB | 27.2 s | 30.4 s | 9.47 | 87.5 | **904x** | Fastest wall clock; the card's batch config | No ANE (compiler limit); 30 s latency |
| `fast32` | 190 MB | 2.56 s | 2.88 s | 9.53 | 93.8 | 179x | **Recommended default** — near-`offline` quality at conversational latency | 2.88 s latency; not for live captions |
| `c128-split-w8a8` | **95 MB** | 10.24 s | 10.56 s | 9.63 | **100.0** | 364x | Half size, 100% ANE, counting intact — the batch/iOS pick | Split mode needs host pre-encode (FluidAudio handles it) |
| `low` | 190 MB | 0.72 s | 1.04 s | 9.75 | 75.0 | 31x | Lowest latency with the large FIFO; the card's streaming config | Heaviest per second of audio; weaker speaker counting |
| `fast32-split-w8a8` | **95 MB** | 2.56 s | 2.88 s | 9.76 | 75.0 | 185x | Half size at conversational latency | Speaker counting drops 18.8 pts vs fp16 `fast32` — see note |
| `fast` | 190 MB | 0.72 s | 1.04 s | 10.07 | 68.8 | 44x | ~1.4x cheaper than `low` at the same latency | Worst DER and counting of the set |

¹ AMI MHM test, 16 meetings, forced-alignment references
([nttcslab-sp/diar-forced-alignment](https://github.com/nttcslab-sp/diar-forced-alignment)),
collar 0, overlap included — the protocol NVIDIA's card uses. SCA = speaker-counting
accuracy (fraction of meetings whose speaker count is exactly right). NVIDIA's published
AMI MHM numbers under this protocol: 9.25 DER / 87.5 SCA offline, 9.48 / 81.25 at 1.04 s.
Wall RTFx is single-stream on an M5 Pro MacBook, ANE route for the split builds.

> **Window size drives speaker counting, not quantization.** On the 10.24 s window the
> W8A8 build matches fp16 at 16/16 meetings for 0.27 DER. On the 2.56 s window it loses
> 18.8 points of counting accuracy. Short windows are the fragile ones in fp16 too —
> `low` and `fast` sit at 75.0 and 68.8 on a 0.72 s window. If speaker count matters more
> than latency, prefer a longer window.

## Presets

All presets share one checkpoint; they differ only in streaming shape. Latency =
(chunk + right-context) x 80 ms. `Packed T` is the transformer sequence length
(speaker cache + FIFO + window) and is what sets cost per call. DER/SCA: AMI MHM test,
16 meetings, forced-alignment references, collar 0.

### Monolithic (single model file, simplest integration)

| Preset | Chunk | RC | FIFO | Spk cache | Packed T | Latency | DER | SCA | Wall RTFx |
|---|---|---|---|---|---|---|---|---|---|
| `offline` | 340 | 40 | 40 | 264 | 684 | 30.40 s | 9.47 | 87.5 | **904x** |
| `fast128` | 128 | 4 | 40 | 264 | 436 | 10.56 s | **9.36** | **100.0** | 546x |
| `fast32` | 32 | 4 | 40 | 264 | 340 | 2.88 s | 9.53 | 93.8 | 179x |
| `low` | 9 | 4 | 264 | 264 | 541 | 1.04 s | 9.75 | 75.0 | 31x |
| `fast` | 9 | 4 | 40 | 264 | 317 | 1.04 s | 10.07 | 68.8 | 44x |

`low` and `fast` run the same 0.72 s window at the same latency; the only difference is
the FIFO (264 vs 40), which takes the sequence from 317 to 541. That buys `low` 0.32 DER
and 6.2 points of speaker counting, and costs roughly a third of the throughput.

Other configurations (sub-second latency tiers, intermediate chunk sizes, weight-only
int8) were built and benchmarked but are not published — they are dominated by the
presets above. Open an issue if you need one; regeneration is scripted.

### Split-graph (host pre-encode; 100% ANE-resident CoreML subgraph)

Feature stacking, the 1024->512 projection (`pre_encode_proj_t.bin`), state packing,
and masks run host-side; the model is the pure-fp transformer+head. FluidAudio handles
all of this via the `-split` presets.

| Preset | Packed T | Latency | DER | SCA | Wall RTFx | Weights |
|---|---|---|---|---|---|---|
| `c128-split-w8a8` | 436 | 10.56 s | 9.63 | **100.0** | 364x | **95 MB** |
| `fast32-split-w8a8` | 340 | 2.88 s | 9.76 | 75.0 | 185x | **95 MB** |

## Usage (FluidAudio, Swift)

```swift
import FluidAudio

let config = Nemotron3Config.fast32  // or .preset(named: "c128-split-w8a8")!
let models = try await Nemotron3Models.load(
    config: config,
    directory: modelsDirectoryURL  // this repo's files
)
let diarizer = Nemotron3Diarizer(config: config, models: models)

let (probs, frames) = try diarizer.processComplete(audioSamples)  // 16 kHz mono
let segments = Nemotron3Diarizer.segments(probabilities: probs, frameCount: frames)
// -> arrival-ordered speaker segments at 10 ms resolution, up to 8 speakers
```

Optional VAD gating for sparse audio (2x wall speedup at 55% speech density):

```swift
let (probs, frames) = try diarizer.processComplete(audioSamples, speechMask: mask)
```

## Files

- `monolithic/` — one `.mlmodelc` per preset (mel features in, predictions out)
- `monolithic/v2/` — same presets re-exported with fp16 inputs/outputs and gather-free state
  packing, so they compile for the ANE on M3-class chips ([FluidAudio #951](https://github.com/FluidInference/FluidAudio/issues/951));
  same checkpoint and weights, DER-neutral on AMI. FluidAudio v0.17.3+ loads these; the
  originals in `monolithic/` are kept for older releases.
- `split/` — W8A8 transformer graphs (`packed`/`attn_bias`/`output_mask` inputs)
- `learnable_sil_emb.bin` — learned silence embedding, 512 x fp32 (cache compression)
- `pre_encode_proj_t.bin` — FeatureStacking projection W^T, 1024x512 fp32 (split mode)

All models: fixed shapes, fp16 weights unless noted, `minimum_deployment_target` iOS 17 /
macOS 14. Conversion verified against the NeMo reference across four state configurations
per preset (cold start, half-full cache, steady state, partial final chunk): the export
wrapper is exact in torch (0.0), and the CoreML fp16 runtime stays within 1.9e-4 on
speaker predictions.

## Attribution & license

Converted from [nvidia/Nemotron-3-Diarization](https://huggingface.co/nvidia/Nemotron-3-Diarization)
(`Nemotron-3-Diarization.nemo`, sha256 `867c53f5…`), released by NVIDIA under the
OpenMDW License v1.1, which permits commercial use. The converted weights carry the
same licence.
Conversion pipeline, Swift runtime, and benchmarks by
[Fluid Inference](https://huggingface.co/FluidInference).

Reference: [Streaming Sortformer](https://arxiv.org/abs/2507.18446).

---
license: cc-by-4.0
base_model: FermionResearch/Phonon-2
base_model_relation: quantized
language: [en]
pipeline_tag: automatic-speech-recognition
tags: [coreml, parakeet, tdt, phonon, low-bit, sparse, speech-recognition, apple-silicon]
library_name: fluidaudio
---

# phonon-2-coreml

Core ML build of [FermionResearch/Phonon-2](https://huggingface.co/FermionResearch/Phonon-2), Fermion Research's
quantization-aware re-training of `nvidia/parakeet-tdt-0.6b-v3` for English, in which every encoder weight takes one of
five learned values per output row. Same tokenizer, 15 s window and `Decoder` / `JointDecisionv3` contract as
[parakeet-tdt-0.6b-v3-coreml](https://huggingface.co/FluidInference/parakeet-tdt-0.6b-v3-coreml); loaded in
[FluidAudio](https://github.com/FluidInference/FluidAudio) via `AsrModelVersion.phonon2`.

Every encoder here holds the checkpoint's **exact** five-value weights — as fp16 palettes (iOS 18 / macOS 15
`constexpr_lut_to_dense`), or as a sparsity mask plus a palette over the non-zero weights (`constexpr_lut_to_sparse` +
`constexpr_sparse_to_dense`). No re-quantization noise is added, and all five produce identical transcripts. The decoder
and joint are re-exported from the checkpoint's int6 tables; preprocessor and vocabulary are the v3 ones.

## Encoder ladder (`Encoder.mlmodelc`, since [#1019](https://github.com/FluidInference/FluidAudio/pull/1019))

`Encoder.mlmodelc` is a Core ML **multifunction** model: three encoder programs — `enc_5040ms`, `enc_10160ms`,
`enc_15000ms` (5.04 / 10.16 / 15 s windows, 63 / 126 / 188 encoder frames) — over one shared weight blob (341 MB for the
three). FluidAudio ≥ the #1019 merge loads every function and runs each window on the smallest one that holds it; older
FluidAudio versions load the default function (15 s) and behave as before. The three lengths are the Neural Engine's
64-frame tiles: 11–15 s windows all cost ~19 ms, 10 s costs 12 ms, 5 s about 6 ms, so a short clip stops paying for a
15 s pass and long recordings are cut at pauses with no overlap. Each function computes the same masked encoder;
transcripts do not change. First Neural Engine load compiles each function (~55 s each on an M5 Pro, cached after).

| | Encoder | 1 h Earnings-22 (M5 Pro) | LibriSpeech test-clean RTFx |
|---|---|---:|---:|
| FluidAudio with the ladder | `Encoder.mlmodelc` (341 MB) | **5.55 s / 649×, WER 16.7 %** | **193×** (WER 2.47 %) |
| previous default | `Encoder_sparse-g8.mlmodelc` (321 MB) | 7.5 s / 480×, WER 17.2 % | 155–159× (WER 2.47 %) |

An existing FluidAudio cache keeps the old file until the `phonon-2` model directory is deleted.

## Usage (FluidAudio, merged in [#980](https://github.com/FluidInference/FluidAudio/pull/980))

```swift
let models = try await AsrModels.downloadAndLoad(version: .phonon2)  // iOS 18+ / macOS 15+, downloads Encoder.mlmodelc
let asr = AsrManager()
try await asr.initialize(models: models)
let result = try await asr.transcribe(audioFileURL)
```

```bash
swift run fluidaudiocli transcribe audio.wav --model-version phonon2
swift run fluidaudiocli asr-benchmark --subset test-clean --model-version phonon2
```

To use another encoder file, download the model directory, rename the chosen `Encoder_*.mlmodelc` to `Encoder.mlmodelc`
and load it with `AsrModels.loadLocal(from:version: .phonon2, encoderComputeUnits:)`.

## Encoder files

One 15 s window on an M5 Pro (macOS 27); RTFx is FluidAudio `asr-benchmark` on full LibriSpeech test-clean with the
encoder on the Neural Engine. All five are exact and give the same transcripts.

| File | Size | Encoding | ANE | ANE RTFx | GPU |
|---|---:|---|---:|---:|---|
| **`Encoder.mlmodelc`** (default, ladder) | **341 MB** | sparse mask + 6-bit palette per 8 rows, 3 window lengths | **18.6 ms** (15 s) / 12 ms (10 s) / 6 ms (5 s) | **193×** | ~150 s load on every launch |
| `Encoder_sparse-g8.mlmodelc` (previous default, 15 s only) | 321 MB | sparse mask + 6-bit palette per 8 rows | 18.6 ms | 159× | 16 ms, but ~150 s load on every launch |
| `Encoder_sparse-g4.mlmodelc` | 246 MB | sparse mask + 4-bit palette per 4 rows | 24.3 ms | 140× | same load caveat |
| `Encoder_sparse-g1.mlmodelc` | 176 MB | sparse mask + 2-bit palette per row | 70 ms | ~70× | same load caveat |
| `Encoder_lut6.mlmodelc` | 470 MB | dense 6-bit palette per 8 rows | 18.6 ms | 155× | 16 ms, 0.6 s load |
| `Encoder_lut3.mlmodelc` | 253 MB | dense 3-bit palette per row | 72 ms | 70× | 16 ms, 0.7 s load |
| v3 `Encoder.mlmodelc` (6-bit, for reference) | 445 MB | — | 23.5 ms | 149–152× | 18 ms |

Two facts decide the choice. The Neural Engine's palette cost grows with the number of palettes, not their bit width,
so 8 rows per palette is faster than v3's own encoder while per-row palettes are 3× slower. And the GPU materializes
*sparse* weights at every load (~150 s of CPU, not cached), while the ANE compiles them once (~1 min) and caches. So:
Neural Engine (the FluidAudio default, and the only option for iOS background work) → `Encoder.mlmodelc`; GPU →
`Encoder_lut3.mlmodelc` (small) or `Encoder_lut6.mlmodelc` (fast everywhere); smallest possible → `Encoder_sparse-g1`.

Other files: `Decoder.mlmodelc` (RNNT prediction net, fp16, iOS 17+), `JointDecisionv3.mlmodelc` (single-step joint +
top-64, fp16, iOS 17+), `Preprocessor.mlmodelc` and `parakeet_vocab.json` (identical to v3), `NOTICE` / `LICENSE`
(upstream attribution, CC-BY-4.0).

## Accuracy vs parakeet-tdt-0.6b-v3

Full LibriSpeech, FluidAudio `asr-benchmark`, M5 Pro, both models run back to back with the default (ANE) encoder. WER is
corpus-level (total edit distance over total reference words); RTFx = total audio / total processing time.

| Set (ANE) | v3 | Ultra | Phonon-2 |
|---|---|---|---|
| test-clean (2620 files) WER | 2.27 % | **2.13 %** | 2.47 % |
| test-other (2939 files) WER | 4.12 % | **3.81 %** | 4.62 % |
| test-clean RTFx | 149–152× | 151× | **193×** ladder / 159× single-shape |
| test-other RTFx | 138× | 142× | **146×** |

v3 is the more accurate model on LibriSpeech by 0.20 / 0.50 points, reproducing the upstream card's own gap to its
teacher (+0.20 / +0.79 under the Open ASR Leaderboard protocol, where Phonon-2 in turn beats v3 on AMI meetings and
VoxPopuli). Phonon-2 is English only; v3 covers 25 languages. The absolute values are above the card's because
FluidAudio decodes in 15 s windows with a simpler normalizer, which both models pay equally.

Conversion fidelity: on the first 100 test-clean files the Core ML transcripts differ from a NeMo fp32 full-context
decode of the same checkpoint by 0.34 % WER (1.83 % vs 1.79 %).


## 60-minute long-form file (Earnings-22, four concatenated calls)

`transcribe` on the 3600 s `earnings22_top4_1h.wav` (M5 Pro, default ANE encoder, best of 2–3 runs, processing time
excludes model load). Reference = the concatenated Earnings-22 chunk transcripts, same normalizer.

| Model | Processing time | RTFx | WER |
|---|---:|---:|---:|
| v3 | 10.9 s | 331× | 16.5 % |
| Ultra | 7.7 s | 469× | **13.5 %** |
| Redux | 14.2 s | 254× | 14.8 % |
| **Phonon-2 ladder `Encoder.mlmodelc` (341 MB), pause-cut windows** | **5.55 s** | **649×** | 16.7 % |
| Phonon-2 `Encoder_sparse-g8` (321 MB, previous default) | 7.5 s | 478× | 17.2 % |
| Phonon-2 `Encoder_lut6` (470 MB) | 7.4 s | 486× | 17.2 % |
| Phonon-2 `Encoder_sparse-g4` (246 MB) | 9.0 s | 399× | 17.2 % |
| Phonon-2 `Encoder_sparse-g1` (176 MB) | 23.4 s | 154× | 17.2 % |
| Phonon-2 `Encoder_lut3` (253 MB) | 23.6 s | 152× | 17.2 % |

On conversational long-form audio Phonon-2 is the fastest model we ship (1.45× v3's throughput, on par with Ultra) but
the least accurate of the four: Ultra and Redux both beat v3 here while Phonon-2 trails it by 0.8 points, consistent
with the upstream card's Earnings-22 row (6.96 % vs its teacher's 5.85 %). All five Phonon-2 encoders produce the same
transcript.

## Licence and attribution

The weights are a derivative of NVIDIA's parakeet-tdt-0.6b-v3 re-trained by Fermion Research and are distributed under
CC-BY-4.0, as upstream. `NOTICE` reproduces Fermion Research's change list and training-data attribution. The encoders are
exact re-encodings of the upstream weights (grouped-channel palettes, or a sparsity mask plus palettes over the non-zeros);
the decoder and joint are the upstream int6 tables in fp16.

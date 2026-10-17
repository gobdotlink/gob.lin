---
license: other
license_name: openmdw-1.1
license_link: https://openmdw.ai/license/1-1/
base_model: nvidia/nemotron-3.5-asr-streaming-0.6b
library_name: fluidaudio
pipeline_tag: automatic-speech-recognition
tags:
- coreml
- apple-silicon
- ane
- streaming-asr
- rnnt
- on-device
language:
- en
- es
- fr
- it
- pt
- de
- zh
- ja
---

# Nemotron 3.5 ASR Streaming Multilingual 0.6B — CoreML


To grant access please join the server https://discord.gg/S6m4ET3pX and message Sisyphu

CoreML / Apple Neural Engine ships of
[nemotron-3.5-asr-streaming-0.6b](https://huggingface.co/nvidia/nemotron-3.5-asr-streaming-0.6b)
(Conformer encoder + RNN-T decoder), optimized for on-device streaming ASR
on Apple Silicon. Benchmarked on Apple M5 Pro / macOS 26.5.

> Built on the **2026-05-29** base-checkpoint update.

**Two models × 4 latency tiers = 8 bundles.**
- **`latin/`** — one Latin-script-pruned vocab (2828 tokens) shared by
  **en / es / fr / it / pt / de** (smaller, faster joint).
- **`multilingual/`** — the **full 13087-token vocab** covering every language,
  including **zh / ja** (and 100+ more via `prompt_id`).

Each at four chunk sizes — **0.56 s / 1 s / 2 s / 4 s** — trading latency for
throughput. Pick the folder by script; pass the exact language at inference
(`--language de-DE`). FluidAudio's downloader auto-routes the language to the
right folder. Per-language results are in the table below and in
[`manifest.json`](manifest.json).

## Ship matrix (per-file RTFx, single-stream batch=1)

RTFx = real-time factor (audio-seconds processed per wall-second; higher is
faster). **WER** for Latin-script languages, **CER for zh/ja** (no word
boundaries). **All numbers are FLEURS test, full splits** (see methodology).
The **Folder** column is which bundle serves that language — the en/es/fr/it/pt/de
rows are all the *same* `latin/` model measured per language; zh/ja and
Multilingual are the *same* `multilingual/` model.

| Language | Folder | Vocab | 0.56 s (560 ms) ‡ | 1 s (1120 ms) | **2 s (2240 ms)** ⭐ | 4 s (4480 ms) | Test set |
|---|---|--:|--:|--:|--:|--:|---|
| **English** | `latin` | 2828 | 58 (9.43%) | 103 (8.89%) | **130 (8.96%)** | 122 (9.02%) | FLEURS en_us |
| **Spanish** | `latin` | 2828 | 58 (4.95%) | 106 (4.76%) | **140 (4.80%)** | 136 (4.77%) | FLEURS es_419 |
| **French** | `latin` | 2828 | 57 (9.68%) | 105 (9.44%) | **130 (9.52%)** | 124 (9.42%) | FLEURS fr_fr |
| **Italian** | `latin` | 2828 | 59 (5.68%) | 109 (5.45%) | **147 (5.41%)** | 150 (5.40%) | FLEURS it_it |
| **Portuguese** | `latin` | 2828 | 59 (6.38%) | 108 (6.11%) | **141 (6.14%)** | 141 (6.18%) | FLEURS pt_br |
| **German** | `latin` | 2828 | 59 (10.83%) | 107 (9.78%) | **144 (9.83%)** | 142 (9.83%) | FLEURS de_de |
| **Chinese** | `multilingual` | 13087 | 22 (19.48% C) | 27 (18.75% C) | **89 (18.57% C)** | 90 (18.05% C) | FLEURS cmn_hans_cn |
| **Japanese** | `multilingual` | 13087 | 21 (14.61% C) | 26 (13.77% C) | **84 (13.79% C)** | 89 (13.82% C) | FLEURS ja_jp |
| **Multilingual** | `multilingual` | 13087 | 23 (9.15%) | 71 (8.64%) | **80 (8.76%)** | 78 (8.78%) | FLEURS en_us |

‡ **560 ms is the lowest-latency tier but off the trained attention tiling** —
lower throughput and a small quality cost vs 1120 ms. Use 1120 ms+ unless
sub-second latency is required.

> **Full-vocab models (zh / ja / multilingual) are tier-sensitive.** The
> 13087-vocab joint matmul only fits the ANE working-set efficiently at the
> **2 s** tier. At 560 ms the per-chunk joint overhead dominates and throughput
> collapses to ≈ 21–23 RTFx; **use the 2 s tier for zh/ja/multilingual**
> (zh/ja ≈ 84–90, multilingual-en ≈ 80). Throughput at 1 s depends on output
> density — sparse Latin text (multilingual-en ≈ 71 RTFx) fares far better than
> dense CJK (zh/ja ≈ 26), since CJK hits the big joint on more decode steps.
> The Latin-script ships (small joint) are fast at every tier.

### Which tier to use

- **2 s (2240 ms) is the recommended default for every model.** Latin-script
  ships run ≈ 130–150 RTFx; zh/ja/multilingual peak here at ≈ 84–90 RTFx.
  WER/CER is at or near its best, at 2.5 s latency.
- **1 s (1120 ms)** for lower latency (1.25 s) on the Latin-script ships at
  near-full quality (≈ 103–109 RTFx). Avoid for zh/ja/multilingual (≈ 26 RTFx).
- **0.56 s (560 ms)** only when sub-second latency is mandatory; off the trained
  tiling, so throughput and quality both dip. Not recommended for
  zh/ja/multilingual (≈ 21–22 RTFx).
- **4 s (4480 ms)** for offline/long-form. Within noise of 2 s for the
  Latin-script ships, so 2 s usually dominates.

## Recipe

All ships share: **LAYERPOS [42,13] mixed-precision encoder** (first/last 3
Conformer layers INT8, middle 18 layers 6-bit palettized — ~55% encoder size
cut vs FP16, WER-neutral) + **B1 decoder⊕joint fusion** + **triple-stage
pipelining**.

Vocab handling differs by script:
- **Latin-script languages (en/es/fr/it/pt/de)** share **one Latin-script-pruned
  joint** — the keep-set is derived from the **writing system** (all Latin +
  shared punctuation/digit tokens kept; CJK/Hangul/Cyrillic/Arabic/etc.
  dropped), **not from any test corpus**. 2828 tokens, ~5× smaller joint, no
  test-set overfit and no in-script OOV. One model file serves all six
  languages.
- **Chinese / Japanese / multilingual** keep the **full 13087-vocab joint** — no
  pruning, no OOV, full character coverage.

The encoder is **shared across all languages** (a multilingual encoder that
selects language via `prompt_id`) and is byte-identical across the Latin-script
and full-vocab ships at each tier — only the decode stack differs.

## Usage (FluidAudio)

Each `<model>/<tier>ms/` directory is a self-contained bundle. Pick the folder
by script (`latin` for en/es/fr/it/pt/de, `multilingual` for everything else)
and pass the exact language:

```bash
fluidaudiocli nemotron-multilingual-transcribe \
    --input audio.wav \
    --model-dir latin/2240ms \
    --language de-DE
```

The FluidAudio auto-downloader routes `--language` to the correct folder
automatically. Models are shipped as compiled `.mlmodelc` (immediate load on
Apple Silicon).

## Folder layout

```
<model>/<tier>ms/
  preprocessor.mlmodelc
  encoder.mlmodelc          # LAYERPOS [42,13], byte-identical across both models per tier
  decoder.mlmodelc
  joint.mlmodelc
  decoder_joint.mlmodelc    # B1 fusion (default decode path)
  metadata.json
  tokenizer.json
```
`<model>` ∈ {latin, multilingual}; `<tier>` ∈ {560, 1120, 2240, 4480}.
`latin` serves en/es/fr/it/pt/de (shared Latin-script vocab); `multilingual`
serves zh/ja and 100+ languages via `prompt_id` (full vocab). A top-level
[`manifest.json`](manifest.json) indexes both models, all tiers, and per-language
benchmark numbers.

### iOS 17

All `latin/` and `multilingual/` bundles target **iOS 17+ / macOS 14+**. The
encoder uses an iOS 17-compatible quantization (INT8 cuff via `affine_dequantize`
+ 6-bit palettized middle); the 6-bit middle is unchanged from the prior iOS 18
build. Speed and WER are identical to that iOS 18 build — verified on LibriSpeech
test-clean (M5 Pro, 2 s tier): **120 RTFx, 3.67% WER** for both targets.

## Notes

- **Latin-script ships are domain-general.** The vocab keep-set is defined by
  the Latin writing system, not derived from any evaluation corpus, so there is
  no test-set overfit and no out-of-vocabulary loss for any Latin-script text.
- **zh/ja use the full-vocab model** (no pruned keep-set), so they have no OOV
  limitation and cover the full character inventory — at the cost of throughput
  below the 2 s tier (use 2 s).
- The **multilingual** full-vocab model (13087) supports 100+ languages via
  `prompt_id` — use it when broad coverage matters more than per-language speed.

## Benchmark methodology

Apple M5 Pro, macOS 26.5, coremltools 9.0, CoreML iOS 17 target,
`.cpuAndNeuralEngine` routing. Single-stream, batch=1, per-file sum-aggregate
RTFx (matches the Open ASR Leaderboard convention). **All languages evaluated
on FLEURS test, full splits.** WER for Latin-script languages, CER for zh/ja,
via HuggingFace normalization. No inverse text normalization is applied, so
FLEURS' digit-bearing utterances inflate WER by ~1–2 pp relative to
number-normalized references; FLEURS is also multi-domain, so these numbers run
higher than LibriSpeech/MLS would for the same model.

## License & attribution

Derived from the base model
[nemotron-3.5-asr-streaming-0.6b](https://huggingface.co/nvidia/nemotron-3.5-asr-streaming-0.6b),
released by NVIDIA under the
[OpenMDW-1.1 License](https://openmdw.ai/license/1-1/) and marked ready for
commercial use. This CoreML port is a derivative of those weights and is
distributed under the same **OpenMDW-1.1** license; commercial use and
redistribution are permitted under its terms. Retain this attribution to
NVIDIA and the OpenMDW-1.1 notice when redistributing.

Weights are quantized/pruned post-training only — **no retraining, no
fine-tuning, no calibration-data fitting.**
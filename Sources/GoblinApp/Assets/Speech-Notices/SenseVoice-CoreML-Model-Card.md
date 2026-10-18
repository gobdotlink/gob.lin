---
license: other
license_name: sensevoice-upstream
license_link: https://github.com/FunAudioLLM/SenseVoice
language:
- zh
- en
- ja
- ko
- yue
library_name: coreml
tags:
- coreml
- ane
- speech-recognition
- sensevoice
- funasr
- fluidaudio
pipeline_tag: automatic-speech-recognition
base_model: FunAudioLLM/SenseVoiceSmall
---

# SenseVoiceSmall — CoreML (Apple Neural Engine)

CoreML conversion of [FunAudioLLM/SenseVoiceSmall](https://huggingface.co/FunAudioLLM/SenseVoiceSmall)
for on-device inference on Apple Silicon, intended for
[FluidInference/FluidAudio](https://github.com/FluidInference/FluidAudio)
(tracks issues #645 / #646).

SenseVoiceSmall is a **non-autoregressive** multilingual ASR model (~234M params,
SANM encoder + single CTC head) covering 50+ languages, with emotion and
audio-event tags. One forward pass yields all output tokens.

## Files (3-stage pipeline)

| File | Precision | Compute unit | Size | Role |
|------|-----------|--------------|------|------|
| `SenseVoicePreprocessor.mlmodelc` | FLOAT32 | CPU | 3 MB | front-end: waveform → 560-d LFR features |
| `SenseVoiceSmall.mlmodelc` | FLOAT16 | **`CPU_AND_NE` (ANE)** | 447 MB | **default** encoder+CTC |
| `SenseVoiceSmall_int8.mlmodelc` | INT8 (weights) | `CPU_AND_NE` (ANE) | 225 MB | ~half size, accuracy-neutral |
| `SenseVoiceSmall_fp32.mlmodelc` | FLOAT32 | any | 897 MB | encoder fallback (non-ANE) |
| `vocab.json` | — | — | — | 25055 SentencePiece tokens (array form) |

**int8** is post-training weight quantization (`linear_symmetric`), accuracy-neutral
vs fp16 on the full canonical sets: LibriSpeech test-clean WER 3.22→3.25% (2,620),
AISHELL-1 test CER 3.09→3.09% (7,176) — Δ +0.03 pp / 0.00 pp, 0 NaN on ANE, peak
RAM 0.54→0.32 GB. Pick it for ~half the on-disk/memory footprint.

Pipeline: `waveform → [Preprocessor, fp32/CPU] → features → [encoder+CTC, fp16/ANE] → logits → host greedy-CTC decode`.

> ⚠️ **Compute-unit requirement.** The FLOAT16 encoder is numerically correct on
> the **Neural Engine** but produces **NaN on the CPU/GPU fp16 path**. Load it
> with `MLModelConfiguration.computeUnits = .cpuAndNeuralEngine`. On hardware
> without ANE (or under ANE fallback), use `SenseVoiceSmall_fp32`. The
> preprocessor must run **fp32** (power-spectrum/log exceed fp16 range).

## I/O

**`SenseVoicePreprocessor`** — in: `waveform [1, N]` fp32 (16 kHz, scaled ×32768
like kaldi; flexible length). out: `features [1, T, 560]` fp32.

**`SenseVoiceSmall`** (encoder+CTC):

| name | shape | dtype | notes |
|------|-------|-------|-------|
| `speech` | `[1, T, 560]` | fp32 | preprocessor output; `T` ∈ enumerated buckets `[128,256,512,1024,1800]` (pad up) |
| `speech_lengths` | `[1]` | int32 | valid frame count (before padding) |
| `language` | `[1]` | int32 | embed index; `0` = auto |
| `textnorm` | `[1]` | int32 | `15` = no inverse text-norm (woitn), `14` = withitn |

**Output:** `ctc_logits` `[1, T+4, 25055]` — the 4 leading positions are the
language/emotion/event/itn query tokens; the rest are the transcript.

## Host pre/post-processing

**Pre:** handled by `SenseVoicePreprocessor` (kaldi fbank80 → LFR m=7,n=6 → CMVN,
matching FunASR `WavFrontend` to max|Δ|≈2e-5). Pad its output up to the smallest
encoder bucket ≥ `T`.

**Post (decode):** greedy CTC over `ctc_logits` → collapse repeats → drop blank
(id 0) → SentencePiece detokenize → strip `<|...|>` tags for the clean
transcript. Reference Python in the repo's `decode.py`.

`language`/`textnorm` are **embed indices**, mapped on the host:
```
lid_int_dict      = {24884:3, 24885:4, 24888:7, 24892:11, 24896:12, 24992:13}  # <|zh|> etc -> embed idx
textnorm_int_dict = {25016:14, 25017:15}
# language not in dict -> 0 (auto)
```

## Verification & benchmarks

Conversion = PyTorch (FunASR) → `torch.jit.trace` → coremltools (FLOAT16,
`EnumeratedShapes`, iOS17). Measured on this machine (M-series), FunASR 1.3.9 /
coremltools 8.3.

- **End-to-end correctness:** on the cached zh sample, the CoreML(ANE) →
  greedy-CTC pipeline reproduces FunASR `am.generate` **exactly**:
  `<|zh|><|NEUTRAL|><|Speech|><|woitn|>欢迎大家来体验达摩院推出的语音识别模型`
- **Parity (torch ↔ CoreML, ANE):** CTC argmax token agreement **100%** on real audio.
- **LibriSpeech test-clean (canonical — matches the official chart):** CoreML(ANE)
  **3.21% WER** (torch 3.26%) on n=100 vs the published SenseVoice-Small **~3.1%**.
  Confirms the full pipeline (front-end + CoreML + decode) reproduces the paper.
  (Full 2620-utt split number: see repo README.)
- **FLEURS WER (CoreML ANE vs torch), 100 samples/lang — conversion is accuracy-neutral:**

  | lang | torch | CoreML (ANE) | Δ | RTFx |
  |------|-------|--------------|---|------|
  | en_us (WER) | 9.52% | 9.52% | +0.00pp | 402 |
  | cmn_hans_cn (CER) | 9.60% | 9.57% | −0.03pp | 372 |

  > FLEURS is a harder/different read-speech set than LibriSpeech/Aishell — its
  > absolute numbers are not comparable to the official benchmark chart; it's
  > used here only for cross-language CoreML↔torch parity.

- **RTFx (5.55 s clip, by bucket, ANE):** 128→524, 256→274, 512→97, 1024→36, 1800→14.5.
  (M-series; iPhone ANE not yet measured.)

## License & attribution

Weights derive from [FunAudioLLM/SenseVoiceSmall](https://huggingface.co/FunAudioLLM/SenseVoiceSmall);
the upstream model license applies. This repo only contains a format conversion
(no retraining). See the [SenseVoice](https://github.com/FunAudioLLM/SenseVoice)
and [FunASR](https://github.com/modelscope/FunASR) projects.

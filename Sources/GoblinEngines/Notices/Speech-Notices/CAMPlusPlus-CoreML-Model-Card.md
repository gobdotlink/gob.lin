---
license: other
license_name: campplus-upstream
license_link: https://github.com/modelscope/FunASR
language: [zh]
library_name: coreml
tags: [coreml, ane, speaker-verification, speaker-diarization, campplus, funasr, fluidaudio]
pipeline_tag: audio-classification
---

# CAM++ — CoreML (Apple Neural Engine)

CoreML conversion of FunASR's **CAM++** speaker-embedding model (~7.2M params), for
on-device speaker verification / diarization on Apple Silicon. Upstream:
[iic/speech_campplus_sv_zh-cn_16k-common](https://www.modelscope.cn/models/iic/speech_campplus_sv_zh-cn_16k-common).

## Files

| File | Precision | Compute unit | Role |
|------|-----------|--------------|------|
| `CamPlusPreprocessor_v2.mlmodelc` | FP32 | CPU | waveform → 80-d Kaldi fbank (Povey window, log floor after the mel filterbank) |
| `CamPlusPlus_v2.mlmodelc` | FP32 | CPU / GPU | mean-normalized fbank → 192-d speaker embedding |
| `CamPlusPreprocessor.mlmodelc` | FP32 | CPU | v1, superseded by `_v2` (Hamming window); kept for older FluidAudio releases |
| `CamPlusPlus.mlmodelc` | FP16 | CPU / GPU | v1, superseded by `_v2` (see Changelog); kept for older FluidAudio releases |

## Pipeline

```
waveform → [CamPlusPreprocessor_v2 fp32/CPU] → fbank [1,T,80]
        → subtract the per-utterance mean (host)
        → [CamPlusPlus_v2 fp32/CPU+GPU] → embedding [1,192]  (L2-normalize, then cosine for verification/clustering)
```

Neither model normalizes the fbank: the host subtracts each mel band's mean over the utterance,
as 3D-Speaker and FunASR do (FluidAudio's `CampPlusEmbedder`). The 192-d embedding is used with
cosine similarity for speaker verification and diarization clustering.

## Benchmark — AMI speaker verification (v2)

413 single-speaker AMI Mix-Headset segments (3–8 s, 16 participants, 3–4 meetings each), cosine scoring:

| | v1 + host mean | v2 | PyTorch 3D-Speaker CAMPPlus |
|---|---|---|---|
| EER, within meeting (1,332 target trials) | 3.07% | 2.85% | 2.85% |
| EER, across meetings (4,079 target trials) | 3.48% | 3.55% | 3.55% |
| Cosine to PyTorch, 357 lengths 0.35–60 s | as low as −0.01 | 1.0000 | 1 |

## Benchmark — AISHELL-1 speaker verification (v1)

| Metric | Value |
|--------|-------|
| **EER** | **0.48%** (20 speakers, 6000 same / 6000 diff trials) |
| same-speaker cosine | 0.805 |
| different-speaker cosine | 0.256 |

AISHELL-1 (clean read Mandarin) is easier than the official CN-Celeb (~6-7%). CoreML↔torch embedding cosine 0.9997-0.99999.

## Changelog

| Date | Files | Change | Issue | Recipe | FluidAudio PR | HF commit |
|---|---|---|---|---|---|---|
| 2026-11-01 | `CamPlusPreprocessor_v2.mlmodelc`, `CamPlusPlus_v2.mlmodelc` | Kaldi Povey fbank with the log floor after the mel filterbank; each segment-pooling tail averaged over its own frames (v1 divided by 100); fp32 (v1's fp16 pointwise convs gave unrelated embeddings at some lengths, e.g. 17.9–20.4 s) | [FluidAudio #985](https://github.com/FluidInference/FluidAudio/issues/985) | model-lab `models/campplus-coreml-v2` | [#1099](https://github.com/FluidInference/FluidAudio/pull/1099) | [b7be41fc](https://huggingface.co/FluidInference/campplus-coreml/commit/b7be41fcf4bf7697d879ca71c687dc532854e8a2) |

## License

Weights derive from FunASR's CAM++; upstream license applies. Format conversion only.

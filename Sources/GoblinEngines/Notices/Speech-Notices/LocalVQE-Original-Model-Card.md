---
library_name: pytorch
tags:
  - audio-to-audio
  - speech-enhancement
  - acoustic-echo-cancellation
  - noise-suppression
  - ggml
license: apache-2.0
---

# LocalVQE

[![Open in Spaces](https://huggingface.co/datasets/huggingface/badges/resolve/main/open-in-hf-spaces-md.svg)](https://huggingface.co/spaces/LocalAI-io/LocalVQE-demo)
[![GitHub](https://img.shields.io/badge/GitHub-localai--org%2FLocalVQE-181717?logo=github)](https://github.com/localai-org/LocalVQE)
[![License: Apache 2.0](https://img.shields.io/badge/License-Apache_2.0-blue.svg)](https://www.apache.org/licenses/LICENSE-2.0)

**Local Voice Quality Enhancement** — compact neural models for acoustic echo
cancellation (AEC), noise suppression (NS), and dereverberation of 16 kHz
speech, running on commodity CPUs in real time. Causal and streaming
(256-sample hop, 16 ms latency).

- **Try it:** <https://huggingface.co/spaces/LocalAI-io/LocalVQE-demo>
- **Source, build system, tests:** <https://github.com/localai-org/LocalVQE>

This page hosts the published weights. Inference runs the GGML C++ engine on
the GGUF files directly (build instructions on GitHub).

**Authors:** Richard Palethorpe ([richiejp](https://github.com/richiejp)) and
Claude (Anthropic). LocalVQE is a streaming, CPU-tuned derivative of **DeepVQE**
([Indenbom et al., Interspeech 2023](https://arxiv.org/abs/2306.03177)).

## Models

Speed is per 16 ms hop on a Ryzen 9 7900 (Zen4), 4 threads; RT = realtime
factor (higher is faster than realtime).

| Version | Does | Params | Size (F32) | Speed | Pick it when |
|---|---|---:|---:|---|---|
| **v1.3** *(current)* | AEC + NS + dereverb | 4.8 M | ~19 MB | 3.2 ms · 5.0× RT | best joint quality, CPU budget available |
| **v1.2** | AEC + NS + dereverb | 1.3 M | ~5 MB | 1.7 ms · 8.9× RT | tight CPU / low-power devices |
| **v1.4-AEC** | echo only (keeps voice, noise, room) | 203 K | ~3 MB | 0.83 ms · 19× RT | NS is handled elsewhere, or you want the room kept |
| **v1.4-AEC 2.7K** | echo only, linear filter (no mask) | 2.7 K | ~17 KB | 0.36 ms · 44× RT | lightest echo canceller; echo isn't heavily reverberant |
| v1.1 / v1 | AEC + NS + dereverb | 1.3 M | ~5 MB | — | superseded by v1.2 |

- **Joint models (v1.2 / v1.3)** clean echo, noise, and reverb in one pass.
  v1.3 is wider and filters noise better; v1.2 is ~1/4 the per-hop cost.
- **v1.4-AEC** removes only the far-end echo and passes voice, room, and
  background through unchanged. It's a classical adaptive filter followed by a
  small neural mask. The **2.7K** build is that filter alone — cheaper and
  gentler, but it can't remove heavily reverberant echo the way the mask can.
- Every model needs a far-end **reference** signal (a loopback of what your
  speakers play) in addition to the mic.
- `bf16` GGUFs are ~12 % smaller with identical quality and speed; pick `f32`
  unless download size matters.

### Compact line — GTCRN-AEC (for lower-power CPUs)

A separate, much smaller second line of models for lower-power CPUs: a
~49 K-parameter **GTCRN-AEC** network — a distinct architecture based on
[GTCRN](https://github.com/Xiaobin-Rong/gtcrn) (Rong et al., ICASSP 2024) —
paired with the project's DSP echo-cancellation front-end. The GGUFs are
self-contained, so they run with the same single command as every other model.
Two variants share the architecture:

| Model | Does | Params |
|---|---|---:|
| **localvqe-pi-v1-49k** | AEC + NS + dereverb (full enhance) | 49 K |
| **localvqe-pi-aec-v1-49k** | echo only — keeps noise + room | 49 K |

Whole-clip real-time factor on the real ggml graph, benchmarked on a Raspberry
Pi 5 (one example of a low-power target; `test_gtcrn --bench`, Cortex-A76,
Ubuntu 24.04), parity-verified to the PyTorch reference within ~1e-6 on-device.
RTF is identical for both variants:

| Threads | 8 s clip | RTF | RT factor |
|--:|--:|--:|--:|
| 1 | 388 ms | 0.048 | ~21× |
| 2 | 219 ms | 0.027 | ~37× |
| 4 | 163 ms | 0.020 | ~49× |

That is ~0.78 ms per 16 ms hop single-threaded. Runs on any CPU; for single-board
ARM, cross-compile for aarch64 with `ggml/docker/Dockerfile.arm64` (docker buildx
+ qemu). `f16`/`q8` quantizations are published only if/when released.

## Files in this repository

| File | Size | Model |
|---|---|---|
| `localvqe-v1.4-aec-200K-f32.gguf` | 3 MB | v1.4-AEC (echo only) |
| `localvqe-v1.4-aec-200K-bf16.gguf` | 2.6 MB | v1.4-AEC, conv weights in BF16 |
| `localvqe-v1.4-aec-2.7K-f32.gguf` | 17 KB | v1.4-AEC front-end only (adaptive filter, no mask) |
| `localvqe-pi-v1-49k-f32.gguf` | 2.3 MB | Compact line — GTCRN-AEC full enhance (echo + NS + dereverb) |
| `localvqe-pi-aec-v1-49k-f32.gguf` | 2.3 MB | Compact line — GTCRN-AEC echo-only (keeps noise + room) |
| `localvqe-v1.3-4.8M-f32.gguf` | 19 MB | v1.3 joint — GGUF the engine loads |
| `localvqe-v1.3-4.8M.pt` | 55 MB | v1.3 joint — PyTorch checkpoint (research) |
| `localvqe-v1.2-1.3M-f32.gguf` | 5 MB | v1.2 joint — GGUF |
| `localvqe-v1.2-1.3M.pt` | 11 MB | v1.2 joint — PyTorch checkpoint |
| `localvqe-v1.1-1.3M-f32.gguf`, `localvqe-v1-1.3M-f32.gguf` | 5 MB | older releases |

v1.4-AEC is GGUF-only (no `.pt`). GGUF integrity is checked at load time against
a built-in SHA256 allowlist in the engine.

## Performance

Full 800-clip eval on the
[ICASSP 2022 AEC Challenge blind test set](https://github.com/microsoft/AEC-Challenge)
(real recordings). AECMOS echo / deg are 1–5 (higher = more echo removed /
cleaner speech); blind ERLE is `10·log10(E[mic²]/E[enh²])`, only meaningful on
far-end-only clips. Unprocessed-mic echo MOS is 2.67 / 2.56 / 1.90 / 2.13 / 5.00
across the five scenarios.

**v1.4-AEC** — keeps background noise and room by design, so its ERLE and
far-end DNSMOS are intentionally lower than the joint models (it isn't deleting
the ambience):

| Scenario | n | echo ↑ | deg ↑ | ERLE ↑ | OVRL |
|---|--:|--:|--:|--:|--:|
| doubletalk | 115 | 4.20 | 2.45 | — | 2.59 |
| doubletalk-with-movement | 185 | 4.19 | 2.45 | — | 2.55 |
| farend-singletalk | 107 | 3.80 | 4.99 | 14.6 dB | 1.37 |
| farend-singletalk-with-movement | 193 | 3.86 | 4.95 | 11.1 dB | 1.31 |
| nearend-singletalk | 200 | 4.99 | 3.99 | — | 3.08 |

**v1.4-AEC 2.7K** (front-end only) — matches or beats the full model's
perceptual far-end echo at 1/74 the parameters; the mask's extra work shows up
as higher ERLE above, not higher echo MOS:

| Scenario | n | echo ↑ | deg ↑ | ERLE ↑ | OVRL |
|---|--:|--:|--:|--:|--:|
| doubletalk | 115 | 4.00 | 2.79 | — | 2.46 |
| doubletalk-with-movement | 185 | 3.90 | 2.92 | — | 2.42 |
| farend-singletalk | 107 | 4.06 | 5.00 | 6.5 dB | 1.24 |
| farend-singletalk-with-movement | 193 | 4.05 | 4.97 | 3.9 dB | 1.22 |
| nearend-singletalk | 200 | 4.98 | 3.77 | — | 3.03 |

**v1.3** (joint) and **v1.2** (joint) — these also delete the background, so
their far-end ERLE is much higher and not comparable to v1.4-AEC's:

| Scenario | n | v1.3 echo / deg / ERLE / OVRL | v1.2 echo / deg / ERLE / OVRL |
|---|--:|---|---|
| doubletalk | 115 | 4.73 / 2.62 / 8.5 dB / 2.89 | 4.72 / 2.37 / 8.4 dB / 2.83 |
| doubletalk-with-movement | 185 | 4.67 / 2.43 / 8.3 dB / 2.85 | 4.65 / 2.30 / 8.1 dB / 2.79 |
| farend-singletalk | 107 | 3.69 / 4.83 / 50.9 dB / 1.94 | 3.78 / 4.91 / 45.7 dB / 1.80 |
| farend-singletalk-with-movement | 193 | 3.88 / 4.98 / 49.9 dB / 1.96 | 4.12 / 4.96 / 40.6 dB / 1.75 |
| nearend-singletalk | 200 | 5.00 / 4.18 / 2.4 dB / 3.17 | 5.00 / 4.16 / 2.1 dB / 3.17 |

### Latency

Per-hop p50 / RT factor on a Ryzen 9 7900 (Zen4). 16 kHz, 256-sample hop.

| Model | 1 thread | 4 threads | dGPU (RTX 5070 Ti, Vulkan) |
|---|---|---|---|
| v1.4-AEC (203 K) | 1.29 ms · 12.2× | 0.83 ms · 18.6× | run on CPU¹ |
| v1.4-AEC 2.7K | 0.36 ms · 44× (single-threaded) | — | run on CPU¹ |
| v1.3 (4.8 M) | 9.73 ms · 1.58× | 3.21 ms · 4.97× | 2.57 ms · 6.07× |
| v1.2 (1.3 M) | 4.28 ms · 3.72× | 1.65 ms · 8.90× | 1.96 ms · 7.85× |

¹ v1.4-AEC's adaptive front-end always runs on CPU and the neural stage is too
small for GPU offload to pay off. Four threads is the sweet spot on Zen4 for all
models; the library defaults to `min(4, available CPUs)`.

### Memory (CPU)

Working set the model adds on top of the ~7 MiB binary baseline:

| Model | Post-load delta | Peak RSS |
|---|--:|--:|
| v1.3 (4.8 M) | +24.4 MiB | 34.1 MiB |
| v1.2 (1.3 M) | +10.0 MiB | 19.6 MiB |
| v1.4-AEC (203 K) | +6.7 MiB | 17.0 MiB |

## Running inference

Download a GGUF (web UI, `huggingface-cli`, or `hf_hub_download`) and run the
GGML CLI — same command for every model, just swap the file:

```bash
./localvqe localvqe-v1.3-4.8M-f32.gguf --in-wav mic.wav ref.wav --out-wav out.wav
```

16 kHz mono PCM for both the mic and the far-end reference. Building the engine,
the C API (`liblocalvqe.so`), and the OBS Studio plugin are documented in the
[GitHub repository](https://github.com/localai-org/LocalVQE).

## PyTorch reference

`localvqe-v1.3-4.8M.pt` and `localvqe-v1.2-1.3M.pt` are the checkpoints used to
produce the GGUF exports — for verification, ablation, and research, not
end-user inference (use the GGML build). The model definition lives under
`pytorch/` in the [GitHub repo](https://github.com/localai-org/LocalVQE).

## Citing

Cite the repository via `CITATION.cff` at
<https://github.com/localai-org/LocalVQE> (GitHub's "Cite this repository"
button produces APA / BibTeX), and the upstream DeepVQE paper:

```bibtex
@inproceedings{indenbom2023deepvqe,
  title     = {DeepVQE: Real Time Deep Voice Quality Enhancement for Joint
               Acoustic Echo Cancellation, Noise Suppression and Dereverberation},
  author    = {Indenbom, Evgenii and Beltr{\'a}n, Nicolae-C{\u{a}}t{\u{a}}lin
               and Chernov, Mykola and Aichner, Robert},
  booktitle = {Interspeech}, year = {2023},
  doi       = {10.21437/Interspeech.2023-2176}
}
```

The compact GTCRN-AEC line is based on **GTCRN** — please also cite:

```bibtex
@inproceedings{rong2024gtcrn,
  title     = {GTCRN: A Speech Enhancement Model Requiring Ultralow
               Computational Resources},
  author    = {Rong, Xiaobin and Sun, Tianchi and Zhang, Xu and Hu, Yuxiang
               and Zhu, Changbao and Lu, Jing},
  booktitle = {ICASSP 2024 - 2024 IEEE International Conference on Acoustics,
               Speech and Signal Processing (ICASSP)},
  pages     = {971--975}, year = {2024},
  doi       = {10.1109/ICASSP48485.2024.10448310}
}
```

## Dataset attribution

Weights are trained on the
[ICASSP 2023 DNS Challenge](https://github.com/microsoft/DNS-Challenge)
(Microsoft, CC BY 4.0) and fine-tuned on the
[ICASSP 2022/2023 AEC Challenge](https://github.com/microsoft/AEC-Challenge).

## Safety

Training data was filtered by DNSMOS, which can misclassify distressed speech
(screaming, crying) as noise. LocalVQE may attenuate such signals and must not
be relied upon for emergency or safety-critical applications.

## License

Apache License 2.0.

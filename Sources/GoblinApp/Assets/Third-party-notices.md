# Third-party notices

This document lists bundled fonts, dependencies, and model attribution for gob.lin.

## Bundled brand fonts

- Workbench — Copyright 2021 The Workbench Project Authors; SIL Open Font License 1.1. [Source and licence](https://github.com/google/fonts/tree/main/ofl/workbench). See `Workbench-OFL.txt`.
- VT323 — Copyright 2011 The VT323 Project Authors; SIL Open Font License 1.1. [Source and licence](https://github.com/google/fonts/tree/main/ofl/vt323). See `VT323-OFL.txt`.

The original goblin sprites come from the owner's gob.lin brand kit. Only visual assets and fonts are reused from that kit.

## Speech runtime

- FluidAudio by FluidInference — exact version 0.17.7, Apache License 2.0. [Pinned source and licence](https://github.com/FluidInference/FluidAudio/tree/v0.17.7). Goblin uses its local Core ML ASR runtime; the optional NeMo binary/text-processing trait is disabled. The complete upstream licence and bundled third-party notices (including fastcluster) are retained in `FluidAudio-Notices/`, copied into the app bundle. Upstream source is unmodified.
- NVIDIA Parakeet TDT v3 — Creative Commons Attribution 4.0. [Model card and attribution](https://huggingface.co/nvidia/parakeet-tdt-0.6b-v3). Models must be downloaded at runtime, never committed. Goblin uses the [FluidInference Core ML conversion](https://huggingface.co/FluidInference/parakeet-tdt-0.6b-v3-coreml), with the int8 encoder, from NVIDIA's original model. We do not modify those downloaded components. Model weights are acquired separately and stay outside Git. The original and conversion model cards and complete [CC BY 4.0 licence](https://creativecommons.org/licenses/by/4.0/) are retained in the bundled `FluidAudio-Notices` assets.

- The optional CLI vocabulary diagnostic uses NVIDIA Parakeet TDT-CTC 110M through [FluidInference's CTC Core ML conversion](https://huggingface.co/FluidInference/parakeet-ctc-110m-coreml). It is separately downloaded only with `prepare-model --vocabulary-support`; this auxiliary CTC model is separate from the selectable TDT-CTC 110M transducer. The upstream metadata identifies CC BY 4.0 while the conversion card describes Apache 2.0. Both complete licence texts and original/conversion cards are retained with the app assets. Goblin does not modify the downloaded model components.


- WhisperKit (Argmax OSS Swift) — exact version 1.1.1, MIT. Only the WhisperKit library product is linked. Upstream code is unmodified. The complete MIT license and upstream third-party notices, including the Apache 2.0 notice for incorporated Hugging Face swift-transformers code, are retained in the bundled Speech-Notices assets. [Pinned SDK source](https://github.com/argmaxinc/argmax-oss-swift/tree/v1.1.1).
- OpenAI Whisper Tiny, Base, Small, Medium, their English-only variants, Large v3 Turbo and Large v3 — use the [Argmax Core ML conversions](https://huggingface.co/argmaxinc/whisperkit-coreml) under MIT and separately acquired [OpenAI tokenizers](https://huggingface.co/openai/whisper-large-v3) whose repository metadata identifies Apache 2.0. The complete MIT and Apache 2.0 texts and original/conversion model cards are retained in Speech-Notices. Models and tokenizers are downloaded at immutable revisions and are unmodified; no weights are committed or bundled.


- Parakeet Redux and Ultra by moondream — CC BY 4.0, derivatives of NVIDIA Parakeet v3. [Redux original](https://huggingface.co/moondream/parakeet-redux), [Ultra original](https://huggingface.co/moondream/parakeet-ultra). Uses unmodified [Redux](https://huggingface.co/FluidInference/parakeet-redux-coreml) and [Ultra](https://huggingface.co/FluidInference/parakeet-ultra-coreml) Core ML conversions by FluidInference. Original/conversion cards are retained in Speech-Notices; the full CC BY 4.0 text is in FluidAudio-Notices.
- Phonon-2 by Fermion Research — CC BY 4.0, an English retraining of NVIDIA Parakeet v3. [Original model](https://huggingface.co/FermionResearch/Phonon-2), [Core ML conversion](https://huggingface.co/FluidInference/phonon-2-coreml). The fixed `Encoder_sparse-g8.mlmodelc` bundle is placed locally at the SDK's `Encoder.mlmodelc` filename; its bytes are unmodified. The upstream LICENSE, NOTICE with training attribution, and both cards are retained in Speech-Notices.
- NVIDIA Parakeet TDT-CTC 110M — CC BY 4.0. The selectable English transducer uses [FluidInference's TDT Core ML conversion](https://huggingface.co/FluidInference/parakeet-tdt-ctc-110m-coreml); the separate vocabulary diagnostic uses the CTC conversion described above. The transducer conversion card is in Speech-Notices; original NVIDIA attribution and the full CC BY 4.0 text are in FluidAudio-Notices. Downloaded weights are unmodified.
- SenseVoice Small by FunAudioLLM / Alibaba — [FunASR Model Open Source License Agreement 1.1](https://github.com/modelscope/FunASR/blob/main/MODEL_LICENSE). Uses FluidInference's [INT8 Core ML conversion](https://huggingface.co/FluidInference/sensevoice-small-coreml) of [SenseVoiceSmall](https://huggingface.co/FunAudioLLM/SenseVoiceSmall), unmodified. The complete model license and original/conversion cards are retained in Speech-Notices.
- NVIDIA Nemotron 3.5 ASR Streaming 0.6B — [OpenMDW-1.1](https://openmdw.ai/license/1-1/). Uses FluidInference's [multilingual Core ML conversion](https://huggingface.co/FluidInference/Nemotron-3.5-ASR-Streaming-Multilingual-0.6b-CoreML) of [NVIDIA's original model](https://huggingface.co/nvidia/nemotron-3.5-asr-streaming-0.6b), unmodified. The complete OpenMDW-1.1 text and original/conversion cards are retained in Speech-Notices.

## Updates

The GitHub Releases updater uses Foundation, Security and macOS system utilities.
No third-party updater framework or model weights are bundled.

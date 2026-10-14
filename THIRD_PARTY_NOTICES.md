# Third-party notices

This document lists bundled fonts, dependencies, and model attribution for gob.lin.

## Bundled brand fonts

- Workbench — Copyright 2021 The Workbench Project Authors; SIL Open Font License 1.1. [Source and licence](https://github.com/google/fonts/tree/main/ofl/workbench). See `Sources/GoblinApp/Assets/Workbench-OFL.txt`.
- VT323 — Copyright 2011 The VT323 Project Authors; SIL Open Font License 1.1. [Source and licence](https://github.com/google/fonts/tree/main/ofl/vt323). See `Sources/GoblinApp/Assets/VT323-OFL.txt`.

The original goblin sprites come from the owner's gob.lin brand kit. Only visual assets and fonts are reused from that kit.

## Speech runtime

- FluidAudio by FluidInference — exact version 0.17.7, Apache License 2.0. [Pinned source and licence](https://github.com/FluidInference/FluidAudio/tree/v0.17.7). Goblin uses its local Core ML ASR runtime; the optional NeMo binary/text-processing trait is disabled. The complete upstream licence and bundled third-party notices (including fastcluster) are retained in `Sources/GoblinApp/Assets/FluidAudio-Notices/`, copied into the app bundle. Upstream source is unmodified.
- NVIDIA Parakeet TDT v3 — Creative Commons Attribution 4.0. [Model card and attribution](https://huggingface.co/nvidia/parakeet-tdt-0.6b-v3). Models must be downloaded at runtime, never committed. Goblin uses the [FluidInference Core ML conversion](https://huggingface.co/FluidInference/parakeet-tdt-0.6b-v3-coreml), with the int8 encoder, from NVIDIA's original model. We do not modify those downloaded components. Model weights are acquired separately and stay outside Git. The original and conversion model cards and complete [CC BY 4.0 licence](https://creativecommons.org/licenses/by/4.0/) are retained in the bundled `FluidAudio-Notices` assets.

- The optional CLI vocabulary diagnostic uses NVIDIA Parakeet TDT-CTC 110M through [FluidInference's CTC Core ML conversion](https://huggingface.co/FluidInference/parakeet-ctc-110m-coreml). It is separately downloaded only with `prepare-model --vocabulary-support`; the app does not expose it as another selectable recognizer. The upstream metadata identifies CC BY 4.0 while the conversion card describes Apache 2.0. Both complete licence texts and original/conversion cards are retained with the app assets. Goblin does not modify the downloaded model components.

## Updates

The GitHub Releases updater uses Foundation, Security and macOS system utilities.
No third-party updater framework or model weights are bundled.

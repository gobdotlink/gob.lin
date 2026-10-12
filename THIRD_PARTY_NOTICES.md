# Third-party notices

This file records gob.lin's third-party dependency and asset notices.

## Bundled brand fonts

- Workbench — Copyright 2021 The Workbench Project Authors; SIL Open Font License 1.1. [Source and licence](https://github.com/google/fonts/tree/main/ofl/workbench). See `Licenses/Workbench-OFL.txt`.
- VT323 — Copyright 2011 The VT323 Project Authors; SIL Open Font License 1.1. [Source and licence](https://github.com/google/fonts/tree/main/ofl/vt323). See `Licenses/VT323-OFL.txt`.

The original goblin sprites come from the owner's gob.lin brand kit. Only visual assets and fonts are reused from that kit.

## Planned dependencies (not currently bundled)

- FluidAudio by FluidInference — Apache License 2.0. [Upstream licence](https://github.com/FluidInference/FluidAudio/blob/main/LICENSE). Selection and version pinning depend on the speech-engine benchmark.
- NVIDIA Parakeet TDT v3 — Creative Commons Attribution 4.0. [Model card and attribution](https://huggingface.co/nvidia/parakeet-tdt-0.6b-v3). Models must be downloaded at runtime, never committed. When this model ships, preserve its model card, identify NVIDIA as the source, link the [CC BY 4.0 licence](https://creativecommons.org/licenses/by/4.0/), and record any modifications or conversion.
- Sparkle — BSD-style licence with additional third-party notices in its [upstream licence](https://github.com/sparkle-project/Sparkle/blob/2.x/LICENSE). The update/distribution ticket is separate; retain the complete upstream licence for the version shipped.

Before adding one of these dependencies, replace its planned entry with the exact version, required copyright/attribution, and locally bundled licence text. No model weights, FluidAudio source, or Sparkle binaries ship in this benchmark-independent scaffold.

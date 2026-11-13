---
license: cc-by-4.0
language:
- en
metrics:
- wer
base_model:
- nvidia/parakeet-tdt_ctc-110m
pipeline_tag: automatic-speech-recognition
tags:
- automatic-speech-recognition
- speech
- audio
- Transducer
- TDT
- FastConformer
- Conformer
- pytorch
- NeMo
- hf-asr-leaderboard
---
# Parakeet-TDT-CTC 110M — CoreML

CoreML export of [nvidia/parakeet-tdt_ctc-110m](https://huggingface.co/nvidia/parakeet-tdt_ctc-110m) for on-device speech recognition on Apple Silicon via [FluidAudio](https://github.com/FluidInference/FluidAudio).


## CoreML Components

| File | Size | Description |
|------|------|-------------|
| `Preprocessor.mlmodelc` | 207 MB | Fused mel-spectrogram + FastConformer encoder |
| `Decoder.mlmodelc` | 7.5 MB | 1-layer LSTM prediction network |
| `JointDecision.mlmodelc` | 2.7 MB | Single-step joint network (token + duration) |
| `parakeet_vocab.json` | 18 KB | 1024-token BPE vocabulary |
| `config.json` | 2.5 KB | Model metadata and I/O contracts |

**Input:** 16 kHz mono audio, fixed 15-second window (240,000 samples).
**Output:** Token IDs, probabilities, and TDT duration predictions per encoder frame.

## Performance

Benchmarked with FluidAudio CLI on Apple M2 (release build):

| Benchmark | WER |
|-----------|-----|
| LibriSpeech test-clean | **3.0%** |
| RTFx (overall) | **102x** real-time |
| Peak memory | 0.3 GB |

NVIDIA's reference WER (greedy, GPU):

| Benchmark | WER |
|-----------|-----|
| LibriSpeech test-clean | 2.4% |
| LibriSpeech test-other | 5.2% |
| AMI | 15.88% |
| Earnings-22 | 12.42% |
| GigaSpeech | 10.52% |
| TEDLIUM-v3 | 4.16% |

## Usage with FluidAudio

```bash
# Transcribe
fluidaudiocli transcribe audio.wav --model-version tdt-ctc-110m

# Benchmark
fluidaudiocli asr-benchmark --subset test-clean --model-version tdt-ctc-110m
```

Models auto-download from this repo on first use. To pre-fetch:

```bash
fluidaudiocli download --model-version tdt-ctc-110m
```

## Conversion

Exported from NeMo using [mobius/models/stt/parakeet-tdt-ctc-110m/coreml/convert-tdt-coreml.py](https://github.com/FluidInference/mobius):

- Preprocessor fuses mel-spectrogram extraction and the FastConformer encoder into a single CoreML model
- JointDecision is the single-step variant (encoder_step + decoder_step inputs) used by FluidAudio's TDT decoder
- All models exported as MLProgram (iOS 17+ / macOS 14+), float32 precision

## References

- [Fast Conformer with Linearly Scalable Attention](https://arxiv.org/abs/2305.05084)
- [Efficient Sequence Transduction by Jointly Predicting Tokens and Durations](https://arxiv.org/abs/2304.06795)
- [NVIDIA NeMo](https://github.com/NVIDIA/NeMo)
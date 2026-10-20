# Speech models

The app ships 17 local model choices, with four recommended choices for common needs. Settings opens the recommendation shortlist; **All Models** exposes the complete catalog. Search and the **Supports Language** filter stay visible on both tabs and preserve their values. Filtering changes the visible choices without switching the selected model or dictation language. Each stable row shows its tradeoff, download size, language coverage and whether text appears while speaking or after recording. Language counts open searchable lists of the actual supported languages. Only **Use Model** or **Download & Use** starts a switch; readiness, download progress and Cancel share the row’s action area without expanding it. Download sizes come from the pinned file manifests, including tokenizers; a shared 1.1 MB speech detector is acquired separately.

| Model | Download | Role | Recognition language | Live preview | Recommended |
| --- | --- | --- | --- | --- | --- |
| Parakeet TDT v3 | 483 MB | Everyday default | Automatic or script hint, 25 languages | Yes | Yes |
| Whisper Tiny | 81 MB | Compact multilingual | Automatic or explicit, 99 languages | Yes | Yes |
| Whisper Large v3 Turbo | 631 MB | Compressed broad-language option | Automatic or explicit, 100 languages | Yes | Yes |
| Whisper Large v3 | 3.09 GB | Full-size multilingual | Automatic or explicit, 100 languages | Yes | Yes |
| Parakeet Redux | 220 MB | Compact ternary retraining | Automatic or script hint, 25 languages | Yes | |
| Parakeet Ultra | 632 MB | Post-trained Parakeet derivative | Automatic or script hint, 25 languages | Yes | |
| Phonon-2 | 358 MB | Compressed English retraining | Fixed English | Yes | |
| Parakeet TDT-CTC 110M | 227 MB | Small English transducer | Fixed English | Yes | |
| SenseVoice Small | 240 MB | Mandarin, Cantonese, English, Japanese, Korean | Automatic or hint, 5 languages | No | |
| Nemotron 3.5 | 664 MB | Streaming-trained multilingual alternative | Automatic or hint, 28 languages | Yes | |
| Whisper Tiny (English) | 80 MB | Smallest English Whisper | Fixed English | Yes | |
| Whisper Base | 151 MB | Intermediate multilingual size | Automatic or explicit, 99 languages | Yes | |
| Whisper Base (English) | 150 MB | Intermediate English size | Fixed English | Yes | |
| Whisper Small | 491 MB | Intermediate multilingual size | Automatic or explicit, 99 languages | Yes | |
| Whisper Small (English) | 490 MB | Intermediate English size | Fixed English | Yes | |
| Whisper Medium | 1.53 GB | Larger intermediate multilingual size | Automatic or explicit, 99 languages | Yes | |
| Whisper Medium (English) | 1.53 GB | Larger English size | Fixed English | Yes | |

Recommendations cover useful roles rather than a measured accuracy ranking on a user's recordings. Each catalog entry pairs with a real inference adapter and pinned acquisition manifest. Parakeet, SenseVoice and Nemotron use FluidAudio 0.17.7; Whisper uses the WhisperKit product from Argmax OSS Swift 1.1.1. The default Parakeet v3 retains its original int8 encoder. Phonon-2 uses the fixed 15-second `Encoder_sparse-g8` conversion, mapped locally to the SDK's `Encoder.mlmodelc` filename; it does not use a newer multifunction encoder path. SenseVoice uses INT8 on the Neural Engine. Nemotron uses the full-vocabulary 2240 ms conversion.

This catalog includes intermediate sizes, monolingual alternatives, newer retrained checkpoints and an Asian-language specialist. Older Whisper Large v1/v2 and redundant precision variants are omitted. Qwen3-ASR needs another inference runtime; the available Canary conversion is beta and does not report exhausted decoder output through its public API. They are not listed as selectable models. The app owns its bounded preview; persistent incremental streaming remains outside these adapters. Whisper supports native dictionary prompting with a visible whole-entry cutoff; see [Dictionary](dictionary.md).

## Download and cache

`SpeechRuntimeFactory` pairs the selected descriptor with its actual engine and `PinnedSpeechModelStore`. Files are stored under `Application Support/gob.lin/models/<model-cache-folder>`; the existing Parakeet folder remains `parakeet-tdt-0.6b-v3`. Models remain downloaded when another model is selected or runtime memory is unloaded.

The bundled `speech-model-assets.json` records every acquired file's upstream repository, immutable commit, destination, exact byte size and expected SHA-256. Acquisition downloads directly from FluidInference, Argmax and OpenAI on Hugging Face. Browsing the catalog and loading a complete cache need no network. There is no hosted catalog, download mirror or remote inference.

The Foundation downloader writes bounded chunks to a dedicated `.partial` file, resumes using byte ranges, safely restarts when a server ignores Range, limits response size, retries transient failures up to four attempts and times out inactive network requests after 60 seconds. Incomplete transfers that make less than 1 MiB of progress over 120 seconds also time out and retry from the saved bytes. Cancellation keeps received bytes. A complete partial is verified locally before promotion. Bad checksums are never installed. Zero-byte upstream assets are created locally. Compilation has no network watchdog or fixed timeout.

Every required file is checked against the upstream manifest on the first store use. Idle reloads reuse successful hash validation while checking file presence and size. A complete older cache can be adopted if its bytes match the pinned manifest; the previous local integrity inventory is not the trust source. Same-size corruption is detected on a fresh store/launch. Retry retains good files and partial transfers; Download again replaces the selected dedicated model cache and shared detector cache to repair damage.

## Switching and sessions

The saved model choice changes only after the candidate downloads, verifies and loads successfully. While it downloads, the loaded current model remains available for new recordings. After acquisition, switching stops new leases and waits for all active/queued dictations to finish. It then unloads the old runtime before loading the candidate, keeping only one large runtime resident. Load failure or cancellation restores the previous runtime and keeps its saved selection. A missing previous cache can still produce a visible restoration error.

Session leases capture model ID, effective recognition options and preview capability before capture starts. Retain every lease through capture, preview/final windows and original-file recovery, then release it exactly once after the last worker exits. Language and dictionary changes affect the next session; they cannot change an existing recording or its recovery request. File replay and the CLI use the same options boundary. The overlay follows successful model selection; history records the engine actually used.

Parakeet's preferred-language parameter filters Latin, Cyrillic or Greek decoder candidates. It cannot enforce English versus French or Russian versus Ukrainian. Automatic remains the default and best supports mixed-script speech. Multilingual Whisper offers automatic detection and explicit decoder language conditioning. Monolingual models show fixed English and accept the default CLI language without pretending to detect it.

Whisper initializes language capabilities from the loaded model and applies its pinned non-speech suppression settings during decoding. Speech-positive recordings of one second or less are decoded without the SDK's trailing clip margin; longer recordings retain the usual margin. Silence is rejected before recognition.

SenseVoice's language query accepts five declared languages. The SDK silently truncates audio beyond its feature limit, so the adapter transcribes bounded 30-second windows with two seconds of overlap. Conservative character overlap supports scripts without whitespace; unmatched tails and wholly repeated hypotheses remain intact, and silence resets merging. SenseVoice returns no timestamps, so finalization uses the original recording.

Nemotron resets its cache and language hint for every preview window or file request, retains state only within that request, and resets after success, error or cancellation. It processes long files in cancellable chunks and returns the SDK's actual token timings. The selector exposes the 28 base languages represented by NVIDIA's 32 transcription-ready/broad-coverage locales; adaptation-only languages and extra metadata prompts are excluded. Bare language codes resolve to exact exported prompt keys, including `nb-NO` for Norwegian Bokmål. Hints condition recognition without promising a hard language lock. See the [publisher's language tiers](https://huggingface.co/nvidia/nemotron-3.5-asr-streaming-0.6b).

Persisted language intent survives switching to an incompatible model. The effective value falls back to automatic detection where available, otherwise English (or the model's first supported language). Settings disclose the fallback without rewriting the user's preference. Matching handles region/script subtags, Norwegian `no`/`nb` and Filipino `tl`/`fil`. Speech recognition language is separate from app UI language and translation; these adapters transcribe in the original language.

Idle unloading defaults to 15 minutes and supports Never, 5, 15 and 60 minutes. Session leases and in-progress selection protect runtime memory. An idle unload drains before a subsequent preparation. Unload retains downloaded files. Settings show model tradeoffs, download size, supported languages, progress, cancellation and retry/repair. The dictation-language control is separate from catalog filters and readiness. Runtime and observed load durations are inside Model Details.

## CLI and validation

```
goblin models
goblin prepare-model --model whisper-tiny
goblin transcribe sample.wav --model whisper-tiny --language ja
goblin replay recordings --model whisper-large-v3-turbo --language auto
goblin transcribe sample.wav --model whisper-small-en
goblin transcribe sample.wav --model nemotron-3.5 --language ja
```

`goblin models` reports all 17 choices, a `recommended` flag for the shortlist and `customVocabulary` for integrated native dictionary support. `--model-dir` points to the exact cache folder for the chosen model. Recognition, replay and benchmarks load installed files only. `prepare-model` explicitly owns acquisition. The optional `--vocabulary-support`/`--vocabulary` diagnostic remains Parakeet TDT v3-only.

Mocked checks cover actual backend switching, acquisition/load failures, rollback, cancellation, shutdown, concurrent recordings during download, session drain, stale progress, preference persistence, per-session PCM/file options, aliases, recommendation/search/filter behavior, fixed languages, tokenizer variants and asset/runtime consistency. Focused adapter checks cover decoder-state shape, language query/prompt mapping, adaptation-only language exclusion and long-file tail preservation. Synthetic URLSession fixtures cover direct acquisition, range resume/restart, complete partials, checksum/size validation, cancellation and path boundaries. Builds and these checks do not establish new-model accuracy, Core ML compatibility on hardware, live-preview cadence, memory use or dictation latency. Those require explicit local runtime and signed-app acceptance with real recordings.

SDK and model licenses/attribution are bundled in app assets; see [third-party notices](../THIRD_PARTY_NOTICES.md). Weights and recordings stay outside Git.

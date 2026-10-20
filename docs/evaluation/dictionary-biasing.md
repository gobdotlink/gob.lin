# Dictionary biasing: Parakeet, Whisper and Moonshine

**Run:** 20 October 2026, local Apple Silicon, cached models, one engine per process, arms run serially.
**Data:** the GOB-14 128-clip synthetic set (64 original + 64 fresh; 64 name-bearing, 64 ordinary controls), with the
focused 16-term and historical 120-term glossaries. All audio is macOS text-to-speech. These are controlled comparisons,
not accuracy on natural human dictation.

## Results, all 128 clips

| Arm | Terms | Names (unbiased → biased) | Ordinary clips worsened | Words damaged | WER (unbiased → biased) | Median ms with dictionary |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| Parakeet TDT v3 + CTC correction, defaults | 16 | 34 → 62/64 | 16/64 | 28 | 5.41% → 3.44% | 147 |
| Parakeet TDT v3 + CTC correction, defaults | 120 | 34 → 61/64 | 48/64 | 96 | 5.41% → 10.24% | 190 |
| Parakeet TDT v3 + CTC correction, 0.90 gate | 16 or 120 | 34 → 50/64 | 0/64 | 0 | 5.41% → 2.26% | 147 / 189 |
| Whisper Large v3 Turbo, dictionary prompt | 16 | 45 → 62/64 | 2/64 † | 2 † | 3.44% → 0.98% | 1,171 |
| Whisper Large v3 Turbo, dictionary prompt | 120 ‡ | 45 → 48/64 | 0/64 | 0 | 3.44% → 2.95% | 1,642 |
| **Moonshine Medium Streaming, key terms, boost 3** | **16** | **38 → 60/64** | **0/64** | **0** | 5.41% → **1.67%** | **139** |
| Moonshine Medium Streaming, key terms, boost 3 | 120 | 38 → 53/64 | 0/64 | 1 § | 5.41% → 2.95% | 138 |
| Moonshine Medium Streaming, key terms, boost 2 (default) | 16 | 38 → 54/64 | 0/64 | 0 | 5.41% → 2.46% | 136 |
| Moonshine Small Streaming, key terms, boost 2 | 16 | 34 → 52/64 | 0/64 | 0 | 6.69% → 3.35% | 99 |

† Both are “five minutes” written as “5 minutes”: number formatting, not a misrecognition.
‡ Only 25 of the 120 terms fit Whisper's 111-token prompt; the rest are silently excluded (alphabetical whole entries).
§ “backup” written as “back-up” in a sentence where biasing also recovered “Postgres”. Its three lost names are “PNPM” written as “PN/PM”.

Unbiased times without a dictionary: Parakeet 40 ms, Moonshine Medium 137 ms, Moonshine Small 99 ms, Whisper Turbo 703 ms.
Parakeet's correction adds a second CTC model pass; Moonshine's biasing costs nothing measurable; Whisper's prompt adds
roughly 0.5–0.9 s. These are accelerated file replays, not key-up latency.

## Memory and download size

Peak process memory over the 64 original clips with 16 terms (`/usr/bin/time -l`), and model size on disk:

| Engine | Peak footprint | Peak RSS | On disk |
| --- | ---: | ---: | ---: |
| Parakeet TDT v3, no dictionary | 45 MB | 91 MB | 461 MB |
| Parakeet TDT v3 + CTC correction (16 or 120 terms) | 57 MB | 105 MB | 461 + 99 MB |
| Whisper Large v3 Turbo + prompt | 222 MB | 162 MB | 631 MB |
| Moonshine Small Streaming + key terms | 540 MB | 692 MB | 139 MB |
| Moonshine Medium Streaming + key terms | 858 MB | 1,128 MB | 267 MB |

Core ML weights are memory-mapped and partly held outside the process by the Neural Engine service, so the Parakeet and
Whisper figures undercount their system-wide cost. Moonshine runs ONNX Runtime on the CPU, so its weights and working
buffers are ordinary process memory: Medium holds about three times its download size.

## Method

- The Parakeet arms reproduce the GOB-14 handoff exactly on both splits (for example: defaults with 120 terms, 24/32
  ordinary worsened and 42 damaged on the original split; the 0.90 gate, 50/64 with zero damage), so the harness and
  scorer match the earlier measurements.
- Moonshine's boost was chosen on the **original split only** (boosts 1–4); boost 3 was frozen before the fresh split was
  scored. On the fresh split it scored 28/32 names with zero damage using 16 terms. Boost 4 was no better on 16 terms and
  lost more names with 120.
- Moonshine streaming models look ahead, so the adapter appends 500 ms of silence. Without it, abrupt synthetic clip
  endings lost or garbled the last word (“post” for “post hog”, “home” for “lunch”).
- Whisper ran with `--language en`; Parakeet with automatic language, as in the handoff; Moonshine is English-only.
- Metrics follow the handoff: complete target spelling ignoring case and punctuation; ordinary clips whose word-error
  count increased; previously correct non-target reference words that became wrong anywhere; literal WER.

## Follow-up probe: spoken model names and numbers

Six sentences × two voices (Samantha, Daniel), glossary `GPT-6.1 Sol`, `GPT-6.1 Luna`:

- All three engines wrote “GPT 6.1” as digits without help. Parakeet's CTC correction and Moonshine's key terms both
  fixed the homophone (“sold”, “sole”, “solve” → “Sol”); Whisper heard “SOL” unbiased.
- **Moonshine invented text** after “The interest rate rose to 6.1%”: “GDP growth rose to 1.1”, “The 10-year yield
  rose 0.” It happened with and without key terms, and with 0, 250, 500 and 1,000 ms of trailing silence, so it is
  triggered by the content, not the padding. Parakeet and Whisper transcribed the sentence correctly. The 128-clip set
  never triggered this; runaway output is a failure mode that set does not cover.

## Improving Parakeet's correction

The default CTC correction recovers names but replaces correctly heard words (“lunch” → “Luna”, “manage” →
a product name). Each idea below was tuned on the **original split only**, frozen, then scored on clips it had not seen:
the fresh split (64 clips) and a new **holdout 2** set (128 clips: 32 new sentences — 16 names, 16 ordinary sentences
packed with near-collisions such as “lunch”, “manage”, “What's up”, “lease”, “typed safely” — read by Rishi, Tessa,
Reed and Flo). Holdout 2 was generated and hash-frozen before any of these rules was scored on it.

Unseen clips (fresh + holdout 2): 96 name clips, 96 ordinary clips. Names are unbiased → biased.

| Approach | 16 terms: names · ordinary worsened · words damaged | 120 terms | Median ms (16 / 120) |
| --- | --- | --- | ---: |
| CTC correction, defaults | 51 → 91/96 · 51/96 · 82 | 51 → 88/96 · 58/96 · 156 | 149 / 194 |
| CTC correction, 0.90 similarity gate | 51 → 71/96 · 0 · 0 | 51 → 71/96 · 0 · 0 | 148 / 193 |
| Text join only, no CTC model | 51 → 70/96 · 0 · 0 | 51 → 70/96 · 0 · 0 | 40 / 40 |
| **CTC + spelling guard** | **51 → 83/96 · 0 · 0** | **51 → 80/96 · 0 · 0** | 148 / 192 |
| CTC + confidence guard 0.8 (alone or with spelling) | 51 → 90/96 · 2/96 · 4 | 51 → 86/96 · 2/96 · 4 | 149 / 192 |
| FluidAudio main (CTC padding fix), any policy | identical accuracy to 0.17.7 | identical ± 2 clips | 143 / 147 |
| Decoder-time bias 4.5 (prototype) | 51 → 62/96 · 3/96 · 6 | 51 → 61/96 · 11/96 · 24 | 40 / 40 |
| Decoder-time bias 4.5 + text join | 51 → 75/96 · 3/96 · 6 | 51 → 74/96 · 11/96 · 24 | 41 / 40 |
| Whisper Turbo prompt (for comparison) | 53 → 84/96 · 4/96 · 11 | 53 → 58/96 · 2/96 · 11 | 1,170 / 1,639 |
| Moonshine Medium boost 3 (for comparison) | 48 → 75/96 · 3/96 · 12 | 48 → 63/96 · 9/96 · 35 | 147 / 149 |

- **Text join** rejoins two or three adjacent words whose letters equal a term (“post hog” → PostHog), never across
  punctuation, and only recases a single word to a term without punctuation. It needs no model and matches the 0.90
  gate almost exactly, which shows that gate was mostly re-spacing.
- **Spelling guard** keeps a CTC replacement only if it re-spaces a term or replaces a word the macOS spell checker does
  not know (“Kalican”, “postgas”); otherwise the recognized words are restored. Each replacement is judged on its own,
  so an unknown name next to “lunch” does not let “lunch” become “Luna”. It was the only rule with zero damage on
  every split and glossary, and it recovers 9–12 more names than the 0.90 gate.
- **Confidence guard** also allows replacing real words that Parakeet heard with confidence below 0.8 (“posters” for
  Postgres). It finds 7 more names, but some voices heard “manage” below 0.8, so “They manage to…” became “They Panorama
  to…”. Confidence alone cannot protect ordinary words.
- **FluidAudio main** (unreleased; includes the CTC padding fix `e05ab92`) changed no decisions on these clips but cut
  the 120-term correction from 194 to 147 ms.
- **Decoder-time bias** adds the Nemotron matcher's bonus to the TDT joint's top-64 candidates (prototype patch outside
  this repository). It was strong on the split it was tuned on (31/32) but weak on new voices, and it produced
  non-term errors (“pull” → “pool”, “fire crew” → “firecrew”). Not ready.
- On holdout 2, Moonshine and Whisper also showed collisions the original set did not test: “What's up” → WhatsApp and
  “lease” → Lisa (Moonshine), and number formatting (“three” → “3”) from Whisper.

The spelling guard depends on the spell checker's language and the user's learned words; a term the user has added to
the system dictionary counts as known. Multi-word real-word mishearings (“type save”, “post hoc”) remain unrecovered.

## Combined with AI cleanup (Qwen 3.8 on Cerebras)

`goblin rewrite-eval` sends the frozen Parakeet results above through the saved cleanup settings: Cerebras /
`qwen-3.8-27b`, light cleanup, reasoning off, temperature 0, casual tone. The glossary is the cleanup's
`preferred_spellings`, as in the app. Identical transcripts are sent once. The hint variant was chosen on the original
split only, then frozen.

Unseen clips (fresh + holdout 2), 96 name clips and 96 ordinary clips. No arm changed any ordinary sentence.

| Pipeline | 16 terms: names · words damaged · wrong term | 120 terms | Median cleanup ms (16 / 120) |
| --- | --- | --- | ---: |
| Parakeet, no dictionary, no cleanup | 51/96 · 0 · 0 | 51/96 · 0 · 0 | – |
| Parakeet + spelling guard + text join, no cleanup | 83/96 · 0 · 1 | 80/96 · 0 · 0 | – |
| Parakeet → Qwen, no terms | 53/96 · 0 · 0 | – | 209 |
| Parakeet → Qwen + terms (the app today) | 86/96 · 0 · 0 | 74/96 · 0 · 1 | 228 / 325 |
| **Parakeet + guard + join → Qwen + terms** | **92/96 · 0 · 1** | **85/96 · 0 · 0** | 234 / 330 |
| … + hints: rejected corrections below 0.8 confidence | 93/96 · 1 · 2 | 88/96 · 1 · 2 | 217 / 339 |
| … + hints: all rejected corrections (dropped on the original split) | 93/96 · 5 · – | 88/96 · 5 · – | 229 / 333 |

“Wrong term” counts clips where a different dictionary term appears; the name metric scores these as misses, not
damage. Examples: “postbaz” → PostHog (the guard passes it because “postbaz” is not a word), “post organ” →
OpenRouter and “Type save” → “TypeSafe Watcher” (from hints).

- Qwen alone, given only the 16 relevant terms, recovered 86/96 names without touching ordinary sentences. Its context
  judgement fixes real-word mishearings the spelling guard must reject, and it refused “lunch” → Luna and “manage” →
  Panorama.
- Qwen cannot hear: it never recovered “Calican”/“Halikan” → Kalikin, which the CTC correction does. The two stages are
  complementary, which is why the combination is best.
- A long list costs Qwen 12 names (86 → 74) and about 100 ms; the guarded combination loses 7 (92 → 85).
- Hints add 1–3 names but bring wrong-term substitutions. They are not worth enabling; the hint arms used a
  prototype prompt field that is not part of this repository.
- Two requests failed after three retries with HTTP 429 (rate limit). The app would paste the uncleaned text.

## What this does and does not establish

- On this set, Moonshine's decoder-time key terms recovered names without the false replacements that Parakeet's
  post-recognition CTC correction caused (“lunch” → “Luna”, “working” → “WorkOS”). Biasing during decoding changes what
  the model emits; it does not override a word the recognizer already got right.
- Whisper Turbo with 16 terms has the best name recall, at about eight times Moonshine's processing time.
- All engines do worse with 120 terms. Keeping the active list short and relevant, for example by scoping it to the
  current app or project, matters for every engine.
- Moonshine still missed acoustically distant names (“Kalikin” heard as “Halakin”/“Callahan”) and split “TypeSafe” into
  “Type save”. Its base WER is similar to Parakeet's here, but nothing here measures natural speech, accents, long
  dictation or live streaming.
- Moonshine is a CLI diagnostic only. Adopting it in the app needs a catalog entry, pinned model hashes, live-preview
  integration and natural-speech validation.

## Reproduce

```sh
scripts/run-dictionary-eval.sh <dataset-dir> <output-dir>     # prepare-model first; Moonshine arms pass --download
scripts/score-dictionary-eval.py --split original <output-dir>/*.jsonl
scripts/score-dictionary-eval.py --split fresh <output-dir>/*.jsonl
scripts/score-dictionary-eval.py --json <arm>.jsonl           # per-case damage details
goblin rewrite-eval <arm>.jsonl --glossary <terms> [--text-join]  # sends transcripts to the saved cleanup provider
```

`goblin dictionary-eval <manifest.json> --glossary <terms>` writes one configuration record and one paired
unbiased/biased record per clip. Glossary and manifest hashes, FLUID_* overrides, boost and padding are recorded.

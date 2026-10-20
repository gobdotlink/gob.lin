# Dictionary

`DictionaryRepository.applicationDefault` persists only user-authored entries in Application Support/gob.lin/dictionary.json. Load failures never overwrite the existing file. Changes are validated, then saved atomically. Plain-text import accepts one preferred spelling per line and ignores duplicate spellings.

`DictionaryCorrector.correct(_:entries:allowFuzzy:)` returns text and an audit list of corrections. Only explicitly authored aliases cause exact replacements. They match whole Unicode words and whitespace-separated phrases, never across punctuation. Existing preferred spellings are no-change lockouts before fuzzy matching; they do not implicitly capitalize ordinary prose such as “go”, “swift”, or “linear”. Overlapping aliases choose the longest phrase.

An all-caps input must contain at least one uppercase letter; caseless scripts keep the preferred spelling rather than shouting a Latin replacement. Explicit uppercase input stays uppercase. Mixed-case brand spellings such as `iPhone` stay intact. An alias at sentence start capitalizes the replacement's first letter only when the entire preferred spelling is lowercase (`npm` → `Npm`). Fuzzy edits otherwise preserve the input capitalization.

Code in inline backticks or fenced blocks, including whitespace and newlines, is protected before any matching. Conservative whitespace chunks containing URL/email/path/snake_case syntax, dotted/hyphenated/colon-separated identifiers, or camelCase are also protected. Leading/trailing sentence punctuation stays a normal word boundary. This deliberately favors leaving ambiguous code-like text unchanged and can skip correction inside hyphenated prose; it is not a full source-code parser.

Fuzzy correction defaults **off**. Its opt-in implementation permits a unique one-edit match only when the original input token and original preferred term each have five or more characters; case folding is used only for comparison, so a four-character `Groß` cannot qualify by expanding to `gross`. It protects a broad common-English vocabulary and preserves capitalization. A finite deny list cannot guarantee safety for every English word, so the production pipeline must retain the default until the real replay proves zero ordinary-word regressions. No Soundex, mined entries, or automatic learning are used.

All integrated Whisper models accept preferred spellings as native recognition hints. Other models do not receive a native dictionary; experimental acoustic correction remains disabled. Dictionary settings show the selected model's support separately from Cleanup use.

The pinned Whisper decoder accepts 111 prompt tokens. The shared planner uses that model's local tokenizer, includes comma separators, and fits whole preferred spellings in the alphabetical order shown in Dictionary. It stops at the first term that would overflow; neither a partial term nor later terms jump the cutoff. Settings show the included count, token usage, cutoff and excluded entries. Without a prepared tokenizer, settings ask to prepare the model instead of estimating a word limit. Recognition remains probabilistic: hints can help names and can also change ordinary words.

Each dictation snapshots its vocabulary with its model/language options before capture. Live windows, original-file recovery and history retranscription use those options without sharing mutable vocabulary between requests. Word alignment accounts for the prompt prefix, preserving timestamps for live merging. Empty dictionaries retain the unprompted decoding path.

Exact aliases continue to work for every model and every active entry. When Cleanup is enabled at a non-None level, its prompt receives the active preferred spellings, including those excluded from native recognition. Adding dictionary terms never enables Cleanup.

## App scopes

An entry can be limited to apps by bundle identifier (`apps`; empty means every app). Each dictation uses the entries for the app that was frontmost when it started, plus every unscoped entry. The same set drives native recognition, exact aliases and Cleanup's preferred spellings. Dictating while gob.lin itself is frontmost uses unscoped entries only. History records that app with each entry, separately from the app the text was delivered to, and rewrite and retranscription reuse it; entries saved before this fall back to their target app. A spelling or alias still belongs to one entry, which can list several apps.

Files without `apps` load as unscoped. A dictionary with no scoped entries is still saved as version 1 without the key, so earlier versions read it unchanged. Once any entry is scoped the file is saved as version 2: earlier versions report the dictionary as unavailable and leave the file intact rather than drop the scopes.

Settings choose apps from the open apps or any application bundle, show “Only in …” under scoped terms, and filter the list by app. The native capacity preview covers unscoped terms; app terms join them in their apps and share the limit. CLI `transcribe` and `replay` accept `--app <bundle-id>` to select the same set.

Why scope: in the [dictionary evaluation](evaluation/dictionary-biasing.md), Cleanup given the 16 relevant terms recovered 86/96 names on unseen clips against 74/96 with all 120 terms, and Parakeet's guarded correction lost names with the longer list too. Neither list changed ordinary sentences, so a wrong or missing scope costs recall rather than introducing errors.

![Scoped terms in Dictionary settings](evidence/gob-14/dictionary-scoped-light.png)

## Project scopes

Dictionaries layer: unscoped terms apply everywhere, app terms apply in their apps with no further setup, and an entry can also list `projects`. A project-scoped entry applies only when its app matches (or it has no apps) and the detected project matches one of its names. Names compare by their last path component, ignoring case and diacritics, so `gob.lin`, `akalikin/gob.lin` and a checkout path are the same project.

Detection runs only when some entry lists projects, and in the background from the start of dictation, so it never delays recording. Within a 1.5 s budget and node limits it reads, in order:

- the focused window's document (editors and some terminals): the name of the enclosing git repository;
- T3 Code: the thread in the page address, looked up read-only in `~/.t3/userdata/statev2.sqlite`; threads from remote environments fall back to the "New thread in <project>" button;
- Paseo: the workspace in the page address, looked up in `~/.paseo/projects`; workspaces on other hosts fall back to the one sidebar row styled differently from the rest. This fallback depends on Paseo's markup and gives no answer when the styling is ambiguous.

T3 Code and Paseo are Electron apps, so gob.lin sets `AXManualAccessibility` on them to read their page. Results are cached by document or page address, except Paseo's sidebar fallback. Aliases and Cleanup wait at most 0.3 s after speech ends for a result; without one, project terms are left out, so a missed detection costs recall rather than introducing wrong terms. Native recognition (Whisper's prompt) uses app-scoped terms only, because the project is not known when decoding starts.

History records the detected project with the app, and reprocessing reuses both. Settings add a Projects list to each term with suggestions from the last dictation, existing scopes and local T3 Code and Paseo projects, show the project under scoped terms, filter by project and report what the last dictation detected. CLI `transcribe` and `replay` accept `--project <name>` alongside `--app`. Files with project scopes are saved as version 3, because the app-scoped release reads version 2 but would ignore `projects` and widen those terms to every project; it reports a version 3 dictionary as unavailable and leaves the file intact.

Measured on one Mac with WindowProbe running the shipped detector: Zed file → repository in 7 ms, T3 Code thread → database in 7 ms (1 ms cached), remote Paseo workspace → sidebar in about 95 ms. Ghostty exposes no document, so terminals without one give no project.

![Project-scoped term in Dictionary settings](evidence/gob-14/dictionary-projects-light.png)

![Project scope editor](evidence/gob-14/dictionary-entry-projects.png)

CLI `transcribe` and audio `replay` use the default dictionary, or the JSON file selected with `--dictionary`. Supported models receive the same native prompt; `transcribe` reports included/excluded terms and token usage in `dictionaryUsage`. Recorded-transcript replay does not run recognition. Benchmarks retain their explicit diagnostic controls. `dictionary-eval` compares dictionary biasing across Parakeet CTC correction, Whisper prompting and a CLI-only Moonshine key-term diagnostic; see [Dictionary biasing evaluation](evaluation/dictionary-biasing.md).

Validation: `swift test` covers dictionary safety/storage. `scripts/check-models.sh` checks capacity boundaries, alphabetical ordering, backend gating, immutable session options and alignment offsets. Its `--dictionary-real <model-directory> <audio-file> [--model <id>] [--long-file <audio-file>]` mode checks installed Whisper file/PCM inference, word timing, tokenizer preview agreement, automatic language detection, silence and request isolation using supplied recordings. `--capture-dictionary <output-directory> <turbo-model-directory>` renders the production settings views offscreen, including app- and project-scoped terms. These checks do not establish accuracy on a user's real dictations.

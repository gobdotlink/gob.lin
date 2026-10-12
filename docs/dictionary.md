# Dictionary

`DictionaryRepository.applicationDefault` persists only user-authored entries in Application Support/gob.lin/dictionary.json. Load failures never overwrite the existing file. Changes are validated, then saved atomically. Plain-text import accepts one preferred spelling per line and ignores duplicate spellings.

`DictionaryCorrector.correct(_:entries:allowFuzzy:)` returns text and an audit list of corrections. Only explicitly authored aliases cause exact replacements. They match whole Unicode words and whitespace-separated phrases, never across punctuation. Existing preferred spellings are no-change lockouts before fuzzy matching; they do not implicitly capitalize ordinary prose such as “go”, “swift”, or “linear”. Overlapping aliases choose the longest phrase.

An all-caps input must contain at least one uppercase letter; caseless scripts keep the preferred spelling rather than shouting a Latin replacement. Explicit uppercase input stays uppercase. Mixed-case brand spellings such as `iPhone` stay intact. An alias at sentence start capitalizes the replacement's first letter only when the entire preferred spelling is lowercase (`npm` → `Npm`). Fuzzy edits otherwise preserve the input capitalization.

Code in inline backticks or fenced blocks, including whitespace and newlines, is protected before any matching. Conservative whitespace chunks containing URL/email/path/snake_case syntax, dotted/hyphenated/colon-separated identifiers, or camelCase are also protected. Leading/trailing sentence punctuation stays a normal word boundary. This deliberately favors leaving ambiguous code-like text unchanged and can skip correction inside hyphenated prose; it is not a full source-code parser.

Fuzzy correction defaults **off**. Its opt-in implementation permits a unique one-edit match only when the original input token and original preferred term each have five or more characters; case folding is used only for comparison, so a four-character `Groß` cannot qualify by expanding to `gross`. It protects a broad common-English vocabulary and preserves capitalization. A finite deny list cannot guarantee safety for every English word, so the production pipeline must retain the default until the real replay proves zero ordinary-word regressions. No Soundex, mined entries, or automatic learning are used.

Recognizer vocabulary biasing and the 250-recording jargon acceptance measurement remain blocked on engine selection and benchmark data. No benchmark claim is made here.

Validation: `swift test` runs four focused dictionary safety/storage tests. The app has a native Dictionary window with add/edit/delete, aliases, and text-file import.

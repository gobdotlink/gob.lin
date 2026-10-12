# Dictionary

`DictionaryRepository.applicationDefault` persists only user-authored entries in Application Support/gob.lin/dictionary.json. Load failures never overwrite the existing file. Changes are validated, then saved atomically. Plain-text import accepts one preferred spelling per line and ignores duplicate spellings.

`DictionaryCorrector.correct(_:entries:allowFuzzy:)` returns text and an audit list of corrections. Exact preferred spellings and aliases match whole Unicode words and whitespace-separated phrases. They never cross punctuation. Uppercase input stays uppercase; preferred name capitalization is retained for ordinary alias input. Overlapping aliases choose the longest phrase.

Fuzzy correction defaults **off**. Its opt-in implementation permits a unique one-edit match only for words of five or more letters, protects a broad common-English vocabulary, and preserves capitalization. A finite deny list cannot guarantee safety for every English word, so the production pipeline must retain the default until the real replay proves zero ordinary-word regressions. No Soundex, mined entries, or automatic learning are used.

Recognizer vocabulary biasing and the 250-recording jargon acceptance measurement remain blocked on engine selection and benchmark data. No benchmark claim is made here.

Validation: `swift test` runs four focused dictionary safety/storage tests. The app has a native Dictionary window with add/edit/delete, aliases, and text-file import.

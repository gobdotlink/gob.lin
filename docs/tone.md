# Tone

`DictationTone` has `formal`, `casual`, and `veryCasual`, a title, a preview, and a `promptInstruction` for optional rewriting. `ToneFormatter.format(_:tone:protectedTerms:)` is deterministic and operates without a provider. The native Tone window persists the global raw enum value in UserDefaults under `dictationTone`.

Formal capitalizes sentence starts and adds a missing final period. Casual uses sentence capitalization, commas instead of semicolons, and omits a final period. Very casual also lowercases ordinary sentence starts. Question marks, exclamation marks, and ellipses retain their meaning. Supplied names/dictionary terms, URLs, email addresses, code, acronyms, and camelCase text remain protected.

URL schemes are matched without case sensitivity; dotted abbreviations such as U.S., e.g. and p.m. retain their final dot. Formal may add a sentence period after a protected name, acronym, camelCase word or dictionary term, while code, URL and email endings block an added period.

Opening quotes and brackets allow ordinary sentence-start casing. Closing quotes and brackets are treated as the outer edge: Casual and Very casual may remove a preceding sentence period; Formal adds a missing period after the closing mark. Existing punctuation is never moved, so `"send it"` becomes `"Send it".` in Formal, while `"send it."` remains `"Send it."`. This deliberately chooses a period-outside style for newly added punctuation. A word after a mid-sentence abbreviation may still be capitalized (for example, U.S. economy); recognizing that context is outside this deterministic formatter's scope.

Unknown capitalized sentence starts remain intact because they may be names. This conservative behavior intentionally avoids guessing that a name should be lowercased. Tone selection is global; per-app categories remain outside this ticket.

Validation: one focused formatter safety test checks previews, punctuation, and protected data. Live dictation wiring belongs to the final pipeline integration while the recognizer is selected.

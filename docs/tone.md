# Tone

`DictationTone` has `formal`, `casual`, and `veryCasual`, a title, a preview, and a `promptInstruction` for optional rewriting. `ToneFormatter.format(_:tone:protectedTerms:)` is deterministic and operates without a provider. The native Tone window persists the global raw enum value in UserDefaults under `dictationTone`.

Formal capitalizes sentence starts and adds a missing final period. Casual uses sentence capitalization, commas instead of semicolons, and omits a final period. Very casual also lowercases ordinary sentence starts. Question marks, exclamation marks, and ellipses retain their meaning. Supplied names/dictionary terms, URLs, email addresses, code, acronyms, and camelCase text remain protected.

Unknown capitalized sentence starts remain intact because they may be names. This conservative behavior intentionally avoids guessing that a name should be lowercased. Tone selection is global; per-app categories remain outside this ticket.

Validation: one focused formatter safety test checks previews, punctuation, and protected data. Live dictation wiring belongs to the final pipeline integration while the recognizer is selected.

---
"swash": minor
---

Writing partner: context-aware spelling on this Mac (#98). When you finish a sentence, Apple's on-device model (macOS 26 with Apple Intelligence) reads that paragraph for misspellings the system spell checker leaves alone and real words used wrongly (form/from, their/there, loose/lose, then/than). Confident corrections play through the partner's cursor without moving your caret, each its own undo step, and undoing one tells the partner the word is right in this document. Less confident ones are only offered, as in Suggest mode, and the least confident are dropped. A word you use more than once in the document is treated as yours and left alone, and case-only changes are left to the Punctuate voice. `scripts/run_context_spelling_eval.sh` scores it on the strip-and-restore corpus with wrong words injected, on a Mac where the model is available.

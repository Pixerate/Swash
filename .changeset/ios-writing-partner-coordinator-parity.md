---
"swash": patch
---

Close iOS Writing Partner coordinator parity gaps with macOS: isolate partner undo steps via `breakUndoCoalescing()`, reuse cached `MarkdownDocument` parses in `StyledTextView` and `SourceTextView`, guard `SourceTextView` SwiftUI updates and structural edit offsets, and add iOS tests for `FormattingVoice`, `SourceTextView` parity, and undo isolation.

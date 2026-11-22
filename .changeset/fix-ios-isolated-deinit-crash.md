---
"swash": patch
---

Add `nonisolated deinit` to `MarkdownEditorStyler`, `BlockDecoration`, `IOSEditorController`, and `StyledTextView.Coordinator` to avoid Swift 6.2 `swift_task_deinitOnExecutorImpl` crashes on the iOS Simulator.

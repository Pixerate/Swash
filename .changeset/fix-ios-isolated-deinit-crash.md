---
"swash": patch
---

Fixes a crash on the iOS Simulator when the editor closed or restyled. Swift 6.2 ran the deinits of main-actor editor classes through `swift_task_deinitOnExecutorImpl`, which aborted. The styler, both editors' coordinators, the preview, the layout manager and the writing partner's classes now have `nonisolated deinit`.

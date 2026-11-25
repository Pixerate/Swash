---
"swash": patch
---

Fix NewDocumentSeed race condition by binding seeded text to the specific window and document identity instead of a global queue.

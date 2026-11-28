---
"swash": patch
---

Fix NewDocumentSeed race condition by binding seeded text to the specific window and document identity instead of a global queue. Seeds hold their document and window weakly, so a seed left unclaimed (its window closed, or its document gone) is dropped instead of landing in an unrelated later window.

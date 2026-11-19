---
"swash": patch
---

Share the on-device LanguageModelSession across pauses within the same document to use its session memory and cached context. The session is never shared between documents, is dropped when the document changes or the partner is paused, starts again after a few exchanges or when its context window fills (retrying that pause once), and is never asked to answer two pauses at once.

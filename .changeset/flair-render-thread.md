---
"swash": patch
---

iOS: the document manager's Flair wordmark and pixel speckles now draw on a render thread of their own, so they keep animating while the main thread is busy, such as while a document opens.

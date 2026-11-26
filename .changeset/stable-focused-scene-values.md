---
"swash": patch
---

Fix the iOS document screen sometimes staying blank, with the app stuck at high CPU, after creating or opening a document (most often on iPhone Duo). The Format and Distraction-Free menu commands were given a new closure on every redraw, which made `DocumentGroup` rebuild the document view in an endless loop. They now get closures made once per document view.

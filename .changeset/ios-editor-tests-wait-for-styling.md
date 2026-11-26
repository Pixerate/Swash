---
"swash": patch
---

Internal: the iOS editor tests wait for the editor's styling pass after each simulated keystroke instead of a fixed 0.15s, so they no longer fail on a slow CI simulator.

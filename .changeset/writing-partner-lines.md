---
"swash": patch
---

Writing partner fixes:
- Each line is now a sentence: a line starts with a capital, and Return at the end of a line of four or more words adds its full stop or question mark (no blank line needed).
- Return finishes a word, so the last word on a line is fixed too.
- Fast typing no longer skips fixes.
- macOS inline predictions are off while the writing partner is on, because together they could corrupt a word (`dont't`).
- "Fix punctuation as I type" is a switch.

Also:
- Sign-in no longer crashes, because PixerateAccount is updated to 0.1.1.
- The MCP bridge says how to start it when nothing is listening.

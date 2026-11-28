---
"swash": minor
---

Find and replace on iPhone and iPad (#271). The Source and Formatted editors have a find bar with Replace, reached from the More menu (Find, Find and Replace) or with ⌘F, ⌥⌘F, ⌘G and ⇧⌘G on a hardware keyboard. Replacing works like typing: the Formatted editor restyles what changed and Replace All is one undo step. In Formatted, matches that would cut through hidden formatting are left alone and counted, and matches inside tables and images are listed with a Show in Source button. Also fixes Swash's own edits (inserting a table, formatting) picking up smart punctuation after a text field with smart punctuation had the keyboard, which turned a table's `---` into `—`.

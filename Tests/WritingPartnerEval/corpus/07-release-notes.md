# Release Notes and Field Observations

We've spent the week refining the writing partner so it feels like a quiet second pair of hands rather than an intrusive autocorrect box. It's built around a simple promise: every change is its own undo step, and the partner backs off as soon as you undo a rule twice.

**Fast** local rules handle the everyday mechanics without touching the network. I don't need an account or an internet connection to get clean apostrophes, sentence capitals, and full stops at the end of a paragraph. When I pause, the optional bandleader tier can suggest structure, but it won't rewrite my prose behind my back.

Here's what changed in this build:

- Added clause commas before "but" when both sides form complete clauses
- Taught the contraction rule to distinguish possessive `its` from `it's` using lexical tags
- Enabled `I'd` and `I'll` when the tagger sees a pronoun and verb on the line
- Stopped inline predictive text from colliding with the partner's cursor

I tested the cursor playback on a long design doc, and it didn't drop a single keystroke while I kept typing ahead. That's critical because fast typists shouldn't have to wait for an animation to finish before starting the next line.

What happens if you're editing a poem or a set of short headings where full stops don't belong? Short lines under four words stay untouched, and you can turn off any rule in Settings if it doesn't fit your style. Give the new build a try today!

Everything works now.

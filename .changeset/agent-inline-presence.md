---
"swash": minor
---

Agent tools: an MCP agent's caret, selection and name tag now show inline in the macOS editor, and the text it changes is briefly tinted. The agent keeps its own insertion cursor (starting at yours), so its edits and `set_selection` no longer move your caret or selection, and your typing keeps the agent's cursor in place.

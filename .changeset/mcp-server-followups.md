---
"swash": patch
---

Embedded MCP server fixes: `tools/list` always lists every document tool, so agents that connect before a document is open (or while a read-only one is in front) can still edit; tool calls without a `document` go to the most recently active window instead of the last-opened one; write tools on a read-only document explain why they failed; and Copy MCP Config adds `"type": "http"`, which Claude Code needs.

---
"swash": patch
---

Embedded MCP server fixes: `tools/list` always lists every document tool, so agents that connect before a document is open (or while a read-only one is in front) can still edit; tool calls without a `document` go to the most recently active window instead of the last-opened one; write tools on a read-only document explain why they failed; and Copy MCP Config adds `"type": "http"`, which Claude Code needs.

Also: a listener that fails to start (port in use) is released and shows why, and changing settings retries it; Settings flags an out-of-range port; unknown paths return 404 before authentication and a bad token returns 401 with `WWW-Authenticate` (compared in constant time); and the server negotiates MCP 2025-06-18 and checks `MCP-Protocol-Version`.

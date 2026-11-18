---
"swash": patch
---

The embedded MCP server now comes from PixerateCore (editor 0.81.0), shared with other Pixerate apps, instead of Swash's own copy. Agents see the same tools and documents. The default port is now 4478, so it no longer clashes with `pixerate-mcp-bridge` on 4477. If you already turned the server on without choosing a port, Swash keeps 4477 so your copied MCP config still works. `list_documents` now also gives a read-only document's reason.

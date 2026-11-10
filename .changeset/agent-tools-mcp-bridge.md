---
"swash": minor
---

AI agents can now read and edit open documents on macOS through the Pixerate MCP bridge (`pixerate-mcp-bridge`), with the same tools as the Pixerate editor: `get_text`, `find_text`, `insert_text`, `replace_text`, `replace_range`, `replace_selection`, `set_selection`, `format_text` and `set_block_type`. Positions are offsets into the Markdown source, every change is one undo step, and read-only documents only offer the read tools. Turn it on in Settings › Agents (off by default), with the bridge's token; the tab shows the connection status.

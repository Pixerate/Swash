---
"swash": patch
---

Agent tools now read and format Slack documents as Slack mrkdwn: `format_text` writes `*bold*`, `_italic_`, `~strike~` and `<url|text>` links instead of GitHub Markdown, and `get_text`'s plain text, HTML and blocks parse Slack syntax. Also removes unreachable string-based formatting code from the Mac editor.

---
"swash": patch
---

Stop opening ordinary GitHub Markdown files as Slack mrkdwn. Flavour detection now counts syntax Slack never uses (`**bold**`, `__bold__`, `[text](url)` links, `#` headings, tables, fenced code with a language) against Slack's signals, ignores anything inside code, and gives the signals Markdown shares with Slack (`*text*`, `<https://…>`, `:emoji:`) less weight. Slack messages with `<url|text>` links, `<@user>` mentions or single-asterisk bold are still detected as Slack.

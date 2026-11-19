---
"swash": patch
---

Use PixerateMarkdown 0.82.0, which now provides the Confluence and Jira image paste conversion (`HTMLToMarkdown.convert(_:sourceURL:)`), `FormatCommandEdits.activeLink` and `MarkdownSyntax.url`, and drop Swash's local copies in `PixerateMarkdownExtensions.swift`. The paste checks now run against the package.

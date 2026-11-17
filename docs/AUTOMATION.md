# Automation: AppleScript & Shortcuts

Swash supports macOS AppleScript (`Swash.sdef`) and cross-platform Apple Shortcuts (`AppIntents`).

## AppleScript (macOS)

`NSAppleScriptEnabled` is enabled in [`Swash/Info.plist`](../Swash/Info.plist) with scripting dictionary [`Swash/Swash.sdef`](../Swash/Swash.sdef) (`Swash Suite`), implemented in [`Swash/SwashAppleScript.swift`](../Swash/SwashAppleScript.swift).

| Command | Parameters | Returns | Description |
| :--- | :--- | :--- | :--- |
| `create note` | `titled` (`text`, optional), `with content` (`text`, optional) | `text` (file path) | Creates and opens a new Markdown document in Swash. |
| `open quick note` | — | — | Opens Swash's Quick Note capture panel. |
| `count words` | direct parameter (`text`) | `text` | Returns `"<words> words, <chars> characters, <lines> lines"`. |
| `format markdown` | direct parameter (`text`), `as style` (`"code block"` \| `"quote block"` \| `"header"`, optional) | `text` | Formats plain text as a Markdown code block, quote block, or header. |

```applescript
tell application "Swash"
    create note titled "Meeting Notes" with content "# Agenda"
    open quick note
    set stats to count words "Hello Swash world"
    set md to format markdown "let x = 1" as style "code block"
end tell
```

## Shortcuts & AppIntents (macOS & iOS)

Defined in [`Swash/SwashAppIntents.swift`](../Swash/SwashAppIntents.swift) (`SwashShortcuts: AppShortcutsProvider`):

| Intent | Platform | Parameters | Returns | Siri Phrases |
| :--- | :--- | :--- | :--- | :--- |
| `CreateDocumentIntent` | macOS, iOS | `title: String` (default `"Untitled Note"`), `content: String` | Opens created document | `"Create a new document in Swash"`, `"New Swash note"` |
| `QuickNoteIntent` | macOS | — | — | `"Quick note in Swash"`, `"Jot something down in Swash"` |
| `GetWordCountIntent` | macOS, iOS | `text: String` | `String` (`"<words> words, <chars> characters, <lines> lines"`) | `"Count words with Swash"`, `"Get word count in Swash"` |
| `ConvertTextToMarkdownIntent` | macOS, iOS | `text: String`, `style: MarkdownWrapperStyle` (`.codeBlock`, `.quoteBlock`, `.header`) | `String` (formatted Markdown) | Available in Shortcuts |

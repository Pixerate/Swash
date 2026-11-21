# Automation: Shortcuts, Siri, Spotlight & AppleScript

Swash supports cross-platform Apple Shortcuts (`AppIntents`), Siri phrases, Spotlight entity indexing (`IndexedEntity`), Focus Filters (`SetFocusFilterIntent`), and macOS AppleScript (`Swash.sdef`).

---

## Shortcuts & App Intents (macOS, iOS & iPadOS)

Defined in [`Swash/SwashAppIntents.swift`](../Swash/SwashAppIntents.swift) (`SwashShortcuts: AppShortcutsProvider`). All non-UI actions run in the background without opening Swash (`openAppWhenRun = false`) and coordinate file writes via `NSFileCoordinator` so any open document window or folder workspace reloads automatically.

### `SwashDocumentEntity` (`AppEntity` & `IndexedEntity`)

Represents a Markdown file in Swash's `Documents` folder, iCloud Drive container, user-granted folders (`FolderAccessManager`), or recent documents.

| Property | Type | Description |
| :--- | :--- | :--- |
| `id` | `String` | Standardized file path. |
| `title` | `String` | Document name without its Markdown extension. |
| `folder` | `String` | Containing folder name or relative folder path. |
| `path` | `String` | Full filesystem path. |
| `modified` | `Date?` | Last modification timestamp. |
| `wordCount` | `Int` | Document word count (`MarkdownStatistics`). |

### Actions Catalogue

| Intent | Action Title | `openAppWhenRun` | Parameters | Returns |
| :--- | :--- | :--- | :--- | :--- |
| `CreateDocumentIntent` | **Create Markdown Document** | `true` | `title: String`, `content: String` | `SwashDocumentEntity` (and opens it) |
| `OpenDocumentIntent` | **Open Markdown Document** | `true` | `document: SwashDocumentEntity`, `focusMode: Bool?`, `typewriterScrolling: Bool?` | Opens document in Swash |
| `FindOrCreateDocumentIntent` | **Find or Create Markdown Document** | `false` | `pathOrTitle: String`, `initialContent: String`, `folder: IntentFile?` | `SwashDocumentEntity` |
| `CreateDocumentFromTemplateIntent` | **Create Document from Template** | `false` | `template: SwashDocumentTemplate` (`.dailyJournal`, `.meetingNotes`, `.inboxCapture`, `.projectPlan`, `.custom`), `title: String`, `customTemplate: String`, `variables: String`, `folder: IntentFile?` | `SwashDocumentEntity` |
| `GetDocumentContentsIntent` | **Get Document Contents** | `false` | `document: SwashDocumentEntity`, `format: SwashContentFormat` (`.markdown`, `.plainText`, `.html`, `.standaloneHTML`) | `String` |
| `AppendToDocumentIntent` | **Append or Prepend to Document** | `false` | `text: String`, `document: SwashDocumentEntity?`, `pathOrName: String`, `position: SwashInsertPosition` (`.end`, `.beginning`, `.underHeading`), `heading: String`, `style: SwashAppendStyle` (`.plain`, `.bullet`, `.todo`, `.timestampedBullet`, `.timestampedTodo`), `createIfMissing: Bool` | `SwashDocumentEntity` |
| `FindDocumentsIntent` | **Find Markdown Documents** | `false` | `query: String`, `scope: SwashSearchScope` (`.nameAndContent`, `.nameOnly`, `.contentOnly`), `folder: IntentFile?`, `limit: Int` | `[SwashDocumentEntity]` |
| `ConvertHTMLToMarkdownIntent` | **Convert HTML to Markdown** | `false` | `html: String`, `sourceURL: URL?`, `includeSourceLink: Bool` | `String` (Markdown) |
| `ConvertMarkdownIntent` | **Convert Markdown to HTML or Plain Text** | `false` | `markdown: String`, `format: SwashContentFormat`, `flavor: SwashMarkdownFlavorOption` | `String` |
| `ChangeMarkdownFlavorIntent` | **Convert Markdown Flavor** | `false` | `markdown: String`, `sourceFlavor: SwashMarkdownFlavorOption?`, `targetFlavor: SwashMarkdownFlavorOption` | `String` |
| `ExportPDFIntent` | **Export Document as PDF** | `false` | `document: SwashDocumentEntity?`, `markdown: String`, `title: String` | `IntentFile` (`application/pdf`) |
| `GetTodosIntent` | **Get To-Dos from Markdown** | `false` | `document: SwashDocumentEntity?`, `folder: IntentFile?`, `status: SwashTodoStatusFilter` (`.open`, `.completed`, `.all`) | `[String]` |
| `GetDocumentOutlineIntent` | **Get Document Outline** | `false` | `document: SwashDocumentEntity?`, `markdown: String` | `[String]` |
| `GetWordCountIntent` | **Get Word & Character Count** | `false` | `text: String`, `document: SwashDocumentEntity?` | `String` (`"<words> words, <chars> characters, <lines> lines"`) |
| `GetDocumentStatisticsIntent` | **Get Document Statistics** | `false` | `document: SwashDocumentEntity?`, `folder: IntentFile?`, `text: String` | `Int` (word count) |
| `ConvertTextToMarkdownIntent` | **Convert Text to Markdown Format** | `false` | `text: String`, `style: MarkdownWrapperStyle` (`.codeBlock`, `.quoteBlock`, `.header`) | `String` |
| `SetWritingModeIntent` | **Set Writing Mode** | `false` | `focusMode: Bool`, `focusUnit: SwashFocusUnitOption`, `typewriterScrolling: Bool` | Configures editor defaults |
| `SwashFocusFilterIntent` | **Swash Writing Focus** (`SetFocusFilterIntent`) | `false` | `focusMode: Bool`, `focusUnit: SwashFocusUnitOption`, `typewriterScrolling: Bool` | System Focus Filter |
| `QuickNoteIntent` | **Quick Note** (macOS) | `true` | — | Opens Quick Note panel |

---

## Sample Shortcuts Recipes

### 1. Daily Journal ("Append to Today's Journal")
Finds or creates `Journal/YYYY-MM-DD.md` from the Daily Journal template, appends a timestamped bullet under `## Notes`, and opens the document in Swash:
1. **Ask for Input** (Text, Prompt: `"What happened?"`) → `Provided Input`
2. **Swash: Create Document from Template**
   - Template: `Daily Journal`
   - Title or Relative Path: `Journal/{{date}}`
   - Returns: `Journal Document` (`SwashDocumentEntity`)
3. **Swash: Append or Prepend to Document**
   - Text: `Provided Input`
   - Document: `Journal Document`
   - Position: `Under Heading`
   - Heading: `Notes`
   - Style: `Timestamped Bullet (- HH:mm item)`
4. **Swash: Open Markdown Document**
   - Document: `Journal Document`

### 2. Capture to Inbox (Share Sheet or Action Button)
Captures selected text, a shared URL, or dictated text into `Inbox.md` as an open `- [ ]` task without opening the app:
1. **Receive** `Text`, `URLs`, or `Rich Text` from **Share Sheet** (or **Dictate Text** for the Action button) → `Shortcut Input`
2. **Swash: Append or Prepend to Document**
   - Text: `Shortcut Input`
   - Path or Name: `Inbox.md`
   - Position: `End of Document`
   - Style: `To-Do (- [ ] item)`
   - Create if Missing: `true`

### 4. Web Clipping (Safari Selection or Page → Markdown Note)
Converts a Safari web page or selection from HTML to Markdown with a `Source:` link and appends it or saves a new note:
1. **Receive** `Safari web pages` or `Rich Text` from **Share Sheet**
2. **Get Details of Safari Web Page** (`Page Selection` or `Page Contents`, plus `Page URL`)
3. **Swash: Convert HTML to Markdown**
   - HTML or Text: `Page Selection`
   - Source URL: `Page URL`
   - Include Source Link: `true`
   - Returns: `Clipped Markdown`
4. **Swash: Append or Prepend to Document**
   - Text: `Clipped Markdown`
   - Path or Name: `Clips.md` (or pass to **Swash: Create Markdown Document**)

### 5. Publish / Send (HTML, Slack `mrkdwn`, or PDF Export)
Exports a Swash document as HTML, Slack `mrkdwn`, or a paginated PDF to send via Mail, Slack, or a blog API:
- **As PDF**:
  1. **Swash: Export Document as PDF** (Document: `Chosen Document`) → `PDF File`
  2. **Send Email** / **Share** `PDF File`
- **As HTML or Plain Text**:
  1. **Swash: Get Document Contents** (Document: `Chosen Document`, Format: `HTML` or `Standalone HTML`) → `HTML Content`
  2. **Get Contents of URL** (POST `HTML Content` to blog API) or **Send Email**
- **As Slack message**:
  1. **Swash: Get Document Contents** (Document: `Chosen Document`, Format: `Markdown`) → `Markdown Text`
  2. **Swash: Convert Markdown Flavor** (Markdown: `Markdown Text`, To Flavor: `Slack mrkdwn`) → `Slack Text`

### 6. Task Roll-Up (Collect Open `- [ ]` Tasks Across a Folder → Reminders)
Finds every unchecked `- [ ]` task across your Swash notes (or a specific folder) and adds them to Apple Reminders:
1. **Swash: Get To-Dos from Markdown**
   - Status: `Open (- [ ])`
   - Folder: *(optional folder, or leave blank for all Swash notes)*
   - Returns: `Open Tasks` (`[String]`)
2. **Repeat with Each** item in `Open Tasks`:
   - **Add New Reminder** with title `Repeat Item`

### 7. Search and Open ("Open My Swash Note About X")
Searches note titles and full-text contents, lets you pick from matching notes, and opens the chosen note:
1. **Ask for Input** (Text, Prompt: `"Search Swash notes for:"`) → `Query`
2. **Swash: Find Markdown Documents**
   - Query: `Query`
   - Search Scope: `Name and Content`
   - Limit: `10`
   - Returns: `Matching Documents` (`[SwashDocumentEntity]`)
3. **Choose from List** `Matching Documents` → `Chosen Document`
4. **Swash: Open Markdown Document**
   - Document: `Chosen Document`

---

## AppleScript (macOS)

`NSAppleScriptEnabled` is enabled in [`Swash/Info.plist`](../Swash/Info.plist) with scripting dictionary [`Swash/Swash.sdef`](../Swash/Swash.sdef) (`Swash Suite`), implemented in [`Swash/SwashAppleScript.swift`](../Swash/SwashAppleScript.swift).

| Command | Parameters | Returns | Description |
| :--- | :--- | :--- | :--- |
| `create note` | `titled` (`text`, optional), `with content` (`text`, optional) | `text` (file path) | Creates and opens a new Markdown document in Swash. |
| `open quick note` | — | — | Opens Swash's Quick Note capture panel. |
| `append to note` | direct parameter (`text`), `at path` (`text`, optional), `under heading` (`text`, optional), `as style` (`"plain"` \| `"bullet"` \| `"todo"` \| `"timestamped bullet"` \| `"timestamped todo"`, optional) | `text` (file path) | Appends or inserts text into a Markdown note (creating it if needed). |
| `get note contents` | direct parameter (`text`, path or title), `as format` (`"markdown"` \| `"plain text"` \| `"html"` \| `"standalone html"`, optional) | `text` | Reads a note's contents in the requested format. |
| `find notes` | direct parameter (`text`, query), `in folder` (`text`, optional) | `text` (newline-separated paths) | Searches Markdown notes by filename and content. |
| `get todos` | `in path` (`text`, optional), `with status` (`"open"` \| `"completed"` \| `"all"`, optional) | `text` (newline-separated tasks) | Extracts `- [ ]` / `- [x]` tasks from a note or folder. |
| `convert html to markdown` | direct parameter (`text`, HTML), `from url` (`text`, optional) | `text` | Converts HTML to Markdown (with optional source link). |
| `count words` | direct parameter (`text`) | `text` | Returns `"<words> words, <chars> characters, <lines> lines"`. |
| `format markdown` | direct parameter (`text`), `as style` (`"code block"` \| `"quote block"` \| `"header"`, optional) | `text` | Formats plain text as a Markdown code block, quote block, or header. |

```applescript
tell application "Swash"
    create note titled "Meeting Notes" with content "# Agenda"
    append to note "Follow up on release checklist" at path "Inbox.md" as style "todo"
    set inboxHTML to get note contents "Inbox.md" as format "html"
    set openTasks to get todos in path "Inbox.md" with status "open"
    set matchingPaths to find notes "Agenda"
    set stats to count words "Hello Swash world"
    set md to convert html to markdown "<p>Hello <strong>Swash</strong></p>" from url "https://swash.pixerate.com"
end tell
```

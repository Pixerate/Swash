// Checks for Swash's Shortcuts & Automation engine (Swash/SwashAppIntents.swift):
// append/prepend (end, beginning, under heading, bullet/todo/timestamp styles), find/create,
// templates, HTML ↔ Markdown and flavor conversions, to-do extraction, outlines and statistics.
// Run via scripts/run_shortcuts_tests.sh.

import Foundation
import PixerateMarkdown

setvbuf(stdout, nil, _IONBF, 0)
var failures = 0
func check(_ name: String, _ ok: Bool, _ detail: @autoclosure () -> String = "") {
    let extra = ok ? "" : detail()
    print("\(ok ? "PASS" : "FAIL") \(name)\(extra.isEmpty ? "" : " — \(extra)")")
    if !ok { failures += 1 }
}

let fm = FileManager.default
let root = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "build/shortcuts/fixture")
    .absoluteURL.standardizedFileURL
try? fm.removeItem(at: root)
try! fm.createDirectory(at: root, withIntermediateDirectories: true)

// Fixed reference date: 2026-11-21 09:45 UTC
let utc = TimeZone(secondsFromGMT: 0)!
var components = DateComponents()
components.year = 2026
components.month = 11
components.day = 21
components.hour = 9
components.minute = 45
components.timeZone = utc
let fixedDate = Calendar(identifier: .gregorian).date(from: components)!

// MARK: - 1. Entry Formatting & Append/Prepend Logic

check(
    "plain entry formatting trims surrounding newlines",
    SwashShortcutsEngine.formatEntry("\n  Hello world \n", style: .plain, date: fixedDate, timeZone: utc) == "Hello world"
)
check(
    "bullet formatting adds dash prefix",
    SwashShortcutsEngine.formatEntry("First item\nSecond item", style: .bullet, date: fixedDate, timeZone: utc)
        == "- First item\n- Second item"
)
check(
    "todo formatting adds unchecked task prefix and strips existing bullet",
    SwashShortcutsEngine.formatEntry("- Buy milk\nCall Alice", style: .todo, date: fixedDate, timeZone: utc)
        == "- [ ] Buy milk\n- [ ] Call Alice"
)
check(
    "timestamped bullet formatting prefixes HH:mm in bold",
    SwashShortcutsEngine.formatEntry("Shipped SWA-76", style: .timestampedBullet, date: fixedDate, timeZone: utc)
        == "- **09:45** Shipped SWA-76"
)
check(
    "timestamped todo formatting prefixes unchecked task with HH:mm",
    SwashShortcutsEngine.formatEntry("Review PR", style: .timestampedTodo, date: fixedDate, timeZone: utc)
        == "- [ ] **09:45** Review PR"
)

let emptyAppend = SwashShortcutsEngine.insert("First note", into: "", position: .end, style: .bullet)
check("appending to an empty document writes a single trailing newline", emptyAppend == "- First note\n", emptyAppend)

let tightListAppend = SwashShortcutsEngine.insert("Second item", into: "# List\n\n- First item\n", position: .end, style: .bullet)
check(
    "appending a bullet to a list keeps list items tight",
    tightListAppend == "# List\n\n- First item\n- Second item\n",
    tightListAppend
)

let paragraphAppend = SwashShortcutsEngine.insert("New paragraph", into: "# Heading\n\nOpening text.\n", position: .end, style: .plain)
check(
    "appending plain text separates paragraphs with a blank line",
    paragraphAppend == "# Heading\n\nOpening text.\n\nNew paragraph\n",
    paragraphAppend
)

let prependWithFrontMatter = SwashShortcutsEngine.insert(
    "Prepended intro",
    into: "---\ntitle: Doc\n---\n\n# Body\n",
    position: .beginning,
    style: .plain
)
check(
    "prepending preserves YAML front matter at the top of the file",
    prependWithFrontMatter == "---\ntitle: Doc\n---\n\nPrepended intro\n\n# Body\n",
    prependWithFrontMatter
)

let docWithSections = """
# 2026-11-21

## Notes
- **09:00** Morning standup

## Tasks
- [ ] Existing task

## Reflections
Quiet day.
"""

let underExistingHeading = SwashShortcutsEngine.insert(
    "Met with design team",
    into: docWithSections,
    position: .underHeading,
    heading: "Notes",
    style: .timestampedBullet,
    date: fixedDate,
    timeZone: utc
)
let expectedUnderNotes = """
# 2026-11-21

## Notes
- **09:00** Morning standup
- **09:45** Met with design team

## Tasks
- [ ] Existing task

## Reflections
Quiet day.
"""
check(
    "inserting under an existing heading places the item at the end of that section",
    underExistingHeading == expectedUnderNotes,
    underExistingHeading
)

let underMissingHeading = SwashShortcutsEngine.insert(
    "Check deployment metrics",
    into: "# Daily Note\n\nSome text.\n",
    position: .underHeading,
    heading: "Action Items",
    style: .todo
)
check(
    "inserting under a missing heading creates the heading at the end",
    underMissingHeading == "# Daily Note\n\nSome text.\n\n## Action Items\n\n- [ ] Check deployment metrics\n",
    underMissingHeading
)

// MARK: - 2. Templates & Find-or-Create Document (Use Cases 1, 2, 3, 8)

let vars = SwashShortcutsEngine.parseVariables("attendees = Alice, Bob\nagenda: Shortcuts design")
let meetingExpanded = SwashShortcutsEngine.expandTemplate(
    SwashShortcutsEngine.templateBody(for: .meetingNotes),
    title: "Weekly Sync",
    variables: vars,
    clipboard: "https://github.com/Pixerate/Swash/issues/196",
    date: fixedDate,
    timeZone: utc
)
check(
    "template expansion fills date, time, title and custom variables",
    meetingExpanded.contains("# Weekly Sync")
        && meetingExpanded.contains("- **Date:** 2026-11-21 09:45")
        && meetingExpanded.contains("- **Attendees:** Alice, Bob")
        && meetingExpanded.contains("- Shortcuts design"),
    meetingExpanded
)

let journalPath = SwashShortcutsEngine.expandTemplate(
    SwashShortcutsEngine.defaultTitlePattern(for: .dailyJournal),
    date: fixedDate,
    timeZone: utc
)
let journalBody = SwashShortcutsEngine.expandTemplate(
    SwashShortcutsEngine.templateBody(for: .dailyJournal),
    date: fixedDate,
    timeZone: utc
)
let (journalURL, journalCreated) = try! SwashShortcutsEngine.findOrCreateDocument(
    pathOrTitle: journalPath,
    initialContent: journalBody,
    in: root
)
check("findOrCreateDocument creates nested Journal/2026-11-21.md", journalCreated && journalURL.path.hasSuffix("/Journal/2026-11-21.md"), journalURL.path)

let (_, secondCreated) = try! SwashShortcutsEngine.findOrCreateDocument(
    pathOrTitle: "Journal/2026-11-21",
    initialContent: "Should not overwrite",
    in: root
)
check("findOrCreateDocument finds existing document without overwriting", !secondCreated)

let updatedJournal = SwashShortcutsEngine.insert(
    "Reviewed iPad Shortcuts gap analysis",
    into: try! SwashShortcutsEngine.readText(at: journalURL),
    position: .underHeading,
    heading: "Notes",
    style: .timestampedBullet,
    date: fixedDate,
    timeZone: utc
)
try! SwashShortcutsEngine.writeText(updatedJournal, to: journalURL)
check(
    "coordinated write updates Journal/2026-11-21.md with timestamped bullet",
    (try! SwashShortcutsEngine.readText(at: journalURL)).contains("- **09:45** Reviewed iPad Shortcuts gap analysis")
)

// Use case 2: Capture to Inbox
let (inboxURL, inboxCreated) = try! SwashShortcutsEngine.findOrCreateDocument(
    pathOrTitle: "Inbox.md",
    initialContent: "# Inbox\n",
    in: root
)
let inboxAfterCapture = SwashShortcutsEngine.insert(
    "Follow up with team on App Intents",
    into: try! SwashShortcutsEngine.readText(at: inboxURL),
    position: .end,
    style: .todo
)
try! SwashShortcutsEngine.writeText(inboxAfterCapture, to: inboxURL)
check(
    "inbox capture appends a task item to Inbox.md",
    inboxCreated && (try! SwashShortcutsEngine.readText(at: inboxURL)) == "# Inbox\n\n- [ ] Follow up with team on App Intents\n"
)

// MARK: - 3. Search & Find Documents (Use Case 7)

let (_, _) = try! SwashShortcutsEngine.findOrCreateDocument(
    pathOrTitle: "Projects/Roadmap.md",
    initialContent: "# Q4 Roadmap\n\nShip Shortcuts AppEntity and Spotlight indexing.\n\n- [ ] Build SwashDocumentEntity\n- [x] Ship iOS editor\n",
    in: root
)

let byName = SwashShortcutsEngine.findDocuments(query: "roadmap", scope: .nameOnly, in: [root])
check("name search finds Projects/Roadmap.md", byName.count == 1 && byName[0].title == "Roadmap", "\(byName.map(\.title))")

let byContent = SwashShortcutsEngine.findDocuments(query: "Spotlight indexing", scope: .contentOnly, in: [root])
check("full-text content search finds note containing phrase", byContent.count == 1 && byContent[0].title == "Roadmap", "\(byContent.map(\.title))")

let combined = SwashShortcutsEngine.findDocuments(query: "2026-11-21", scope: .nameAndContent, in: [root])
check("combined search finds daily journal note", combined.first?.title == "2026-11-21", "\(combined.map(\.title))")

// MARK: - 4. HTML, Markdown & Flavor Conversions (Use Cases 4, 5, 9)

let clippedMD = SwashShortcutsEngine.convertHTMLToMarkdown(
    "<h2>Release Notes</h2><p>Read the <a href=\"/docs\">guide</a> for <strong>Swash</strong>.</p>",
    sourceURL: URL(string: "https://swash.pixerate.com/blog/196"),
    includeSourceLink: true
)
check(
    "HTML to Markdown converts tags, resolves relative links and appends source link",
    clippedMD.contains("## Release Notes")
        && clippedMD.contains("[guide](https://swash.pixerate.com/docs)")
        && clippedMD.contains("**Swash**")
        && clippedMD.contains("Source: [swash.pixerate.com](https://swash.pixerate.com/blog/196)"),
    clippedMD
)

let sampleMD = "# Title\n\nHello **world** with [a link](https://example.com) and ~~strike~~."
let htmlOut = SwashShortcutsEngine.convertMarkdown(sampleMD, to: .html, flavor: .github)
check("Markdown to HTML renders headings, strong, links and strikethrough", htmlOut.contains("<h1>Title</h1>") && htmlOut.contains("<strong>world</strong>") && htmlOut.contains("<del>strike</del>"), htmlOut)

let standaloneOut = SwashShortcutsEngine.convertMarkdown(sampleMD, to: .standaloneHTML, flavor: .github, title: "My Doc")
check("Standalone HTML wraps body in full HTML document with escaped title", standaloneOut.contains("<!DOCTYPE html>") && standaloneOut.contains("<title>My Doc</title>"))

let plainOut = SwashShortcutsEngine.convertMarkdown(sampleMD, to: .plainText, flavor: .github)
check("Markdown to plain text strips formatting syntax", plainOut == "Title\nHello world with a link and strike.", plainOut)

let toSlack = SwashShortcutsEngine.convertFlavor(sampleMD, from: .github, to: .slack)
check("GitHub to Slack mrkdwn converts bold, strike and links", toSlack.contains("*world*") && toSlack.contains("<https://example.com|a link>") && toSlack.contains("~strike~"), toSlack)

let backToGitHub = SwashShortcutsEngine.convertFlavor(toSlack, to: .github)
check("Slack mrkdwn auto-detects and converts back to GitHub Markdown", backToGitHub.contains("**world**") && backToGitHub.contains("[a link](https://example.com)") && backToGitHub.contains("~~strike~~"), backToGitHub)

// MARK: - 5. To-Do Roll-Up, Outline & Statistics (Use Cases 6, 11, 12)

let codeBlockTasksDoc = """
# Sprint Tasks

- [ ] Real open task
- [x] Completed task

```markdown
- [ ] Fake task inside fenced code block
```
"""
let openTasks = SwashShortcutsEngine.extractTodos(from: codeBlockTasksDoc, status: .open)
check("extractTodos finds open tasks and ignores tasks inside fenced code blocks", openTasks.map(\.text) == ["Real open task"], "\(openTasks)")

let completedTasks = SwashShortcutsEngine.extractTodos(from: codeBlockTasksDoc, status: .completed)
check("extractTodos filters completed tasks", completedTasks.map(\.text) == ["Completed task"], "\(completedTasks)")

let folderOpenTasks = SwashShortcutsEngine.extractTodos(
    in: SwashShortcutsEngine.discoverFiles(in: [root]),
    status: .open
)
check(
    "folder todo roll-up collects open tasks across all notes in folder",
    folderOpenTasks.map(\.text).contains("Follow up with team on App Intents")
        && folderOpenTasks.map(\.text).contains("Build SwashDocumentEntity"),
    "\(folderOpenTasks.map(\.text))"
)

let outline = SwashShortcutsEngine.formattedOutline(from: docWithSections)
check(
    "formattedOutline returns indented heading hierarchy",
    outline == ["# 2026-11-21", "  ## Notes", "  ## Tasks", "  ## Reflections"],
    "\(outline)"
)

let docStats = SwashShortcutsEngine.calculateStatistics(for: codeBlockTasksDoc)
check(
    "calculateStatistics counts words, headings, open and completed todos",
    docStats.words > 0 && docStats.headings == 1 && docStats.openTodos == 1 && docStats.completedTodos == 1,
    "\(docStats)"
)

let folderStats = SwashShortcutsEngine.calculateStatistics(forFiles: SwashShortcutsEngine.discoverFiles(in: [root]))
check(
    "folder statistics aggregate word and todo counts across discovered files",
    folderStats.words >= 20 && folderStats.openTodos == 2 && folderStats.completedTodos == 1,
    "\(folderStats)"
)

// Appending is one coordinated read-modify-write, and a file it can't read is left alone
let appendURL = root.appendingPathComponent("Append Target.md")
try! SwashShortcutsEngine.writeText("# Log\n", to: appendURL)
let appended = try? SwashShortcutsEngine.modifyText(at: appendURL) { $0 + "- one\n" }
check("modifyText reads, changes and writes in one step", appended == "# Log\n- one\n" && (try? SwashShortcutsEngine.readText(at: appendURL)) == "# Log\n- one\n")
let missingURL = root.appendingPathComponent("Missing.md")
let failed = (try? SwashShortcutsEngine.modifyText(at: missingURL) { $0 + "appended" }) == nil
check("modifyText throws when it can't read the file, and writes nothing",
      failed && !fm.fileExists(atPath: missingURL.path))

try? fm.removeItem(at: root)
print(failures == 0 ? "SHORTCUTS: all checks passed" : "SHORTCUTS: \(failures) failure(s)")
exit(failures == 0 ? 0 : 1)

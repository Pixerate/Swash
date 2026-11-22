//
//  main.swift
//  Tests/Share
//
//  Unit tests for ShareContentConverter with HTML and RTF fixtures.
//

import Foundation
import AppKit
import PixerateMarkdown

var failures = 0
func check(_ name: String, _ condition: Bool, _ message: String = "") {
    print("\(condition ? "PASS" : "FAIL") \(name)\(condition ? "" : " — \(message)")")
    if !condition { failures += 1 }
}

func checkEqual(_ name: String, _ actual: String?, _ expected: String) {
    let ok = actual == expected
    check(name, ok, "expected \(expected.debugDescription), got \((actual ?? "nil").debugDescription)")
}

func checkContains(_ name: String, _ actual: String?, _ needle: String) {
    let ok = actual?.contains(needle) == true
    check(name, ok, "expected to contain \(needle.debugDescription), got \((actual ?? "nil").debugDescription)")
}

// MARK: - HTML Fixtures

// 1. Safari / Notes / Notion formatted HTML: headings, bold, italics, links
let htmlFormatted = """
<h2>Meeting Notes</h2>
<p>Discussed the <b>new feature</b> and <i>timeline</i>.</p>
<p>See <a href="https://example.com/spec">the specification</a> for details.</p>
"""
let mdFormatted = ShareContentConverter.markdownFromHTML(htmlFormatted)
checkContains("HTML heading becomes Markdown heading", mdFormatted, "## Meeting Notes")
checkContains("HTML bold becomes Markdown bold", mdFormatted, "**new feature**")
checkContains("HTML italic becomes Markdown italic", mdFormatted, "*timeline*")
checkContains("HTML link becomes Markdown link", mdFormatted, "[the specification](https://example.com/spec)")

// 2. Relative links resolved via sourceURL (Safari selection)
let htmlRelativeLinks = """
<p>Check the <a href="/docs/guide">User Guide</a> and <a href="changelog.html">Changelog</a>.</p>
"""
let sourceURL = URL(string: "https://swash.app/v1/index.html")!
let mdRelative = ShareContentConverter.markdownFromHTML(htmlRelativeLinks, sourceURL: sourceURL)
checkContains("Relative link with root path resolves against sourceURL", mdRelative, "[User Guide](https://swash.app/docs/guide)")
checkContains("Relative link with relative path resolves against sourceURL", mdRelative, "[Changelog](https://swash.app/v1/changelog.html)")

// 3. Unordered and ordered lists
let htmlList = "<ul><li>First item</li><li>Second item with <b>bold</b></li></ul>"
let mdList = ShareContentConverter.markdownFromHTML(htmlList)
checkContains("List first item present", mdList, "First item")
checkContains("List second item with bold present", mdList, "Second item with **bold**")
check("List items formatted with list markers", mdList.contains("- ") || mdList.contains("* "))

// 4. Checklists / task lists (Notes / Notion to-dos)
let htmlChecklist = """
<ul class="checklist">
  <li><input type="checkbox" checked> Done task</li>
  <li><input type="checkbox"> Pending task</li>
</ul>
"""
let mdChecklist = ShareContentConverter.markdownFromHTML(htmlChecklist)
checkContains("Checked task list item converts to [x]", mdChecklist, "[x] Done task")
checkContains("Unchecked task list item converts to [ ]", mdChecklist, "[ ] Pending task")

// 5. Plain text comparison rule: no formatting gained keeps plain text without backslash escapes
let plainWithChars = "Plain text with *asterisks*, _underscores_, [brackets] and `backticks`."
let htmlNoFormatting = "<p>Plain text with *asterisks*, _underscores_, [brackets] and `backticks`.</p>"
let mdKeepsPlain = ShareContentConverter.markdownFromHTML(htmlNoFormatting, plainText: plainWithChars)
checkEqual("HTML without formatting gain returns plain text verbatim without escapes", mdKeepsPlain, plainWithChars)

// 6. Preformatted code block (from code editors) keeps plain text indentation
let preformattedHTML = "<div style=\"white-space: pre;\"><span>    let x = 42\n    return x</span></div>"
let preformattedPlain = "    let x = 42\n    return x"
let mdPre = ShareContentConverter.markdownFromHTML(preformattedHTML, plainText: preformattedPlain)
checkEqual("Preformatted HTML keeps plain text indentation", mdPre, preformattedPlain)

// MARK: - RTF Fixtures

// 7. RTF with styled text and link
let richText = NSMutableAttributedString(string: "A note with ", attributes: [.font: NSFont.systemFont(ofSize: 13)])
richText.append(NSAttributedString(
    string: "Swash Website",
    attributes: [
        .font: NSFont.boldSystemFont(ofSize: 13),
        .link: URL(string: "https://swash.app")!
    ]
))
richText.append(NSAttributedString(string: " and some trailing notes.", attributes: [.font: NSFont.systemFont(ofSize: 13)]))

let rtfData = try! richText.data(
    from: NSRange(location: 0, length: richText.length),
    documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]
)
let mdFromRTF = ShareContentConverter.markdownFromRTF(rtfData, isRTFD: false, plainText: richText.string)
check("RTF converts to Markdown", mdFromRTF != nil)
check("RTF link survives to Markdown", mdFromRTF?.contains("](https://swash.app)") == true && mdFromRTF?.contains("Swash Website") == true, "got \(mdFromRTF.debugDescription)")

// 8. RTFD fixture
let rtfdData = try! richText.data(
    from: NSRange(location: 0, length: richText.length),
    documentAttributes: [.documentType: NSAttributedString.DocumentType.rtfd]
)
let mdFromRTFD = ShareContentConverter.markdownFromRTF(rtfdData, isRTFD: true, plainText: richText.string)
check("RTFD converts to Markdown", mdFromRTFD != nil)
check("RTFD link survives to Markdown", mdFromRTFD?.contains("](https://swash.app)") == true && mdFromRTFD?.contains("Swash Website") == true, "got \(mdFromRTFD.debugDescription)")

// MARK: - Safari Source Link

// 9. Safari selection + URL appends source link [Title](url)
let convertedText = "## Safari Selection\n\nSome important excerpt."
let safariPageURL = URL(string: "https://example.com/articles/swash-review")!
let withSourceLink = ShareContentConverter.appendingSourceLink(to: convertedText, url: safariPageURL, title: "Swash Review")
checkEqual(
    "Safari selection + URL appends [Title](url)",
    withSourceLink,
    "## Safari Selection\n\nSome important excerpt.\n\n[Swash Review](https://example.com/articles/swash-review)"
)

// 10. Safari URL alone (empty or whitespace selection) formats as [Title](url)
let linkOnly = ShareContentConverter.appendingSourceLink(to: "", url: safariPageURL, title: "Swash Review")
checkEqual(
    "URL alone formats as [Title](url)",
    linkOnly,
    "[Swash Review](https://example.com/articles/swash-review)"
)

// 11. Fallback to host when title is missing or empty
let linkFallback = ShareContentConverter.appendingSourceLink(to: "", url: safariPageURL, title: nil)
checkEqual(
    "URL without title falls back to host",
    linkFallback,
    "[example.com](https://example.com/articles/swash-review)"
)

print(failures == 0 ? "SHARE: all checks passed" : "SHARE: \(failures) failed")
exit(failures == 0 ? 0 : 1)

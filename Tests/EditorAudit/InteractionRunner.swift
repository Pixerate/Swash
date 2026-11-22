import Foundation
import MacAppKitExtras
import SwiftUI
import AppKit
import PixerateCore
import PixerateMarkdown

final class TextBox { var text: String; init(_ t: String) { text = t } }
func pump(_ s: Double = 0.15) { RunLoop.main.run(until: Date().addingTimeInterval(s)) }
/// Runs the loop until the writing partner has played every fix (up to `limit` seconds), then a turn
/// more for the editor to restyle.
@MainActor func waitForPartner(_ tv: NSTextView, limit: Double = 10) {
    let deadline = Date().addingTimeInterval(limit)
    pump(0.05)
    while Date() < deadline, let coordinator = tv.delegate as? SwashTextView.Coordinator, !coordinator.writingPartner.isIdle { pump(0.02) }
    pump(0.05)
}
func findTextView(in v: NSView) -> NSTextView? {
    if let tv = v as? NSTextView { return tv }
    for s in v.subviews { if let f = findTextView(in: s) { return f } }
    return nil
}

var windows: [NSWindow] = []
func makeEditor(_ box: TextBox, styled: Bool = true, flavor: MarkdownFlavor = .github, writing: WritingOptions = WritingOptions(), baseURL: URL? = nil) -> NSTextView {
    let binding = Binding<String>(get: { box.text }, set: { box.text = $0 })
    let editor = SwashTextView(text: binding, selectedRange: .constant(nil), selectionRect: .constant(nil),
                               isStyled: styled, flavor: flavor, baseURL: baseURL, writingOptions: writing)
    let host = NSHostingView(rootView: editor.frame(width: 600, height: 600))
    host.frame = NSRect(x: 0, y: 0, width: 600, height: 600)
    let win = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
    win.contentView = host
    windows.append(win)
    host.layoutSubtreeIfNeeded()
    pump(0.3)
    let tv = findTextView(in: host)!
    win.makeFirstResponder(tv)
    return tv
}

func caretAfter(_ needle: String, in tv: NSTextView) {
    let r = (tv.string as NSString).range(of: needle)
    tv.setSelectedRange(NSRange(location: r.location + r.length, length: 0))
}
func caretBefore(_ needle: String, in tv: NSTextView) {
    let r = (tv.string as NSString).range(of: needle)
    tv.setSelectedRange(NSRange(location: r.location, length: 0))
}

// Key commands are sent with doCommand(by:) so the text view delegate sees them, exactly as key presses do
var out = ""
var failures: [String] = []
/// Records a probe. When `expect` is given the probe is a regression assertion.
func log(_ id: String, _ before: String, _ after: String, _ note: String = "", expect: String? = nil) {
    out += "## \(id)\nBEFORE: \(before.debugDescription)\nAFTER:  \(after.debugDescription)\n\(note.isEmpty ? "" : "NOTE: \(note)\n")\n"
    if let expected = expect, expected != after {
        failures.append("\(id): expected \(expected.debugDescription), got \(after.debugDescription)")
    }
}

@main
struct InteractionRunner {
    static func main() {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)

        // 1. Enter at end of bullet item
        do { let b = TextBox("- first item"); let tv = makeEditor(b); caretAfter("first item", in: tv)
             tv.doCommand(by: #selector(NSResponder.insertNewline(_:))); pump(); tv.insertText("second", replacementRange: tv.selectedRange()); pump()
             log("enter-continues-bullet-list", "- first item", b.text, expect: "- first item\n- second") }
        // 2. Enter at end of ordered item
        do { let b = TextBox("1. first"); let tv = makeEditor(b); caretAfter("first", in: tv)
             tv.doCommand(by: #selector(NSResponder.insertNewline(_:))); pump(); tv.insertText("second", replacementRange: tv.selectedRange()); pump()
             log("enter-continues-ordered-list", "1. first", b.text, expect: "1. first\n2. second") }
        // 3. Enter at end of task item
        do { let b = TextBox("- [x] done"); let tv = makeEditor(b); caretAfter("done", in: tv)
             tv.doCommand(by: #selector(NSResponder.insertNewline(_:))); pump(); tv.insertText("next", replacementRange: tv.selectedRange()); pump()
             log("enter-continues-task-list", "- [x] done", b.text, expect: "- [x] done\n- [ ] next") }
        // 4. Tab in list item
        do { let b = TextBox("- a\n- b"); let tv = makeEditor(b); caretAfter("- b", in: tv)
             tv.doCommand(by: #selector(NSResponder.insertTab(_:))); pump()
             log("tab-indents-list-item", "- a\n- b", b.text, expect: "- a\n  - b") }
        // 5. Enter in blockquote
        do { let b = TextBox("> quote"); let tv = makeEditor(b); caretAfter("quote", in: tv)
             tv.doCommand(by: #selector(NSResponder.insertNewline(_:))); pump(); tv.insertText("more", replacementRange: tv.selectedRange()); pump()
             log("enter-continues-quote", "> quote", b.text, expect: "> quote\nmore".replacingOccurrences(of: "\nmore", with: "\n> more")) }
        // 6. Backspace at visual start of heading text
        do { let b = TextBox("## Title"); let tv = makeEditor(b); caretBefore("Title", in: tv)
             tv.doCommand(by: #selector(NSResponder.deleteBackward(_:))); pump()
             log("backspace-at-heading-start", "## Title", b.text, expect: "Title") }
        // 7. Backspace at visual start of bullet text
        do { let b = TextBox("- item"); let tv = makeEditor(b); caretBefore("item", in: tv)
             tv.doCommand(by: #selector(NSResponder.deleteBackward(_:))); pump()
             log("backspace-at-list-start", "- item", b.text, expect: "item") }
        // 8. Arrow keys across hidden markers: count presses to move from before 'x' to after 'y' in 'x **b** y'
        do { let b = TextBox("x **b** y"); let tv = makeEditor(b); caretAfter("x", in: tv)
             var presses = 0; let target = (tv.string as NSString).range(of: " y").location
             while tv.selectedRange().location < target && presses < 20 { tv.moveRight(nil); presses += 1 }
             log("arrow-keys-hidden-markers", "x **b** y", "presses=\(presses)", "one press per visible character", expect: "presses=3") }
        // 9. Typing right after a bold run: does new text inherit bold / land inside markers?
        do { let b = TextBox("**bold** tail"); let tv = makeEditor(b); caretAfter("bold", in: tv)
             tv.insertText("X", replacementRange: tv.selectedRange()); pump()
             log("type-at-end-of-bold", "**bold** tail", b.text, "caret visually after 'bold' sits before hidden '**' so text lands inside bold") }
        // 10. Undo after typing in a document containing a table
        do { let md = "| A | B |\n|---|---|\n| 1 | 2 |\n\nPara"
             let b = TextBox(md); let tv = makeEditor(b); caretAfter("Para", in: tv)
             tv.insertText("graph", replacementRange: tv.selectedRange()); pump()
             let afterType = b.text
             tv.undoManager?.undo(); pump()
             let afterUndo = b.text
             log("undo-with-table-present", md, afterUndo, "after typing: \(afterType.debugDescription)", expect: md) }
        // 11. Undo after typing in a doc with an image
        do { let md = "![alt](missing.png)\n\nHello"
             let b = TextBox(md); let tv = makeEditor(b); caretAfter("Hello", in: tv)
             tv.insertText(" world", replacementRange: tv.selectedRange()); pump()
             let afterType = b.text
             tv.undoManager?.undo(); pump()
             log("undo-with-image-present", md, b.text, "after typing: \(afterType.debugDescription)") }
        // 12. Undo of plain typing (no attachments)
        do { let md = "Hello"
             let b = TextBox(md); let tv = makeEditor(b); caretAfter("Hello", in: tv)
             tv.insertText(" world", replacementRange: tv.selectedRange()); pump()
             tv.undoManager?.undo(); pump()
             log("undo-plain", md, b.text, expect: "Hello") }
        // 13. Opening doc then typing: are untouched tables reformatted?
        do { let md = "|a|b|\n|-|-|\n|1|2|\n\nx"
             let b = TextBox(md); let tv = makeEditor(b); caretAfter("x", in: tv)
             tv.insertText("y", replacementRange: tv.selectedRange()); pump()
             log("typing-rewrites-untouched-table", md, b.text, "untouched tables must round-trip verbatim", expect: md + "y") }
        // 14. Selection coordinates vs raw markdown (attachments collapse to 1 char)
        do { let md = "![alt](missing.png) target word"
             let b = TextBox(md); let tv = makeEditor(b)
             let r = (tv.string as NSString).range(of: "target")
             let rawR = (md as NSString).range(of: "target")
             log("selection-offset-drift", md, md, "'target' is at storage offset \(r.location) but raw-markdown offset \(rawR.location); ContentView applies bubble actions to document.text using storage offsets → wrong span") }
        // 15. Paste rich text (HTML) into WYSIWYG
        do { let b = TextBox(""); let tv = makeEditor(b)
             let pb = NSPasteboard.general; pb.clearContents()
             pb.setString("<b>Bold</b> and <a href=\"https://x.com\">link</a>", forType: .html)
             pb.setString("Bold and link", forType: .string)
             tv.paste(nil); pump()
             log("paste-html", "(empty) + clipboard HTML '<b>Bold</b> and <a>link</a>'", b.text, expect: "**Bold** and [link](https://x.com)") }
        // 15b. Plain-equivalent HTML pastes as plain text; code-editor HTML keeps its indentation
        do { let b = TextBox(""); let tv = makeEditor(b)
             let pb = NSPasteboard.general; pb.clearContents()
             pb.setString("<p>5 * 3 = 15</p>", forType: .html); pb.setString("5 * 3 = 15", forType: .string)
             tv.paste(nil); pump()
             log("paste-plain-equivalent-html", "<p>5 * 3 = 15</p>", b.text, expect: "5 * 3 = 15") }
        do { let b = TextBox(""); let tv = makeEditor(b)
             let pb = NSPasteboard.general; pb.clearContents()
             pb.setString("<div style=\"white-space: pre;\"><div><span>func a() {</span></div><div><span>    return 1</span></div></div>", forType: .html)
             pb.setString("func a() {\n    return 1", forType: .string)
             tv.paste(nil); pump()
             log("paste-code-editor-html", "VS Code-style HTML", b.text, expect: "func a() {\n    return 1") }
        // 15d. RTF (TextEdit, Pages) converts through HTML
        do { let b = TextBox(""); let tv = makeEditor(b)
             let rich = NSMutableAttributedString(string: "Bold and italic text")
             rich.addAttribute(.font, value: NSFont.boldSystemFont(ofSize: 13), range: NSRange(location: 0, length: 4))
             rich.addAttribute(.font, value: NSFontManager.shared.convert(NSFont.systemFont(ofSize: 13), toHaveTrait: .italicFontMask), range: NSRange(location: 9, length: 6))
             let rtf = try! rich.data(from: NSRange(location: 0, length: rich.length), documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
             let pb = NSPasteboard.general; pb.clearContents()
             pb.setData(rtf, forType: .rtf); pb.setString(rich.string, forType: .string)
             tv.paste(nil); pump()
             log("paste-rtf", "RTF: **Bold** and *italic* text", b.text, expect: "**Bold** and *italic* text") }
        // 15c. Copy within Swash pastes the exact Markdown (tables and images included)
        do { let md = "| A | B |\n|---|---|\n| ![i](x.png) | **b** |\n\nPara *x*"
             let src = TextBox(md); let tv1 = makeEditor(src); tv1.selectAll(nil); tv1.copy(nil); pump()
             let dst = TextBox(""); let tv2 = makeEditor(dst); tv2.paste(nil); pump()
             log("copy-paste-roundtrip", md, dst.text, expect: md) }
        // 16. Copy from WYSIWYG → plain-text clipboard content
        do { let md = "**bold** and [link](https://x.com)"
             let b = TextBox(md); let tv = makeEditor(b); tv.selectAll(nil); tv.copy(nil); pump()
             log("copy-plain-flavor", md, NSPasteboard.general.string(forType: .string) ?? "nil", "plain-text flavour should be raw markdown") }
        // 17. Typing '---' then Enter — live HR?
        do { let b = TextBox("Para\n"); let tv = makeEditor(b); tv.setSelectedRange(NSRange(location: (tv.string as NSString).length, length: 0))
             tv.insertText("---", replacementRange: tv.selectedRange()); pump()
             log("type-hr-under-paragraph", "Para\\n + '---'", b.text, "'Para' immediately becomes a setext H2 and '---' disappears (no blank line)") }

        // 18. Consecutive keystrokes after a table keep the caret in place
        do { let md = "| A | B |\n|---|---|\n| 1 | 2 |\n\nPara"
             let b = TextBox(md); let tv = makeEditor(b); caretAfter("Para", in: tv)
             for ch in ["a", "b", "c"] { tv.insertText(ch, replacementRange: tv.selectedRange()); pump() }
             log("consecutive-typing-after-table", md, b.text, expect: md + "abc") }
        // 19. Consecutive keystrokes between two images
        do { let md = "![a](x.png) mid ![b](y.png) end"
             let b = TextBox(md); let tv = makeEditor(b); caretAfter("mid", in: tv)
             for ch in ["1", "2"] { tv.insertText(ch, replacementRange: tv.selectedRange()); pump() }
             tv.undoManager?.undo(); pump()
             let afterUndo = b.text
             tv.undoManager?.redo(); pump()
             log("typing-undo-redo-between-images", md, b.text, "after undo: \(afterUndo.debugDescription)", expect: "![a](x.png) mid12 ![b](y.png) end")
             if afterUndo != md { failures.append("typing-undo-redo-between-images: undo expected original, got \(afterUndo.debugDescription)") } }

        // 22. Arrow keys back across hidden markers, and a click at line start lands on the content
        do { let b = TextBox("x **b** y"); let tv = makeEditor(b); caretAfter("y", in: tv)
             var presses = 0; let target = (tv.string as NSString).range(of: "x").location + 1
             while tv.selectedRange().location > target && presses < 20 { tv.doCommand(by: #selector(NSResponder.moveLeft(_:))); presses += 1 }
             log("arrow-left-hidden-markers", "x **b** y", "presses=\(presses)", expect: "presses=4") }
        do { let b = TextBox("## Title"); let tv = makeEditor(b); tv.setSelectedRange(NSRange(location: 0, length: 0)); pump()
             tv.insertText("New ", replacementRange: tv.selectedRange()); pump()
             log("click-line-start-types-into-heading", "## Title", b.text, expect: "## New Title") }
        do { let b = TextBox("```\ncode\n```\nafter"); let tv = makeEditor(b); caretAfter("code", in: tv)
             tv.doCommand(by: #selector(NSResponder.moveRight(_:))); pump()
             tv.insertText("X", replacementRange: tv.selectedRange()); pump()
             log("arrow-over-collapsed-fence-line", "```\ncode\n```\nafter", b.text, expect: "```\ncode\n```\nXafter") }
        
        // 23. Clicking a task checkbox toggles it (and undo restores it)
        func clickCheckbox(_ tv: NSTextView, line index: Int) {
            guard let lm = tv.layoutManager, let storage = tv.textStorage else { return }
            var markers: [NSRange] = []
            storage.enumerateAttribute(.listMarker, in: NSRange(location: 0, length: storage.length)) { v, r, _ in if v != nil { markers.append(r) } }
            guard index < markers.count else { return }
            let r = markers[index]
            let glyph = lm.glyphIndexForCharacter(at: NSMaxRange(r))
            let lineRect = lm.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
            let contentX = lineRect.minX + lm.location(forGlyphAt: glyph).x
            let containerPoint = NSPoint(x: contentX - 14, y: lineRect.midY)
            let viewPoint = NSPoint(x: containerPoint.x + tv.textContainerOrigin.x, y: containerPoint.y + tv.textContainerOrigin.y)
            let windowPoint = tv.convert(viewPoint, to: nil)
            let event = NSEvent.mouseEvent(with: .leftMouseDown, location: windowPoint, modifierFlags: [], timestamp: 0,
                                           windowNumber: tv.window?.windowNumber ?? 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
            tv.mouseDown(with: event)
        }
        do { let md = "- [ ] first\n- [x] second"
             let b = TextBox(md); let tv = makeEditor(b)
             clickCheckbox(tv, line: 0); pump()
             let afterFirst = b.text
             clickCheckbox(tv, line: 1); pump()
             let afterSecond = b.text
             tv.undoManager?.undo(); pump()
             log("checkbox-click-toggles", md, afterFirst + " | " + afterSecond + " | undo: " + b.text,
                 expect: "- [x] first\n- [x] second | - [x] first\n- [ ] second | undo: - [x] first\n- [x] second") }
        
        // 24. "/" on an empty line opens the block menu; the chosen block replaces the slash
        SwashTextView.Coordinator.blockMenuPresenter = { _, _, choose in choose(.heading2) }
        do { let b = TextBox("Intro\n"); let tv = makeEditor(b)
             tv.setSelectedRange(NSRange(location: (tv.string as NSString).length, length: 0))
             tv.insertText("/", replacementRange: tv.selectedRange()); pump(0.3)
             tv.insertText("Title", replacementRange: tv.selectedRange()); pump()
             log("slash-menu-heading", "Intro\n + '/' → Heading 2", b.text, expect: "Intro\n## Title") }
        SwashTextView.Coordinator.blockMenuPresenter = { _, _, choose in choose(.todoList) }
        do { let b = TextBox("- a\n- "); let tv = makeEditor(b)
             tv.setSelectedRange(NSRange(location: (tv.string as NSString).length, length: 0))
             tv.insertText("/", replacementRange: tv.selectedRange()); pump(0.3)
             tv.insertText("task", replacementRange: tv.selectedRange()); pump()
             log("slash-menu-in-list-item", "- a\n- + '/' → To-do", b.text, expect: "- a\n- [ ] task") }
        var presented = false
        SwashTextView.Coordinator.blockMenuPresenter = { _, _, choose in presented = true; choose(nil) }
        do { let b = TextBox("and/or"); let tv = makeEditor(b); caretAfter("and", in: tv)
             tv.insertText("/", replacementRange: tv.selectedRange()); pump(0.3)
             log("slash-mid-sentence-no-menu", "and/or", "\(b.text) presented=\(presented)", expect: "and//or presented=false") }
        do { let b = TextBox(""); let tv = makeEditor(b)
             tv.insertText("/", replacementRange: tv.selectedRange()); pump(0.3)
             log("slash-menu-dismissed-keeps-slash", "'/' then Escape", "\(b.text) presented=\(presented)", expect: "/ presented=true") }
        
        // 25. Code block language badge: shown, and clicking it changes the fence's language
        SwashTextView.Coordinator.languageMenuPresenter = { _, _, _, choose in choose(.some("python")) }
        do { let md = "Intro\n\n```swift\nlet x = 1\n```"
             let b = TextBox(md); let tv = makeEditor(b)
             var badges: [String] = []
             var badgeRange = NSRange(location: NSNotFound, length: 0)
             tv.textStorage!.enumerateAttribute(.codeBadge, in: NSRange(location: 0, length: tv.textStorage!.length)) { v, r, _ in
                 if let info = v as? CodeBadgeInfo { badges.append(info.title); badgeRange = r } }
             if badgeRange.location != NSNotFound, let lm = tv.layoutManager {
                 let lineRect = lm.lineFragmentRect(forGlyphAt: lm.glyphIndexForCharacter(at: badgeRange.location), effectiveRange: nil)
                 let rect = CodeBadgeInfo(language: "swift").rect(in: lineRect)
                 let viewPoint = NSPoint(x: rect.midX + tv.textContainerOrigin.x, y: rect.midY + tv.textContainerOrigin.y)
                 let event = NSEvent.mouseEvent(with: .leftMouseDown, location: tv.convert(viewPoint, to: nil), modifierFlags: [], timestamp: 0,
                                                windowNumber: tv.window?.windowNumber ?? 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
                 tv.mouseDown(with: event); pump()
             }
             log("code-language-badge", md, "badges=\(badges) | \(b.text)", expect: "badges=[\"SWIFT\"] | Intro\n\n```python\nlet x = 1\n```") }

        // 25b. Syntax colours: whole-block tokens (a block comment across lines), placed after block-quote prefixes
        do { let md = "```js\nconst a = 1 /* one\ntwo */ + 2\n```\n\n> ```py\n> s = '''x\n> y'''\n> ```"
             let b = TextBox(md); let tv = makeEditor(b)
             let storage = tv.textStorage!
             let ns = storage.string as NSString
             func kind(of needle: String) -> String {
                 let r = ns.range(of: needle)
                 guard r.location != NSNotFound, let color = storage.attribute(.foregroundColor, at: r.location, effectiveRange: nil) as? NSColor else { return "missing" }
                 return CodeTokenKind.allCases.first { CodeHighlightTheme.color(for: $0) == color }?.rawValue ?? "plain"
             }
             let result = ["const", "1", "one", "two", "+", "2", "s =", "x", "y'''"].map { "\($0)=\(kind(of: $0))" }.joined(separator: " ")
             log("code-syntax-colours", md, result, expect: "const=keyword 1=number one=comment two=comment +=plain 2=number s ==plain x=string y'''=string") }

        // 26. Incremental restyling must match a full restyle exactly
        func fingerprint(_ tv: NSTextView) -> String {
            guard let storage = tv.textStorage else { return "" }
            var out = ""
            storage.enumerateAttributes(in: NSRange(location: 0, length: storage.length), options: []) { attrs, range, _ in
                let text = (storage.string as NSString).substring(with: range)
                var parts = [text.debugDescription]
                if let f = attrs[.font] as? NSFont { parts.append("\(f.fontName)@\(f.pointSize)") }
                if let c = attrs[.foregroundColor] as? NSColor { parts.append(c.description) }
                if let p = attrs[.paragraphStyle] as? NSParagraphStyle { parts.append("p\(p.headIndent)/\(p.firstLineHeadIndent)/\(p.tailIndent)/\(p.textBlocks.count)") }
                if let m = attrs[.listMarker] as? ListMarkerInfo { parts.append("m\(m.text)@\(m.indent)") }
                if attrs[.link] != nil { parts.append("link") }
                if attrs[.strikethroughStyle] != nil { parts.append("strike") }
                if let a = attrs[.attachment] { parts.append(a is TableTextAttachment ? "TABLE" : "IMAGE") }
                if attrs[.codeBadge] != nil { parts.append("badge") }
                out += parts.joined(separator: " ") + "\n"
            }
            return out
        }
        let base = "# Title\n\nIntro with **bold** and ![img](x.png) here.\n\n- one\n- two\n\n| A | B |\n|---|---|\n| 1 | 2 |\n\n> quote\n\n```swift\nlet x = 1\n```\n\nLast paragraph."
        let scenarios: [(String, String, String, Bool)] = [
            ("type in paragraph", "Intro with", " more", true),
            ("make bold", "Last", "**", true),
            ("open a fence", "Intro", "\n```\n", true),
            ("type in list", "- one", " item", true),
            ("new list item", "- two", "\n- three", true),
            ("setext underline", "Last paragraph.", "\n---", true),
            ("type in quote", "> quote", " text", true),
            ("before table", "- two", "\n\nPara before table", true),
            ("in code", "let x", "y", true),
            ("open block comment in code", "let x", " /*", true),
            ("open string in code", "let x =", " \"", true),
            ("at start", "# Title", "!", true),
            ("at end", "Last paragraph.", " End", true),
            ("add reference definition", "Last paragraph.", "\n\n[r]: https://r.com", false),
        ]
        for (name, anchor, insertion, expectIncremental) in scenarios {
            let b = TextBox(base); let tv = makeEditor(b)
            let coordinator = tv.delegate as! SwashTextView.Coordinator
            caretAfter(anchor, in: tv)
            let before = coordinator.incrementalPassCount
            tv.insertText(insertion, replacementRange: tv.selectedRange()); pump(0.3)
            let usedIncremental = coordinator.incrementalPassCount > before
            let incremental = fingerprint(tv)
            coordinator.forceFullRestyle = true
            coordinator.highlightMarkdown(in: tv); pump(0.1)
            let full = fingerprint(tv)
            let same = incremental == full
            log("incremental-\(name.replacingOccurrences(of: " ", with: "-"))", "\(anchor) + \(insertion.debugDescription)",
                "path=\(usedIncremental ? "incremental" : "full") matchesFull=\(same)",
                same ? "" : "first difference: \(zip(incremental.split(separator: "\n"), full.split(separator: "\n")).first(where: { $0 != $1 }).map { "\($0) vs \($1)" } ?? "length")",
                expect: "path=\(expectIncremental ? "incremental" : "full") matchesFull=true")
        }
        
        // A table cell edit (changing the table's length) keeps the next keystroke incremental
        do {
            let b = TextBox(base); let tv = makeEditor(b)
            let coordinator = tv.delegate as! SwashTextView.Coordinator
            var table: TableTextAttachment? = nil
            tv.textStorage!.enumerateAttribute(.attachment, in: NSRange(location: 0, length: tv.textStorage!.length), options: []) { v, _, stop in
                if let t = v as? TableTextAttachment { table = t; stop.pointee = true }
            }
            var data = table!.tableData
            data.rows[0][0] = "longer cell"
            table!.onUpdate?(data); pump(0.2)
            let textAfterCell = b.text
            caretAfter("Last paragraph.", in: tv)
            let before = coordinator.incrementalPassCount
            tv.insertText("!", replacementRange: tv.selectedRange()); pump(0.3)
            let usedIncremental = coordinator.incrementalPassCount > before
            let incremental = fingerprint(tv)
            coordinator.forceFullRestyle = true
            coordinator.highlightMarkdown(in: tv); pump(0.1)
            log("incremental-after-table-cell-edit", "cell 1 → \"longer cell\", then type",
                "path=\(usedIncremental ? "incremental" : "full") matchesFull=\(incremental == fingerprint(tv)) cellSaved=\(textAfterCell.contains("| longer cell |")) typed=\(b.text.hasSuffix("Last paragraph.!"))",
                expect: "path=incremental matchesFull=true cellSaved=true typed=true")
        }

        // Braces pair inside math and the closing one is stepped over; outside math they don't pair
        do {
            let b = TextBox("Energy $E=mc^$ here, {plain}"); let tv = makeEditor(b)
            caretAfter("mc^", in: tv)
            for ch in ["{", "2", "}"] { tv.insertText(ch, replacementRange: tv.selectedRange()); pump(0.2) }
            tv.insertText("!", replacementRange: tv.selectedRange()); pump(0.2)
            caretAfter("{plain", in: tv)
            tv.insertText("{", replacementRange: tv.selectedRange()); pump(0.2)
            log("math-brace-pairing", "type { 2 } ! inside $…$, then { outside", b.text, expect: "Energy $E=mc^{2}!$ here, {plain{}")
        }

        // 20. Enter on an empty item leaves the list; Backspace with the caret before the hidden marker
        do { let b = TextBox("- a\n- b"); let tv = makeEditor(b); caretAfter("b", in: tv)
             tv.doCommand(by: #selector(NSResponder.insertNewline(_:))); pump(); tv.doCommand(by: #selector(NSResponder.insertNewline(_:))); pump()
             tv.insertText("after", replacementRange: tv.selectedRange()); pump()
             log("enter-twice-exits-list", "- a\n- b", b.text, expect: "- a\n- b\n\nafter") }
        do { let b = TextBox("- item"); let tv = makeEditor(b); tv.setSelectedRange(NSRange(location: 0, length: 0))
             tv.doCommand(by: #selector(NSResponder.deleteBackward(_:))); pump()
             log("backspace-at-line-start-before-hidden-marker", "- item", b.text, expect: "item") }
        // 21. Structural edits are undoable
        do { let b = TextBox("- a"); let tv = makeEditor(b); caretAfter("a", in: tv)
             tv.doCommand(by: #selector(NSResponder.insertNewline(_:))); pump(); tv.undoManager?.undo(); pump()
             log("enter-continuation-undo", "- a", b.text, expect: "- a") }

        // 22. Split view: scrolling one pane scrolls the other directly, and a pane created later
        //     (a view-mode switch) starts at the shared position
        do { let sync = ScrollSync()
             func pane() -> NSScrollView {
                 let sv = NSScrollView(frame: NSRect(x: 0, y: 0, width: 300, height: 200))
                 sv.documentView = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 5000))
                 sv.contentView.postsBoundsChangedNotifications = true
                 NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: sv.contentView, queue: nil) { _ in
                     sync.scrollViewDidScroll(sv)
                 }
                 sync.register(sv); return sv
             }
             let editorPane = pane(), previewPane = pane(); pump()
             editorPane.contentView.scroll(to: NSPoint(x: 0, y: 420)); editorPane.reflectScrolledClipView(editorPane.contentView)
             let followed = previewPane.contentView.bounds.origin.y
             let laterPane = pane(); pump()
             log("split-scroll-sync", "scroll editor to 420", "preview=\(Int(followed)) newPane=\(Int(laterPane.contentView.bounds.origin.y))",
                 expect: "preview=420 newPane=420") }

        // 23. Preview: a vertical gesture that starts over a table or code block scrolls the preview,
        //     a horizontal one stays with the nested view, and mouse wheels are routed per event
        do { let filler = (1...30).map { "Paragraph \($0) of filler text." }.joined(separator: "\n\n")
             let md = filler + "\n\n```swift\nlet x = 1\n```\n\n| A | B |\n|---|---|\n| 1 | 2 |\n\n" + filler
             let host = NSHostingView(rootView: MarkdownPreviewView(text: md, flavor: .github).frame(width: 500, height: 600))
             host.frame = NSRect(x: 0, y: 0, width: 500, height: 600)
             let win = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
             win.contentView = host; windows.append(win)
             func allScrollViews(in v: NSView) -> [NSScrollView] { ((v as? NSScrollView).map { [$0] } ?? []) + v.subviews.flatMap(allScrollViews) }
             // Wait for the preview, its code block and its table to lay out (about 0.3–0.5 s on a busy
             // Mac) rather than a fixed time: until then the outer document is 0 pt tall
             let laidOut = Date().addingTimeInterval(3)
             repeat { pump(0.05) } while Date() < laidOut && !(allScrollViews(in: host).count >= 3
                 && allScrollViews(in: host).contains { ($0.documentView?.frame.height ?? 0) > host.frame.height })
             let all = allScrollViews(in: host)
             let outer = all.max { ($0.documentView?.frame.height ?? 0) < ($1.documentView?.frame.height ?? 0) }!
             let nested = all.filter { $0 !== outer && $0.isDescendant(of: outer) }
             // Bring the first nested view on screen and aim at its centre
             if let first = nested.first, let doc = outer.documentView {
                 let r = first.convert(first.bounds, to: doc)
                 outer.contentView.scroll(to: NSPoint(x: 0, y: max(0, r.midY - 300))); outer.reflectScrolledClipView(outer.contentView); pump()
             }
             let router = NestedScrollRouter(scrollView: outer)
             let overNested = nested.first.map { $0.convert(NSPoint(x: $0.bounds.midX, y: $0.bounds.midY), to: nil) } ?? .zero
             let overText = outer.convert(NSPoint(x: 250, y: outer.contentView.bounds.minY + 5), to: nil)
             let v = (dx: CGFloat(0), dy: CGFloat(-6)), h = (dx: CGFloat(-6), dy: CGFloat(1))
             func f(_ p: NSEvent.Phase, _ m: NSEvent.Phase = [], _ d: (dx: CGFloat, dy: CGFloat), _ at: NSPoint) -> String {
                 router.shouldForward(phase: p, momentumPhase: m, deltaX: d.dx, deltaY: d.dy, pointInWindow: at) ? "Y" : "n"
             }
             let gesture = [f(.began, [], v, overNested), f(.changed, [], h, overText), f([], .changed, v, overText), f([], .ended, v, overText), f([], .changed, v, overText)].joined()
             let horizontal = [f(.began, [], h, overNested), f(.changed, [], v, overNested)].joined()
             let wheel = [f([], [], v, overNested), f([], [], h, overNested), f([], [], v, overText)].joined()
             log("preview-nested-scroll-routing", "\(nested.count) nested scroll views", "gesture=\(gesture) horizontal=\(horizontal) wheel=\(wheel)",
                 expect: "gesture=YYYYn horizontal=nn wheel=Ynn") }

        // Callouts: change type, back to a plain quote, quote → callout, paragraph → callout
        do {
            func run(_ md: String, _ select: String, _ type: AlertType?) -> String {
                let r = (md as NSString).range(of: select)
                return MarkdownFormatting(text: md).setAlertType(type, selection: r)?.text ?? "nil"
            }
            log("callout-change-type", "> [!NOTE]\n> body", run("> [!NOTE]\n> body", "body", .warning), expect: "> [!WARNING]\n> body")
            log("callout-to-plain-quote", "> [!TIP]\n> body", run("> [!TIP]\n> body", "body", nil), expect: "> body")
            log("quote-to-callout", "> body", run("> body", "body", .tip), expect: "> [!TIP]\n> body")
            log("paragraph-to-callout", "one\ntwo", run("one\ntwo", "one\ntwo", .caution), expect: "> [!CAUTION]\n> one\n> two")
            let nested = "- item\n\n  > [!NOTE]\n  > body"
            log("callout-in-list-change-type", nested, run(nested, "body", .important), expect: "- item\n\n  > [!IMPORTANT]\n  > body")
            log("callout-type-detected", "> [!CAUTION]\n> body",
                "\(MarkdownFormatting(text: "> [!CAUTION]\n> body").alertType(at: NSRange(location: 15, length: 2)).map { "\($0)" } ?? "nil")", expect: "caution")
        }
        // Images: alt text, width (Markdown ↔ <img>), source
        do {
            var image = MarkdownImageSource(markdown: "![old alt](<pics/a b.png> \"T\")")!
            log("image-parse", "![old alt](<pics/a b.png> \"T\")", "\(image.source)|\(image.alt)|\(image.title ?? "-")|\(image.width.map(String.init) ?? "-")", expect: "pics/a b.png|old alt|T|-")
            image.alt = "new [alt]"
            log("image-alt", "", image.markdown, expect: "![new \\[alt\\]](<pics/a b.png> \"T\")")
            image.width = 200
            log("image-width", "", image.markdown, expect: "<img src=\"pics/a b.png\" alt=\"new [alt]\" title=\"T\" width=\"200\">")
            let reparsed = MarkdownImageSource(markdown: image.markdown)!
            log("image-width-roundtrip", "", "\(reparsed.source)|\(reparsed.alt)|\(reparsed.title ?? "-")|\(reparsed.width.map(String.init) ?? "-")", expect: "pics/a b.png|new [alt]|T|200")
            var plain = reparsed
            plain.width = nil
            plain.source = "x.png"
            log("image-original-size", "", plain.markdown, expect: "![new \\[alt\\]](x.png \"T\")")
            let doc = "Intro\n\n<img src=\"a.png\" alt=\"A\" width=\"200\">\n\nEnd"
            let r = (doc as NSString).range(of: "<img src=\"a.png\" alt=\"A\" width=\"200\">")
            log("image-html-block-found", doc, MarkdownFormatting(text: doc).image(exactly: r) != nil ? "found" : "missing", expect: "found")
            log("relative-image-source", "", MarkdownImageSource.source(for: URL(fileURLWithPath: "/docs/pics/my image.png"), relativeTo: URL(fileURLWithPath: "/docs/note.md")), expect: "pics/my%20image.png")
        }
        // An <img> on its own line (what resizing writes) shows as an image in the editor
        do {
            let b = TextBox("Intro\n\n<img src=\"missing.png\" alt=\"A\" width=\"200\">\n\nEnd"); let tv = makeEditor(b)
            var images = 0
            tv.textStorage!.enumerateAttribute(.attachment, in: NSRange(location: 0, length: tv.textStorage!.length), options: []) { v, _, _ in
                if v is ImageTextAttachment { images += 1 }
            }
            log("image-html-block-attachment", b.text, "images=\(images) roundtrip=\(b.text.contains("width=\"200\""))", expect: "images=1 roundtrip=true")
        }
        // Footnotes: insert numbering, lookup, delete
        do {
            let text = "See this[^1] and that.\n\n[^1]: First."
            let caret = (text as NSString).range(of: "that").location + 4
            let inserted = MarkdownFormatting(text: text).insertFootnote(selection: NSRange(location: caret, length: 0))
            log("footnote-insert", text, inserted.map { "\($0.text)|caret=\($0.selection.location == ($0.text as NSString).length)" } ?? "nil",
                expect: "See this[^1] and that[^2].\n\n[^1]: First.\n[^2]: |caret=true")
            let fresh = MarkdownFormatting(text: "Plain text").insertFootnote(selection: NSRange(location: 5, length: 0))?.text ?? "nil"
            log("footnote-insert-first", "Plain text", fresh, expect: "Plain[^1] text\n\n[^1]: ")
            let formatting = MarkdownFormatting(text: text)
            let onRef = formatting.footnote(at: NSRange(location: (text as NSString).range(of: "[^1]").location + 1, length: 0))
            let onDef = formatting.footnote(at: NSRange(location: (text as NSString).range(of: "First").location, length: 0))
            log("footnote-lookup", text, "ref=\(onRef.map { "\($0.label):\($0.isDefinition):\($0.definitionContent.map { (text as NSString).substring(with: $0) } ?? "-")" } ?? "nil") def=\(onDef.map { "\($0.isDefinition):\($0.references.count)" } ?? "nil")",
                expect: "ref=1:false:First. def=true:1")
            log("footnote-delete", text, formatting.deleteFootnote(label: "1", selection: NSRange(location: 0, length: 0))?.text ?? "nil", expect: "See this and that.\n\n")
            let slash = MarkdownEditingCommands.insertBlock(.footnote, text: "Hello /", slashLocation: 6)?.text ?? "nil"
            log("footnote-slash-menu", "Hello /", slash, expect: "Hello [^1]\n\n[^1]: ")
        }
        // Clicking a footnote reference shows its definition, and the definition's label goes back
        do {
            let b = TextBox("See this[^1] and that.\n\n[^1]: First."); let tv = makeEditor(b)
            let coordinator = tv.delegate as! SwashTextView.Coordinator
            coordinator.followFootnote(FootnoteLink(label: "1", isDefinition: false), in: tv); pump()
            let atDefinition = (tv.string as NSString).substring(from: tv.selectedRange().location).hasPrefix("First.")
            coordinator.followFootnote(FootnoteLink(label: "1", isDefinition: true), in: tv); pump()
            let atReference = (tv.string as NSString).substring(from: tv.selectedRange().location).hasPrefix("[^1] and")
            var tagged = 0
            tv.textStorage!.enumerateAttribute(.footnoteLink, in: NSRange(location: 0, length: tv.textStorage!.length), options: []) { v, _, _ in if v != nil { tagged += 1 } }
            log("footnote-navigation", b.text, "definition=\(atDefinition) reference=\(atReference) tagged=\(tagged)", expect: "definition=true reference=true tagged=2")
        }
        // Tables: editing a cell ends the editor's selection; typing after a table keeps its view;
        // the attachment is as tall as the table's content
        do {
            let b = TextBox("Intro text here.\n\n| A | B |\n|---|---|\n| 1 | 2 |\n\nAfter table."); let tv = makeEditor(b)
            tv.display(); pump(0.3)
            var table: TableTextAttachment? = nil
            tv.textStorage!.enumerateAttribute(.attachment, in: NSRange(location: 0, length: tv.textStorage!.length), options: []) { v, _, stop in
                if let t = v as? TableTextAttachment { table = t; stop.pointee = true }
            }
            let hosting = table?.cell.hostingView
            tv.setSelectedRange((tv.string as NSString).range(of: "Intro text")); pump()
            hosting?.rootView.onBeginEditing?(); pump()
            let collapsed = tv.selectedRange().length == 0
            let fits = hosting.map { abs($0.frame.height - ceil(max(44, $0.fittingSize.height))) < 1 } ?? false
            caretAfter("After table.", in: tv)
            tv.insertText(" More", replacementRange: tv.selectedRange()); pump(0.3)
            var after: TableTextAttachment? = nil
            tv.textStorage!.enumerateAttribute(.attachment, in: NSRange(location: 0, length: tv.textStorage!.length), options: []) { v, _, stop in
                if let t = v as? TableTextAttachment { after = t; stop.pointee = true }
            }
            log("table-cell-focus-and-reuse", b.text, "selectionCleared=\(collapsed) heightFits=\(fits) tableKept=\(after != nil && after === table)",
                expect: "selectionCleared=true heightFits=true tableKept=true")
        }

        // Focus mode and typewriter scrolling
        do { let text = "One sentence. Two three here. Four." as NSString
             let caret = NSRange(location: text.range(of: "three").location, length: 0)
             let sentence = text.substring(with: FocusUnit.range(.sentence, around: caret, in: text))
             let paragraph = text.substring(with: FocusUnit.range(.paragraph, around: caret, in: text))
             log("focus-range", text as String, "sentence=\(sentence) paragraph=\(paragraph)",
                 expect: "sentence=Two three here.  paragraph=One sentence. Two three here. Four.") }
        do { let b = TextBox("First **paragraph**.\n\nSecond paragraph.\n\nThird paragraph.")
             let tv = makeEditor(b, writing: WritingOptions(focus: .paragraph)); pump(0.3)
             caretAfter("Second", in: tv); pump()
             let storage = tv.string as NSString
             func dimmed(_ needle: String) -> String {
                 let at = storage.range(of: needle).location
                 return tv.layoutManager?.temporaryAttribute(.foregroundColor, atCharacterIndex: at, effectiveRange: nil) == nil ? "clear" : "dim"
             }
             let hiddenMarker = storage.range(of: "**").location
             let marker = hiddenMarker == NSNotFound ? "collapsed" :
                 (tv.layoutManager?.temporaryAttribute(.foregroundColor, atCharacterIndex: hiddenMarker, effectiveRange: nil) == nil ? "hidden" : "revealed")
             log("focus-dims-other-paragraphs", b.text, "first=\(dimmed("First")) second=\(dimmed("Second")) third=\(dimmed("Third")) marker=\(marker)",
                 expect: "first=dim second=clear third=dim marker=hidden") }
        do { let b = TextBox((1...120).map { "Line \($0)" }.joined(separator: "\n"))
             let tv = makeEditor(b, styled: false, writing: WritingOptions(typewriter: true)); pump(0.3)
             caretAfter("Line 70", in: tv); pump()
             let clip = tv.enclosingScrollView!.contentView
             let glyph = tv.layoutManager!.glyphIndexForCharacter(at: tv.selectedRange().location - 1)
             let line = tv.layoutManager!.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
             let offset = line.midY + tv.textContainerOrigin.y - clip.bounds.origin.y
             log("typewriter-centres-caret", "caret on line 70 of 120", abs(offset - clip.bounds.height / 2) < 2 ? "centred" : "offset \(offset) of \(clip.bounds.height)",
                 expect: "centred") }

        // Typography settings (font, text size, line width, theme)
        do { let t = EditorTypography()
             log("typography-defaults", "EditorTypography()",
                 "size=\(t.textSize) body=\(t.bodyFont == NSFont.systemFont(ofSize: 14)) source=\(t.sourceFont.pointSize) h1=\(t.scaled(MarkdownEditorStyler.headingSize(1))) accent=\(t.accentColor == .controlAccentColor) link=\(t.linkColor == .systemBlue) previewBody=\(t.previewFont() == .body) column=\(t.readableColumnWidth)",
                 expect: "size=14.0 body=true source=13.5 h1=24.0 accent=true link=true previewBody=true column=700.0") }
        do { let t = EditorTypography(font: .serif, textSize: 21)
             let serif = t.bodyFont.fontName.contains("NewYork")
             log("typography-scaled-values", "serif, 21 pt",
                 "scale=\(t.scale) h1=\(t.scaled(MarkdownEditorStyler.headingSize(1))) serif=\(serif) mono=\(EditorTypography(font: .mono).bodyFont.isFixedPitch) column=\(t.readableColumnWidth)",
                 expect: "scale=1.5 h1=36.0 serif=true mono=true column=1050.0") }
        do { // Styling uses the settings, and a change restyles the open editor in place
             let b = TextBox("# Title\n\nBody with `code` and [link](https://example.com).")
             let binding = Binding<String>(get: { b.text }, set: { b.text = $0 })
             func view(_ t: EditorTypography) -> some View {
                 SwashTextView(text: binding, selectedRange: .constant(nil), selectionRect: .constant(nil),
                               isStyled: true, flavor: .github, typography: t).frame(width: 600, height: 600)
             }
             let host = NSHostingView(rootView: view(EditorTypography()))
             host.frame = NSRect(x: 0, y: 0, width: 600, height: 600)
             let win = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
             win.contentView = host; windows.append(win); host.layoutSubtreeIfNeeded(); pump(0.3)
             let tv = findTextView(in: host)!
             func probe() -> String {
                 let s = tv.string as NSString, storage = tv.textStorage!
                 func font(_ needle: String) -> NSFont { storage.attribute(.font, at: s.range(of: needle).location, effectiveRange: nil) as! NSFont }
                 func color(_ needle: String) -> NSColor? { storage.attribute(.foregroundColor, at: s.range(of: needle).location, effectiveRange: nil) as? NSColor }
                 let serif = font("Body").fontName.contains("NewYork")
                 return "body=\(font("Body").pointSize)\(serif ? " serif" : "") h1=\(font("Title").pointSize) code=\(font("code").pointSize)\(font("code").isFixedPitch ? " mono" : "") codeTeal=\(color("code") == .systemTeal) linkTeal=\(color("link") == .systemTeal) paper=\(tv.backgroundColor == EditorTheme.paper.background)"
             }
             let before = probe()
             host.rootView = view(EditorTypography(font: .serif, textSize: 21, theme: .ocean)); pump(0.3)
             let after = probe()
             host.rootView = view(EditorTypography(theme: .paper)); pump(0.3)
             let paper = probe()
             log("typography-live-restyle", before, after + " | " + paper,
                 expect: "body=21.0 serif h1=36.0 code=20.0 mono codeTeal=true linkTeal=true paper=false | body=14.0 h1=24.0 code=13.0 mono codeTeal=false linkTeal=false paper=true")
             log("typography-default-styling", "default typography", before,
                 expect: "body=14.0 h1=24.0 code=13.0 mono codeTeal=false linkTeal=false paper=false") }
        do { // Source mode follows the text size, staying monospaced
             let b = TextBox("Plain source")
             let binding = Binding<String>(get: { b.text }, set: { b.text = $0 })
             let host = NSHostingView(rootView: SwashTextView(text: binding, selectedRange: .constant(nil), selectionRect: .constant(nil),
                                                              isStyled: false, flavor: .github, typography: EditorTypography(textSize: 28)).frame(width: 600, height: 600))
             host.frame = NSRect(x: 0, y: 0, width: 600, height: 600)
             let win = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
             win.contentView = host; windows.append(win); host.layoutSubtreeIfNeeded(); pump(0.3)
             let tv = findTextView(in: host)!
             let font = tv.textStorage!.attribute(.font, at: 0, effectiveRange: nil) as! NSFont
             log("typography-source-mode", "28 pt", "size=\(font.pointSize) mono=\(font.isFixedPitch)", expect: "size=27.0 mono=true") }
        do { // Readable column: the text is centred in a column, full width otherwise
             let b = TextBox("Some text")
             let full = makeEditor(b, writing: WritingOptions())
             let column = makeEditor(b, writing: WritingOptions(readableColumn: true, columnWidth: 300))
             let clip = column.enclosingScrollView!.contentView.bounds.width
             let expected = max(20, ((clip - 300) / 2).rounded())
             log("typography-readable-column", "column 300 in \(clip)", "full=\(full.textContainerInset.width) column=\(column.textContainerInset.width == expected)",
                 expect: "full=20.0 column=true") }
        do { // Preview: bigger text is taller; a readable column is narrower; blocks re-render when typography changes
             let md = (1...40).map { "Paragraph \($0) with enough words to wrap across the preview when the text gets larger, or when it is set in a readable column instead." }.joined(separator: "\n\n")
             /// Content height, and the left edge of the text (points) in a snapshot of the visible page.
             func measure(_ t: EditorTypography) -> (height: CGFloat, left: Int) {
                 let host = NSHostingView(rootView: MarkdownPreviewView(text: md, flavor: .github, typography: t).frame(width: 1200, height: 600))
                 host.frame = NSRect(x: 0, y: 0, width: 1200, height: 600)
                 let win = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
                 win.contentView = host; windows.append(win); pump(0.4)
                 func allScrollViews(in v: NSView) -> [NSScrollView] { ((v as? NSScrollView).map { [$0] } ?? []) + v.subviews.flatMap(allScrollViews) }
                 var left = -1
                 if let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                     host.cacheDisplay(in: host.bounds, to: rep)
                     let scale = CGFloat(rep.pixelsWide) / host.bounds.width
                     let background = rep.colorAt(x: 1, y: 1)?.usingColorSpace(.sRGB)
                     columns: for x in stride(from: 0, to: rep.pixelsWide, by: 2) {
                         for y in stride(from: 0, to: rep.pixelsHigh, by: 2) {
                             if let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB), let b = background,
                                abs(c.redComponent - b.redComponent) + abs(c.greenComponent - b.greenComponent) + abs(c.blueComponent - b.blueComponent) > 0.3 {
                                 left = Int(CGFloat(x) / scale); break columns
                             }
                         }
                     }
                 }
                 return (allScrollViews(in: host).compactMap { $0.documentView?.frame.height }.max() ?? 0, left)
             }
             let normal = measure(EditorTypography())
             let large = measure(EditorTypography(textSize: 22))
             let readable = measure(EditorTypography(lineWidth: .readable, theme: .forest))
             log("typography-preview-size", "40 paragraphs at 14 / 22 pt, and in a readable column",
                 "largerTaller=\(large.height > normal.height * 1.1) fullLeft=\(normal.left < 60) columnCentred=\(abs(readable.left - (1200 - 756) / 2 - 28) < 20)",
                 expect: "largerTaller=true fullLeft=true columnCentred=true")
             let document = MarkdownDocument.parse("Hello")
             let plain = MarkdownBlockView(node: document.root.children[0], context: MarkdownRenderContext(document: document, baseURL: nil))
             let themed = MarkdownBlockView(node: document.root.children[0], context: MarkdownRenderContext(document: document, baseURL: nil, typography: EditorTypography(theme: .rose)))
             log("typography-preview-block-equality", "same block, different theme", "equal=\(plain == themed) self=\(plain == plain)", expect: "equal=false self=true") }
        do { // View › Bigger / Smaller / Actual Size, and ⌘= in the editor
             let defaults = UserDefaults.standard
             defaults.removeObject(forKey: EditorTypography.Keys.textSize)
             EditorTypography.adjustTextSize(by: 1); let bigger = EditorTypography.current.textSize
             EditorTypography.adjustTextSize(by: -3); let smaller = EditorTypography.current.textSize
             for _ in 0..<40 { EditorTypography.adjustTextSize(by: 1) }; let capped = EditorTypography.current.textSize
             EditorTypography.adjustTextSize(by: 0); let reset = EditorTypography.current.textSize
             let b = TextBox("Zoom"); let tv = makeEditor(b)
             let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0, windowNumber: tv.window!.windowNumber,
                                          context: nil, characters: "=", charactersIgnoringModifiers: "=", isARepeat: false, keyCode: 24)!
             let handled = tv.performKeyEquivalent(with: event)
             let afterKey = EditorTypography.current.textSize
             defaults.removeObject(forKey: EditorTypography.Keys.textSize)
             log("typography-zoom", "14 → +1 → −3 → +40 → reset → ⌘=", "\(bigger) \(smaller) \(capped) \(reset) handled=\(handled) \(afterKey) text=\(b.text)",
                 expect: "15.0 12.0 32.0 14.0 handled=true 15.0 text=Zoom") }

        // Images pasted or dropped are copied beside the document and linked relatively
        do { let folder = FileManager.default.temporaryDirectory.appendingPathComponent("swash-images-\(UUID().uuidString)")
             try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
             let doc = folder.appendingPathComponent("Notes.md")
             let outside = FileManager.default.temporaryDirectory.appendingPathComponent("Holiday [1].png")
             let image = NSImage(size: NSSize(width: 2, height: 2), flipped: false) { NSColor.red.setFill(); $0.fill(); return true }
             let png = NSBitmapImageRep(data: image.tiffRepresentation!)!.representation(using: .png, properties: [:])!
             try? png.write(to: outside)
             UserDefaults.standard.removeObject(forKey: ImageInsertion.folderDefaultsKey)

             let b = TextBox("Before "); let tv = makeEditor(b, styled: false, baseURL: doc); caretAfter("Before ", in: tv)
             let pb = NSPasteboard.general; pb.clearContents(); pb.setData(png, forType: .png)
             tv.paste(nil); pump()
             let date = DateFormatter(); date.dateFormat = "yyyy-MM-dd"
             let pasted = b.text.hasPrefix("Before ![Pasted Image \(date.string(from: Date())) at ") && b.text.hasSuffix(".png)") && b.text.contains("](assets/Pasted%20Image%20")
             let files = (try? FileManager.default.contentsOfDirectory(atPath: folder.appendingPathComponent("assets").path)) ?? []
             log("paste-screenshot", "Before | + PNG data", "linked=\(pasted) files=\(files.count)", expect: "linked=true files=1")

             let b2 = TextBox(""); let tv2 = makeEditor(b2, styled: false, baseURL: doc)
             pb.clearContents(); pb.writeObjects([outside as NSURL]); tv2.paste(nil); pump()
             let copied = FileManager.default.fileExists(atPath: folder.appendingPathComponent("assets/Holiday [1].png").path)
             log("paste-image-file", "Holiday [1].png from outside the folder", "\(b2.text) copied=\(copied)",
                 expect: "![Holiday \\[1\\]](assets/Holiday%20%5B1%5D.png) copied=true")

             let inside = folder.appendingPathComponent("diagram.png"); try? png.write(to: inside)
             let b3 = TextBox(""); let tv3 = makeEditor(b3, styled: false, baseURL: doc)
             pb.clearContents(); pb.writeObjects([inside as NSURL]); tv3.paste(nil); pump()
             log("paste-image-in-folder", "diagram.png beside the document", b3.text, expect: "![diagram](diagram.png)")

             pb.clearContents(); pb.setString("plain text", forType: .string)
             log("paste-text-not-image", "string on the pasteboard", ImageInsertion.items(on: pb) == nil ? "text" : "image", expect: "text")
             pb.clearContents()
             try? FileManager.default.removeItem(at: folder); try? FileManager.default.removeItem(at: outside) }

        // Writing partner (#61): fixes as you type, each its own undo step
        do { let defaults = UserDefaults.standard
             let savedMode = defaults.string(forKey: WritingPartnerDefaults.mode)
             let savedStats = defaults.data(forKey: WritingPartnerDefaults.stats)
             let savedChatStats = defaults.data(forKey: WritingPartnerDefaults.chatStats)
             // The first-run introduction (#112) holds the partner until it's answered
             let savedIntroShown = defaults.object(forKey: WritingPartnerDefaults.introShown)
             WritingPartnerDefaults.setIntroShown(true, defaults)
             defaults.removeObject(forKey: WritingPartnerDefaults.stats)
             defaults.removeObject(forKey: WritingPartnerDefaults.chatStats)
             func typeEach(_ text: String, into tv: NSTextView) {
                 for ch in text { tv.insertText(String(ch), replacementRange: tv.selectedRange()); pump(0.05) }
                 waitForPartner(tv)
             }
             for styled in [true, false] {
                 let mode = styled ? "styled" : "source"
                 defaults.set(WritingPartnerMode.off.rawValue, forKey: WritingPartnerDefaults.mode)
                 let off = TextBox(""); let tvOff = makeEditor(off, styled: styled)
                 typeEach("so i dont know ", into: tvOff)
                 log("writing-partner-off-\(mode)", "", off.text, expect: "so i dont know ")

                 defaults.set(WritingPartnerMode.automatic.rawValue, forKey: WritingPartnerDefaults.mode)
                 let b = TextBox(""); let tv = makeEditor(b, styled: styled)
                 typeEach("so i dont know. it works ", into: tv)
                 log("writing-partner-types-\(mode)", "", b.text, expect: "So I don't know. It works ")
                 let caret = tv.selectedRange().location == (tv.string as NSString).length
                 log("writing-partner-caret-\(mode)", "", "atEnd=\(caret)", expect: "atEnd=true")
                 // Undo straight after a fix undoes only the fix, and the caret goes back to the end
                 typeEach("then i ", into: tv)
                 tv.undoManager?.undo(); pump(0.3)
                 typeEach("x", into: tv)
                 log("writing-partner-undo-\(mode)", "", b.text, expect: "So I don't know. It works then i x")

                 let code = TextBox("Text\n\n```\n```"); let tvCode = makeEditor(code, styled: styled)
                 caretAfter("```\n", in: tvCode)
                 typeEach("dont i ", into: tvCode)
                 log("writing-partner-skips-code-\(mode)", "", "\(code.text.contains("dont i ")) \(code.text.contains("don't") || code.text.contains(" I "))",
                     expect: "true false")
             }
             // Each line is a sentence, at normal speed and typed faster than the run loop turns
             let lines = "It's really interesting becuase I dont know how to do this any more\nwhat could be happenign here\nthis should be capitilised but isnt\n"
             let linesFixed = "It's really interesting becuase I don't know how to do this any more.\nWhat could be happenign here?\nThis should be capitilised but isn't.\n"
             // These check punctuation: spelling (on by default, from the system's spell checker) is off
             defaults.set(false, forKey: WritingPartnerDefaults.spelling)
             for styled in [true, false] {
                 let mode = styled ? "styled" : "source"
                 defaults.removeObject(forKey: WritingPartnerDefaults.stats)
                 let normal = TextBox(""); let tvNormal = makeEditor(normal, styled: styled)
                 typeEach(lines, into: tvNormal)
                 log("writing-partner-lines-\(mode)", lines, normal.text, expect: linesFixed)
                 log("writing-partner-no-inline-predictions-\(mode)", "", "\(tvNormal.inlinePredictionType == .no)", expect: "true")
                 let fast = TextBox(""); let tvFast = makeEditor(fast, styled: styled)
                 for ch in lines { tvFast.insertText(String(ch), replacementRange: tvFast.selectedRange()) }
                 waitForPartner(tvFast)
                 log("writing-partner-fast-\(mode)", lines, fast.text, expect: linesFixed)
             }
             // The partner's cursor and selection show while a fix is on its way, and go afterwards:
             // in the default style (the ribbon, which plays on for a moment after the fix lands)
             // and in another (#100)
             let savedStyle = defaults.string(forKey: WritingPartnerDefaults.style)
             for style in [WritingPartnerDefaults.defaultStyle, "soft-sweep"] {
                 defaults.removeObject(forKey: WritingPartnerDefaults.stats)
                 if style == WritingPartnerDefaults.defaultStyle { defaults.removeObject(forKey: WritingPartnerDefaults.style) }
                 else { defaults.set(style, forKey: WritingPartnerDefaults.style) }
                 let v = TextBox(""); let tvV = makeEditor(v, styled: true)
                 for ch in "so i " { tvV.insertText(String(ch), replacementRange: tvV.selectedRange()) }
                 pump(0.08)
                 let overlay = tvV.subviews.compactMap { $0 as? WritingPartnerOverlay }.first
                 let during = overlay?.layer?.sublayers?.count ?? 0
                 let textDuring = v.text
                 waitForPartner(tvV); pump(0.45)
                 let landing = overlay?.layer?.sublayers?.count ?? 0
                 // The layers behind the text are drawn by the text view, under its glyphs: a picture
                 // of the editor mid-landing shows the ribbon passing under the letters
                 let under = overlay?.drawsUnderText ?? false
                 if style == WritingPartnerDefaults.defaultStyle, let rep = tvV.bitmapImageRepForCachingDisplay(in: tvV.bounds) {
                     tvV.cacheDisplay(in: tvV.bounds, to: rep)
                     try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "build/editor-audit/partner-landing.png"))
                     // And without the overlay: only what the text view drew under its glyphs
                     overlay?.isHidden = true
                     if let underOnly = tvV.bitmapImageRepForCachingDisplay(in: tvV.bounds) {
                         tvV.cacheDisplay(in: tvV.bounds, to: underOnly)
                         try? underOnly.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "build/editor-audit/partner-landing-under.png"))
                     }
                     overlay?.isHidden = false
                 }
                 pump(2.6)
                 let afterwards = overlay?.layer?.sublayers?.count ?? 0
                 log("writing-partner-cursor-\(style)", "so i ",
                     "during=\(during > 0) unchangedYet=\(textDuring == "so i ") landing=\(landing > 0) under=\(under) afterwards=\(afterwards) text=\(v.text)",
                     expect: "during=true unchangedYet=true landing=true under=true afterwards=0 text=So I ")
             }
             // The partner's colours follow the editor's own appearance. A system colour read from
             // its timer resolves in the appearance the thread last drew in (after the system
             // switches between Light and Dark that can be the other one), and the page colour it
             // covers the old word with was then the Dark Mode one in a light window.
             for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", NSAppearance.Name.darkAqua)] {
                 let v = TextBox("so I "); let tvV = makeEditor(v, styled: true)
                 tvV.appearance = NSAppearance(named: appearance)
                 NSAppearance.current = NSAppearance(named: appearance == .aqua ? .darkAqua : .aqua)
                 let page = WritingPartnerOverlay.rgba(tvV.backgroundColor, in: tvV)?.r ?? -1
                 let ink = WritingPartnerOverlay.rgba(tvV.textColor, in: tvV)?.r ?? -1
                 let stale = WritingPartnerOverlay.rgba(tvV.backgroundColor)?.r ?? -1
                 let ok = name == "light" ? (page > 0.9 && ink < 0.2) : (page < 0.3 && ink > 0.8)
                 log("writing-partner-colours-\(name)", "so I ", "page and text as the editor shows them=\(ok) (read without its appearance, the page is \(stale > 0.5 ? "light" : "dark"))",
                     expect: "page and text as the editor shows them=true (read without its appearance, the page is \(name == "light" ? "dark" : "light"))")
             }
             if let savedStyle { defaults.set(savedStyle, forKey: WritingPartnerDefaults.style) } else { defaults.removeObject(forKey: WritingPartnerDefaults.style) }
             // The partner takes over autocorrect: spelling fixes come from the system spell checker,
             // through the partner, and the text view's own autocorrect is off while it's on
             for styled in [true, false] {
                 let mode = styled ? "styled" : "source"
                 defaults.removeObject(forKey: WritingPartnerDefaults.stats)
                 defaults.set(true, forKey: WritingPartnerDefaults.spelling)
                 let sp = TextBox(""); let tvSp = makeEditor(sp, styled: styled)
                 tvSp.isAutomaticSpellingCorrectionEnabled = true
                 typeEach("teh dog came because i said so\n", into: tvSp)
                 log("writing-partner-spelling-\(mode)", "", "\(sp.text) systemAutocorrect=\(tvSp.isAutomaticSpellingCorrectionEnabled)",
                     expect: "The dog came because I said so.\n systemAutocorrect=false")
                 // Undoing a spelling fix leaves that word alone from then on
                 typeEach("then hte ", into: tvSp); tvSp.undoManager?.undo(); pump(0.3)
                 typeEach("x hte ", into: tvSp)
                 log("writing-partner-spelling-undo-\(mode)", "", sp.text, expect: "The dog came because I said so.\nThen hte x hte ")
                 // Off, the text view's own autocorrect comes back
                 defaults.set(WritingPartnerMode.off.rawValue, forKey: WritingPartnerDefaults.mode)
                 typeEach("a", into: tvSp)
                 log("writing-partner-autocorrect-restored-\(mode)", "", "\(tvSp.isAutomaticSpellingCorrectionEnabled)", expect: "true")
                 defaults.set(WritingPartnerMode.automatic.rawValue, forKey: WritingPartnerDefaults.mode)
                 defaults.set(false, forKey: WritingPartnerDefaults.spelling)
             }
             // Two undos in a row stop a rule. These cases repeat "dont" on purpose, so Doubled
             // words (#111) is off until the cleanup below.
             defaults.set(false, forKey: WritingPartnerDefaults.doubledWords)
             defaults.removeObject(forKey: WritingPartnerDefaults.stats)
             defaults.set(WritingPartnerMode.automatic.rawValue, forKey: WritingPartnerDefaults.mode)
             defaults.set(false, forKey: WritingPartnerDefaults.spelling)
             let learn = TextBox(""); let tvLearn = makeEditor(learn, styled: false)
             typeEach("I dont ", into: tvLearn); tvLearn.undoManager?.undo(); pump()
             typeEach("dont ", into: tvLearn); tvLearn.undoManager?.undo(); pump()
             typeEach("dont ", into: tvLearn)
             let stats = WritingPartnerStats.load()
             log("writing-partner-learns", "", "\(learn.text) contraction=\(stats.isActive(.contraction))",
                 expect: "I dont dont dont  contraction=false")

             // Formatting voice (#113): a block is tidied once the caret has left it, each fix its own
             // undo step, and in Source view only when that's turned on
             defaults.removeObject(forKey: WritingPartnerDefaults.stats)
             defaults.removeObject(forKey: WritingPartnerDefaults.formattingInSource)
             for (styled, inSource) in [(true, false), (false, false), (false, true)] {
                 let mode = styled ? "styled" : (inSource ? "source-on" : "source")
                 defaults.set(inSource, forKey: WritingPartnerDefaults.formattingInSource)
                 let fmt = TextBox("1. Alpha\n3. Beta\n\nThe end"); let tvFmt = makeEditor(fmt, styled: styled)
                 caretAfter("Beta", in: tvFmt)
                 typeEach("s", into: tvFmt)
                 log("writing-partner-format-waits-\(mode)", "type in the list", fmt.text, expect: "1. Alpha\n3. Betas\n\nThe end")
                 tvFmt.setSelectedRange(NSRange(location: (tvFmt.string as NSString).length, length: 0)); waitForPartner(tvFmt)
                 let tidiedList = styled || inSource ? "1. Alpha\n2. Betas\n\nThe end" : "1. Alpha\n3. Betas\n\nThe end"
                 log("writing-partner-format-leaves-\(mode)", "caret to the end", fmt.text, expect: tidiedList)
                 if styled || inSource {
                     log("writing-partner-format-undo-name-\(mode)", "", tvFmt.undoManager?.undoActionName ?? "", expect: "Formatting")
                     tvFmt.undoManager?.undo(); pump(0.3)
                     log("writing-partner-format-undo-\(mode)", "⌘Z", fmt.text, expect: "1. Alpha\n3. Betas\n\nThe end")
                 }
             }
             defaults.removeObject(forKey: WritingPartnerDefaults.formattingInSource)
             // Two fixes in one block are two undo steps
             defaults.removeObject(forKey: WritingPartnerDefaults.stats)
             let two = TextBox("Say `hell`o and hello  world\n\nThe end"); let tvTwo = makeEditor(two)
             caretAfter("world", in: tvTwo)
             typeEach("s", into: tvTwo)
             tvTwo.setSelectedRange(NSRange(location: (tvTwo.string as NSString).length, length: 0)); waitForPartner(tvTwo)
             log("writing-partner-format-two-fixes", "", two.text, expect: "Say `hello` and hello worlds\n\nThe end")
             tvTwo.undoManager?.undo(); pump(0.3)
             log("writing-partner-format-two-fixes-undo", "⌘Z once", two.text, expect: "Say `hello` and hello  worlds\n\nThe end")
             let learnedFormatting = WritingPartnerStats.load().weight(.formatSpacing) < 1
             log("writing-partner-format-learns", "", "spacing weight lowered=\(learnedFormatting)", expect: "spacing weight lowered=true")

             // Suggest mode (#103): offers fixes without changing the text; accepted by keyboard,
             // pointer, VoiceOver rotor or Edit menu, and dismissed by Esc or typing past
             defaults.set(WritingPartnerMode.suggest.rawValue, forKey: WritingPartnerDefaults.mode)
             defaults.set(false, forKey: WritingPartnerDefaults.spelling)
             for styled in [true, false] {
                 let mode = styled ? "styled" : "source"

                 // 1. Drawn without changing the text; accepted with Tab (or ⌥⏎); undone as its own step
                 defaults.removeObject(forKey: WritingPartnerDefaults.stats)
                 let b = TextBox(""); let tv = makeEditor(b, styled: styled)
                 let coordinator = tv.delegate as! SwashTextView.Coordinator
                 typeEach("I dont ", into: tv)
                 let overlay = tv.subviews.compactMap { $0 as? WritingPartnerOverlay }.first
                 let offered = coordinator.writingPartner.suggestions.map { "\($0.edit.original)->\($0.edit.replacement)" }.joined(separator: ",")
                 log("writing-partner-suggest-drawn-\(mode)", "I dont ",
                     "text=\(b.text) layers=\(overlay?.suggestionLayers.count ?? 0) offered=\(offered)",
                     expect: "text=I dont  layers=1 offered=dont->don't")

                 tv.doCommand(by: #selector(NSResponder.insertTab(_:)))
                 waitForPartner(tv)
                 log("writing-partner-suggest-accept-key-\(mode)", "Tab after 'I dont '",
                     "text=\(b.text) layers=\(overlay?.suggestionLayers.count ?? 0)",
                     expect: "text=I don't  layers=0")

                 tv.undoManager?.undo(); pump(0.3)
                 typeEach("x", into: tv)
                 log("writing-partner-suggest-undo-\(mode)", "⌘Z then type 'x'", b.text, expect: "I dont x")

                 // Option-Return (⌥⏎) also accepts a suggestion
                 let optB = TextBox(""); let tvOpt = makeEditor(optB, styled: styled)
                 typeEach("so ", into: tvOpt)
                 tvOpt.doCommand(by: #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)))
                 waitForPartner(tvOpt)
                 log("writing-partner-suggest-accept-option-return-\(mode)", "⌥⏎ after 'so '", optB.text, expect: "So ")

                 // 2. Clicking the suggested word accepts it (and shows the pointing hand cursor)
                 defaults.removeObject(forKey: WritingPartnerDefaults.stats)
                 let clickB = TextBox(""); let tvClick = makeEditor(clickB, styled: styled)
                 let clickCoord = tvClick.delegate as! SwashTextView.Coordinator
                 typeEach("I dont ", into: tvClick)
                 let storageRange = clickCoord.storageRange(forRaw: clickCoord.writingPartner.suggestions[0].edit.range, in: tvClick)
                 let rect = WritingPartnerOverlay.rects(for: storageRange, in: tvClick)[0]
                 let viewPoint = NSPoint(x: rect.midX, y: rect.midY)
                 let hand = (tvClick as? SwashNSTextView)?.overrideCursor(at: viewPoint) == .pointingHand
                 let clickEvent = NSEvent.mouseEvent(with: .leftMouseDown, location: tvClick.convert(viewPoint, to: nil),
                                                     modifierFlags: [], timestamp: 0, windowNumber: tvClick.window?.windowNumber ?? 0,
                                                     context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
                 tvClick.mouseDown(with: clickEvent)
                 waitForPartner(tvClick)
                 let clickOverlay = tvClick.subviews.compactMap { $0 as? WritingPartnerOverlay }.first
                 log("writing-partner-suggest-accept-pointer-\(mode)", "click 'dont'",
                     "hand=\(hand) text=\(clickB.text) layers=\(clickOverlay?.suggestionLayers.count ?? 0)",
                     expect: "hand=true text=I don't  layers=0")

                 // 3. Dismissing with Esc removes the suggestion and counts against its rule
                 defaults.removeObject(forKey: WritingPartnerDefaults.stats)
                 let escB = TextBox(""); let tvEsc = makeEditor(escB, styled: styled)
                 typeEach("I dont ", into: tvEsc)
                 tvEsc.doCommand(by: #selector(NSResponder.cancelOperation(_:))); pump(0.05)
                 let escOverlay = tvEsc.subviews.compactMap { $0 as? WritingPartnerOverlay }.first
                 let layersAfterFirstEsc = escOverlay?.suggestionLayers.count ?? 0
                 typeEach("dont ", into: tvEsc)
                 tvEsc.doCommand(by: #selector(NSResponder.cancelOperation(_:))); pump(0.05)
                 typeEach("dont ", into: tvEsc)
                 let escCoord = tvEsc.delegate as! SwashTextView.Coordinator
                 let escStats = WritingPartnerStats.load()
                 log("writing-partner-suggest-dismiss-esc-\(mode)", "Esc twice on 'dont'",
                     "afterFirst=\(layersAfterFirstEsc) text=\(escB.text) active=\(escStats.isActive(.contraction)) thirdOffered=\(!escCoord.writingPartner.suggestions.isEmpty)",
                     expect: "afterFirst=0 text=I dont dont dont  active=false thirdOffered=false")

                 // 4. Typing on keeps a suggestion on offer; typing well past it (more than
                 //    `suggestionReach` characters) dismisses it and counts against its rule
                 defaults.removeObject(forKey: WritingPartnerDefaults.stats)
                 let pastB = TextBox(""); let tvPast = makeEditor(pastB, styled: styled)
                 let filler = "know what to do about this whole thing now "
                 typeEach("I dont ", into: tvPast)
                 typeEach("know ", into: tvPast)
                 let pastCoord = tvPast.delegate as! SwashTextView.Coordinator
                 let stillOffered = !pastCoord.writingPartner.suggestions.isEmpty
                 typeEach(String(filler.dropFirst(5)), into: tvPast)
                 typeEach("dont ", into: tvPast)
                 typeEach(filler, into: tvPast)
                 typeEach("dont ", into: tvPast)
                 let pastStats = WritingPartnerStats.load()
                 log("writing-partner-suggest-dismiss-typing-past-\(mode)", "keep typing well past 'dont' twice",
                     "stillOfferedAfterAWord=\(stillOffered) text=\(pastB.text) active=\(pastStats.isActive(.contraction)) thirdOffered=\(!pastCoord.writingPartner.suggestions.isEmpty)",
                     expect: "stillOfferedAfterAWord=true text=I dont \(filler)dont \(filler)dont  active=false thirdOffered=false")

                 // 5. Editing the suggested word makes the suggestion disappear without penalising the rule
                 defaults.removeObject(forKey: WritingPartnerDefaults.stats)
                 let editB = TextBox(""); let tvEdit = makeEditor(editB, styled: styled)
                 typeEach("I dont ", into: tvEdit)
                 tvEdit.doCommand(by: #selector(NSResponder.deleteBackward(_:))); pump(0.05)
                 tvEdit.doCommand(by: #selector(NSResponder.deleteBackward(_:))); pump(0.05)
                 let editOverlay = tvEdit.subviews.compactMap { $0 as? WritingPartnerOverlay }.first
                 let editStats = WritingPartnerStats.load()
                 log("writing-partner-suggest-edit-disappears-\(mode)", "backspace into 'dont'",
                     "text=\(editB.text) layers=\(editOverlay?.suggestionLayers.count ?? 0) weight=\(editStats.weight(.contraction))",
                     expect: "text=I don layers=0 weight=1.0")

                 // 6. VoiceOver announcement, Suggestions rotor and Edit menu acceptance
                 defaults.removeObject(forKey: WritingPartnerDefaults.stats)
                 let voB = TextBox(""); let tvVO = makeEditor(voB, styled: styled)
                 let voCoord = tvVO.delegate as! SwashTextView.Coordinator
                 typeEach("I dont ", into: tvVO)
                 let announced = voCoord.writingPartner.lastAnnouncement ?? ""
                 let rotor = tvVO.accessibilityCustomRotors().first { $0.label == "Suggestions" }
                 let item = rotor.flatMap { $0.itemSearchDelegate?.rotor($0, resultFor: NSAccessibilityCustomRotor.SearchParameters()) }
                 if let range = item?.targetRange { tvVO.setSelectedRange(range) }
                 (tvVO as? SwashNSTextView)?.acceptSuggestion(nil)
                 waitForPartner(tvVO)
                 log("writing-partner-suggest-voiceover-\(mode)", "rotor + Edit › Accept Suggestion",
                     "announced=\(announced) rotor=\(item?.customLabel ?? "nil") text=\(voB.text)",
                     expect: "announced=Suggestion: don't for dont rotor=dont → don't text=I don't ")
             }
             // Slack flavour (#105): the Chat voice fixes apostrophes and capital I, leaves lowercase
             // starts, message ends, ok, lol, :emoji: and Slack syntax alone, and learns separately
             defaults.removeObject(forKey: WritingPartnerDefaults.stats)
             defaults.removeObject(forKey: WritingPartnerDefaults.chatStats)
             // The Suggest-mode cases above leave the mode on Suggest
             defaults.set(WritingPartnerMode.automatic.rawValue, forKey: WritingPartnerDefaults.mode)
             for styled in [true, false] {
                 let mode = styled ? "styled" : "source"
                 let slack = TextBox(""); let tvSlack = makeEditor(slack, styled: styled, flavor: .slack)
                 typeEach("ok lol <@U123> <#C456|dont> <!here> :thumbsup: <https://x.y|dont i> *dont* _i dont_ ~cant~ i tried but it failed\n", into: tvSlack)
                 log("writing-partner-slack-\(mode)", "", slack.text,
                     expect: "ok lol <@U123> <#C456|dont> <!here> :thumbsup: <https://x.y|dont i> *dont* _i dont_ ~cant~ I tried but it failed\n")
             }
             // Undoing capital I twice in Slack stops it in Chat without stopping it in prose documents
             defaults.removeObject(forKey: WritingPartnerDefaults.stats)
             defaults.removeObject(forKey: WritingPartnerDefaults.chatStats)
             let slackUndo = TextBox(""); let tvSlackUndo = makeEditor(slackUndo, styled: false, flavor: .slack)
             typeEach("so i ", into: tvSlackUndo); tvSlackUndo.undoManager?.undo(); pump()
             typeEach("i ", into: tvSlackUndo); tvSlackUndo.undoManager?.undo(); pump()
             typeEach("i dont ", into: tvSlackUndo)
             let proseAfterSlack = TextBox(""); let tvProseAfterSlack = makeEditor(proseAfterSlack, styled: false, flavor: .github)
             typeEach("so i ", into: tvProseAfterSlack)
             let chatLearned = WritingPartnerStats.load(voice: .chat)
             let proseLearned = WritingPartnerStats.load(voice: .punctuate)
             log("writing-partner-slack-separate-stats", "",
                 "slack=\(slackUndo.text) prose=\(proseAfterSlack.text) chatI=\(chatLearned.isActive(.pronounI)) proseI=\(proseLearned.isActive(.pronounI))",
                 expect: "slack=so i i i don't  prose=So I  chatI=false proseI=true")

             // Subscription pause tier (#120): applies certain spelling & team-term suggestions at once
             // through the partner's cursor, offers uncertain ones as in Suggest mode, learns vocabulary,
             // and reports accepted/undone/dismissed feedback.
             do {
                 defaults.removeObject(forKey: WritingPartnerDefaults.stats)
                 defaults.set(WritingPartnerMode.automatic.rawValue, forKey: WritingPartnerDefaults.mode)
                 defaults.set(true, forKey: WritingPartnerDefaults.spelling)

                 let initial = "We use pixerate form their on Uchiage."
                 let box = TextBox(initial)
                 let tv = makeEditor(box, styled: false)
                 let coord = tv.delegate as! SwashTextView.Coordinator
                 caretAfter(initial, in: tv)

                 let stub = StubWritingBandleader { req in
                     let ns = req.paragraph as NSString
                     var suggestions: [JazzTextSuggestion] = []
                     let pixRange = ns.range(of: "pixerate")
                     if pixRange.location != NSNotFound {
                         suggestions.append(JazzTextSuggestion(
                             id: "sug-term-pixerate",
                             kind: .houseStyle,
                             range: JazzTextRange(start: pixRange.location, end: NSMaxRange(pixRange)),
                             replacement: "Pixerate",
                             why: "Team term casing",
                             confidence: 0.98,
                             applyAtOnce: true,
                             checkId: "terms.pixerate"
                         ))
                     }
                     let formRange = ns.range(of: "form")
                     if formRange.location != NSNotFound {
                         suggestions.append(JazzTextSuggestion(
                             id: "sug-wrong-form",
                             kind: .wrongWord,
                             range: JazzTextRange(start: formRange.location, end: NSMaxRange(formRange)),
                             replacement: "from",
                             why: "Wrong word in context",
                             confidence: 0.93,
                             applyAtOnce: true
                         ))
                     }
                     let theirRange = ns.range(of: "their")
                     if theirRange.location != NSNotFound {
                         suggestions.append(JazzTextSuggestion(
                             id: "sug-offer-their",
                             kind: .wrongWord,
                             range: JazzTextRange(start: theirRange.location, end: NSMaxRange(theirRange)),
                             replacement: "there",
                             why: "Possible wrong word",
                             confidence: 0.65,
                             applyAtOnce: false
                         ))
                     }
                     return JazzTextLeadResponse(
                         genre: .prose,
                         palette: [JazzTextVoice(voice: .punctuate, strength: 1.0)],
                         suggestions: suggestions,
                         vocabulary: ["Uchiage"],
                         why: "Team terms and spelling"
                     )
                 }

                 let detector = WritingPauseDetector(pauseDelay: 0)
                 detector.noteTyping(
                     character: 0x2E,
                     paragraph: initial,
                     range: NSRange(location: 0, length: (initial as NSString).length),
                     caret: (initial as NSString).length
                 )
                 coord.writingPartner.setBandleaderForTesting(stub)
                 coord.writingPartner.setPauseDetectorForTesting(detector)
                 coord.writingPartner.triggerPauseCheckForTesting(in: tv, coordinator: coord)
                 waitForPartner(tv)

                 // In Automatically an unsure fix is marked (#128) rather than offered: count both
                 let offeredAfterPause = (coord.writingPartner.suggestions.map { "\($0.edit.original)->\($0.edit.replacement)" }
                     + coord.writingPartner.marks.map { "\($0.original)->\($0.candidates[0])" }).joined(separator: ",")
                 let vocabKnown = coord.writingPartner.sessionMemoryForTesting.isKnownWord("Uchiage")
                 let acceptedIds = stub.feedbackItems.filter { $0.outcome == .accepted }.map(\.suggestionId).joined(separator: ",")
                 log("writing-partner-bandleader-spelling-pause", initial,
                     "text=\(box.text) offered=\(offeredAfterPause) vocab=\(vocabKnown) accepted=\(acceptedIds)",
                     expect: "text=We use Pixerate from their on Uchiage. offered=their->there vocab=true accepted=sug-term-pixerate,sug-wrong-form")

                 // Accept the offered uncertain suggestion with Tab -> plays through cursor and reports .accepted
                 caretAfter("their", in: tv)
                 tv.doCommand(by: #selector(NSResponder.insertTab(_:)))
                 waitForPartner(tv)
                 let acceptedAfterTab = stub.feedbackItems.filter { $0.outcome == .accepted }.map(\.suggestionId).joined(separator: ",")
                 log("writing-partner-bandleader-spelling-accept", "Tab on offered 'their'",
                     "text=\(box.text) offered=\(coord.writingPartner.suggestions.count) accepted=\(acceptedAfterTab)",
                     expect: "text=We use Pixerate from there on Uchiage. offered=0 accepted=sug-term-pixerate,sug-wrong-form,sug-offer-their")

                 // Undo the accepted suggestion -> reverts to 'their' and reports .undone
                 tv.undoManager?.undo(); pump(0.3)
                 waitForPartner(tv)
                 let lastFeedback = stub.feedbackItems.last.map { "\($0.suggestionId):\($0.outcome.rawValue)" } ?? "none"
                 log("writing-partner-bandleader-spelling-undo", "⌘Z after accepting 'there'",
                     "text=\(box.text) lastFeedback=\(lastFeedback)",
                     expect: "text=We use Pixerate from their on Uchiage. lastFeedback=sug-offer-their:undone")
             }

             // Context-aware spelling on device (#98): the model's corrections, judged by ContextSpelling,
             // play through the partner's cursor without moving the caret; low-confidence ones are only
             // offered; a misspelling that recurs in the document is left alone
             do {
                 defaults.removeObject(forKey: WritingPartnerDefaults.stats)
                 defaults.set(WritingPartnerMode.automatic.rawValue, forKey: WritingPartnerDefaults.mode)
                 defaults.set(true, forKey: WritingPartnerDefaults.spelling)
                 let initial = "Send it form home so we dont loose the colur, and the colur."
                 let box = TextBox(initial)
                 let tv = makeEditor(box, styled: false)
                 let coord = tv.delegate as! SwashTextView.Coordinator
                 caretAfter(initial, in: tv)
                 let caretBefore = tv.selectedRange().location
                 let stub = StubWritingBandleader { req in
                     JazzTextLeadResponse(
                         genre: .prose,
                         palette: [JazzTextVoice(voice: .punctuate, strength: 1.0)],
                         suggestions: ContextSpelling.suggestions(from: [
                             ContextSpellingCandidate(kind: .wrongWord, original: "form", replacement: "from", confidence: 0.95),
                             ContextSpellingCandidate(kind: .wrongWord, original: "loose", replacement: "lose", confidence: 0.6),
                             ContextSpellingCandidate(kind: .spelling, original: "colur", replacement: "colour", confidence: 0.9),
                         ], paragraph: req.paragraph),
                         why: "Context spelling"
                     )
                 }
                 let detector = WritingPauseDetector(pauseDelay: 0)
                 detector.noteTyping(character: 0x2E, paragraph: initial,
                                     range: NSRange(location: 0, length: (initial as NSString).length),
                                     caret: (initial as NSString).length)
                 coord.writingPartner.setBandleaderForTesting(stub)
                 coord.writingPartner.setPauseDetectorForTesting(detector)
                 coord.writingPartner.triggerPauseCheckForTesting(in: tv, coordinator: coord)
                 waitForPartner(tv)
                 // In Automatically an unsure fix is marked (#128) rather than offered: count both
                 let offered = (coord.writingPartner.suggestions.map { "\($0.edit.original)->\($0.edit.replacement)" }
                     + coord.writingPartner.marks.map { "\($0.original)->\($0.candidates[0])" }).joined(separator: ",")
                 let caretAfterFix = tv.selectedRange().location - caretBefore
                 log("writing-partner-context-spelling", initial,
                     "text=\(box.text) offered=\(offered) caretMoved=\(caretAfterFix)",
                     expect: "text=Send it from home so we dont loose the colur, and the colur. offered=loose->lose caretMoved=0")
                 tv.undoManager?.undo(); pump(0.3)
                 waitForPartner(tv)
                 log("writing-partner-context-spelling-undo", "⌘Z", box.text, expect: initial)
                 coord.writingPartner.setBandleaderForTesting(nil)
             }

             // Marks (#128): in Automatically, what the partner isn't sure about changes nothing and
             // leaves a mark that survives typing, settled by review (keep or accept), by editing it,
             // or with the caret in it. Nothing is written into the Markdown.
             do {
                 defaults.removeObject(forKey: WritingPartnerDefaults.stats)
                 defaults.removeObject(forKey: WritingPartnerDefaults.markUncertain)
                 defaults.set(WritingPartnerMode.automatic.rawValue, forKey: WritingPartnerDefaults.mode)
                 defaults.set(true, forKey: WritingPartnerDefaults.spelling)
                 let unsure: @Sendable (JazzTextLeadRequest) -> JazzTextLeadResponse = { req in
                     JazzTextLeadResponse(
                         genre: .prose, palette: [JazzTextVoice(voice: .punctuate, strength: 1.0)],
                         suggestions: ContextSpelling.suggestions(from: [
                             ContextSpellingCandidate(kind: .wrongWord, original: "form", replacement: "from", confidence: 0.9, alternatives: ["for"]),
                             ContextSpellingCandidate(kind: .wrongWord, original: "their", replacement: "there", confidence: 0.65),
                         ], paragraph: req.paragraph),
                         why: "Unsure")
                 }
                 func pause(_ coord: SwashTextView.Coordinator, _ tv: NSTextView, _ text: String) {
                     let detector = WritingPauseDetector(pauseDelay: 0)
                     detector.noteTyping(character: 0x2E, paragraph: text, range: NSRange(location: 0, length: (text as NSString).length),
                                         caret: (text as NSString).length)
                     coord.writingPartner.setPauseDetectorForTesting(detector)
                     coord.writingPartner.triggerPauseCheckForTesting(in: tv, coordinator: coord)
                     waitForPartner(tv)
                 }
                 let initial = "I came form the shop and their it was."
                 let box = TextBox(initial)
                 let tv = makeEditor(box, styled: false)
                 let coord = tv.delegate as! SwashTextView.Coordinator
                 var counts: [Int] = []
                 coord.writingPartner.onMarksChange = { counts.append($0) }
                 caretAfter(initial, in: tv)
                 coord.writingPartner.setBandleaderForTesting(StubWritingBandleader { unsure($0) })
                 pause(coord, tv, initial)
                 let markWords = { coord.writingPartner.marks.map(\.original).joined(separator: ",") }
                 log("writing-partner-marks-made", initial,
                     "text=\(box.text) marks=\(markWords()) offered=\(coord.writingPartner.suggestions.count) count=\(counts.last ?? -1)",
                     expect: "text=\(initial) marks=form,their offered=0 count=2")

                 // Typing on neither dismisses a mark nor counts against it
                 tv.insertText(" Then more", replacementRange: tv.selectedRange()); pump(0.2)
                 log("writing-partner-marks-survive-typing", "type on", "marks=\(markWords()) drawn=\(WritingPartnerOverlay.existing(in: tv)?.markLayers.count ?? 0)",
                     expect: "marks=form,their drawn=2")

                 // Review steps through them in order; Esc keeps the text as written and moves on
                 _ = coord.writingPartner.reviewMarks(in: tv, coordinator: coord)
                 let first = coord.writingPartner.suggestions.map { "\($0.edit.original)->\($0.edit.replacement)" }.joined()
                 _ = coord.writingPartner.nextCandidate(in: tv, coordinator: coord)
                 let other = coord.writingPartner.suggestions.map(\.edit.replacement).joined()
                 log("writing-partner-marks-review-order", "⌥⌘', then Show Other Choice", "first=\(first) other=\(other)", expect: "first=form->from other=for")
                 tv.doCommand(by: #selector(NSResponder.cancelOperation(_:))); pump(0.2)
                 let nowShown = coord.writingPartner.suggestions.map(\.edit.original).joined()
                 log("writing-partner-marks-keep", "Esc", "text=\(box.text) marks=\(markWords()) shown=\(nowShown)",
                     expect: "text=\(initial) Then more marks=their shown=their")
                 // Tab accepts the shown candidate through the partner's cursor, as one undo step
                 tv.doCommand(by: #selector(NSResponder.insertTab(_:)))
                 waitForPartner(tv)
                 log("writing-partner-marks-accept", "Tab", "text=\(box.text) marks=\(markWords()) reviewing=\(coord.writingPartner.isReviewing)",
                     expect: "text=I came form the shop and there it was. Then more marks= reviewing=false")
                 tv.undoManager?.undo(); pump(0.3); waitForPartner(tv)
                 log("writing-partner-marks-accept-undo", "⌘Z", box.text, expect: "\(initial) Then more")
                 // A kept word isn't marked again in this document, nor is a fix that was accepted and then undone
                 pause(coord, tv, box.text)
                 log("writing-partner-marks-kept-stays-kept", "pause again", "marks=\(markWords())", expect: "marks=")

                 // Settling a mark in place: the caret in it shows its candidate; editing it settles it your way
                 let box2 = TextBox(initial); let tv2 = makeEditor(box2, styled: true)
                 let coord2 = tv2.delegate as! SwashTextView.Coordinator
                 caretAfter(initial, in: tv2)
                 coord2.writingPartner.setBandleaderForTesting(StubWritingBandleader { unsure($0) })
                 pause(coord2, tv2, initial)
                 caretAfter("form", in: tv2); pump(0.1)
                 let shownInPlace = coord2.writingPartner.suggestions.map { "\($0.edit.original)->\($0.edit.replacement)" }.joined()
                 log("writing-partner-marks-caret-in-mark", "caret after 'form'", "shown=\(shownInPlace)", expect: "shown=form->from")
                 caretAfter("thei", in: tv2)
                 tv2.insertText("x", replacementRange: tv2.selectedRange()); pump(0.2)
                 log("writing-partner-marks-edited", "type inside 'their'", "text=\(box2.text) marks=\(coord2.writingPartner.marks.map(\.original).joined(separator: ","))",
                     expect: "text=I came form the shop and theixr it was. marks=form")

                 // Switched off, uncertain fixes are offered as before
                 defaults.set(false, forKey: WritingPartnerDefaults.markUncertain)
                 let box3 = TextBox(initial); let tv3 = makeEditor(box3, styled: false)
                 let coord3 = tv3.delegate as! SwashTextView.Coordinator
                 caretAfter(initial, in: tv3)
                 coord3.writingPartner.setBandleaderForTesting(StubWritingBandleader { unsure($0) })
                 pause(coord3, tv3, initial)
                 log("writing-partner-marks-off", "switch off", "marks=\(coord3.writingPartner.marks.count) offered=\(coord3.writingPartner.suggestions.count)",
                     expect: "marks=0 offered=2")
                 defaults.removeObject(forKey: WritingPartnerDefaults.markUncertain)
                 coord.writingPartner.setBandleaderForTesting(nil)
                 coord2.writingPartner.setBandleaderForTesting(nil)
                 coord3.writingPartner.setBandleaderForTesting(nil)
             }

             // Inline MCP Agent Presence & Bidirectional Cursor Remapping (#151)
             do {
                 defaults.set(WritingPartnerMode.off.rawValue, forKey: WritingPartnerDefaults.mode)
                 let md = "# Heading\n\nHello **bold** world"
                 let box = TextBox(md)
                 let controller = SwashEditorController()
                 let binding = Binding<String>(get: { box.text }, set: { box.text = $0 })
                 let editor = SwashTextView(text: binding, selectedRange: .constant(nil), selectionRect: .constant(nil),
                                            isStyled: true, flavor: .github, controller: controller)
                 let host = NSHostingView(rootView: editor.frame(width: 600, height: 600))
                 host.frame = NSRect(x: 0, y: 0, width: 600, height: 600)
                 let win = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
                 win.contentView = host
                 windows.append(win)
                 host.layoutSubtreeIfNeeded()
                 pump(0.3)
                 let tv = findTextView(in: host)!
                 let coord = tv.delegate as! SwashTextView.Coordinator
                 win.makeFirstResponder(tv)

                 // Place user caret right before "world" (raw offset 26)
                 let worldRaw = (md as NSString).range(of: "world").location
                 tv.setSelectedRange(coord.storageRange(forRaw: NSRange(location: worldRaw, length: 0), in: tv))
                 pump(0.05)

                 // Agent inserts "dear " at raw offset 11 (before "Hello") and shows presence
                 let updated = (md as NSString).replacingCharacters(in: NSRange(location: 11, length: 0), with: "dear ")
                 _ = controller.applyAgentEdit(
                     newText: updated,
                     edits: [(range: NSRange(location: 11, length: 0), replacementLength: 5)],
                     actionName: "Insert Text"
                 )
                 let store = AgentCaretStore()
                 controller.agentCarets = store
                 store.set(AgentCaretInfo(id: "mcp:agent", name: "Agent"), anchor: 16, head: 16)
                 store.markChanges("mcp:agent", [NSRange(location: 11, length: 5)])
                 pump(0.1)

                 let userRawAfterAgentInsert = coord.rawRange(forStorage: tv.selectedRange(), in: tv)
                 let overlay = WritingPartnerOverlay.existing(in: tv)
                 let hasOverlayPresence = overlay?.hasExternalCarets == true
                 let overlayStage = !(store.caret("mcp:agent")?.changed.isEmpty ?? true)
                 let emptyCaretRect = WritingPartnerOverlay.caretRect(at: 0, in: tv) != nil

                 // User types "!" at their remapped cursor (before "world") -> triggers onUserRawEdit
                 var userEditCaptured: (range: NSRange, len: Int)?
                 controller.onUserRawEdit = { r, l, _ in
                     userEditCaptured = (r, l)
                 }
                 tv.insertText("!", replacementRange: tv.selectedRange())
                 pump(0.1)
                 controller.agentCarets = nil
                 let detached = overlay?.hasExternalCarets == false

                 log("agent-presence-and-remapping", md,
                     "userCaret=\(userRawAfterAgentInsert.location) expected=\(worldRaw + 5) presence=\(hasOverlayPresence) stageLanded=\(overlayStage) caretRect=\(emptyCaretRect) userEdit=\(userEditCaptured?.len ?? -1) detached=\(detached)",
                     expect: "userCaret=\(worldRaw + 5) expected=\(worldRaw + 5) presence=true stageLanded=true caretRect=true userEdit=1 detached=true")
             }

             defaults.removeObject(forKey: WritingPartnerDefaults.spelling)
             defaults.removeObject(forKey: WritingPartnerDefaults.doubledWords)
             if let savedMode { defaults.set(savedMode, forKey: WritingPartnerDefaults.mode) } else { defaults.removeObject(forKey: WritingPartnerDefaults.mode) }
             if let savedStats { defaults.set(savedStats, forKey: WritingPartnerDefaults.stats) } else { defaults.removeObject(forKey: WritingPartnerDefaults.stats) }
             if let savedChatStats { defaults.set(savedChatStats, forKey: WritingPartnerDefaults.chatStats) } else { defaults.removeObject(forKey: WritingPartnerDefaults.chatStats) }
             if let savedIntroShown { defaults.set(savedIntroShown, forKey: WritingPartnerDefaults.introShown) } else { defaults.removeObject(forKey: WritingPartnerDefaults.introShown) }
        }

        // Multi-agent external carets rendered with distinct colours and name tags in WritingPartnerOverlay (#152)
        do {
            let box = TextBox("Hello world and friends")
            let tv = makeEditor(box, styled: true)
            let coord = tv.delegate as! SwashTextView.Coordinator
            let store = AgentCaretStore()
            let overlay = WritingPartnerOverlay.overlay(for: tv)
            overlay.attachExternal(carets: store, coordinator: coord)
            store.set(AgentCaretInfo(id: "mcp:claude", name: "Claude", color: "#7c3aed"), anchor: 0, head: 5)
            store.set(AgentCaretInfo(id: "mcp:cursor", name: "Cursor", color: "#db2777"), anchor: 16, head: 16)
            store.markChanges("mcp:claude", [NSRange(location: 0, length: 5)])
            pump(0.1)
            let sublayers = overlay.layer?.sublayers ?? []
            let aboveLayers = sublayers.flatMap { $0.sublayers ?? [] }
            let tagTexts = aboveLayers.compactMap { layer -> String? in
                for sub in layer.sublayers ?? [] {
                    if let textLayer = sub as? CATextLayer, let attr = textLayer.string as? NSAttributedString {
                        return attr.string
                    }
                }
                return nil
            }.sorted()
            store.mapThroughEdit(range: NSRange(location: 0, length: 0), length: 4)
            let cursorHeadAfter = store.caret("mcp:cursor")?.head ?? -1
            store.clear()
            pump(0.1)
            let cleared = (overlay.layer?.sublayers ?? []).isEmpty
            log("multi-agent-overlay-carets", "Claude (0..5) + Cursor (16)",
                "tags=\(tagTexts.joined(separator: ",")) cursorMoved=\(cursorHeadAfter) cleared=\(cleared)",
                expect: "tags=Claude,Cursor cursorMoved=20 cleared=true")
        }

        // Writing Tools: uncommitted edits on window close, app termination, dismantle, and safety net (SWA-55)
        do {
            // 1. Deferred Publication during Writing Tools session
            let b1 = TextBox("Initial text")
            let tv1 = makeEditor(b1)
            let coord1 = tv1.delegate as! SwashTextView.Coordinator
            (tv1 as? SwashNSTextView)?.writingToolsActiveOverride = true
            if #available(macOS 15.0, *) {
                coord1.textViewWritingToolsWillBegin(tv1)
            }
            tv1.insertText(" rewritten", replacementRange: NSRange(location: (tv1.string as NSString).length, length: 0))
            pump(0.1)
            // While Writing Tools is active, parent.text should still have the old text
            log("writing-tools-deferred-publication", "Initial text", b1.text,
                "binding has not updated during active writing tools session",
                expect: "Initial text")

            // 2. Window close flush
            if let win1 = tv1.window {
                NotificationCenter.default.post(name: NSWindow.willCloseNotification, object: win1)
                pump(0.1)
                log("writing-tools-window-close-flush", "Initial text", b1.text,
                    "window close flushes pending writing tools edits",
                    expect: "Initial text rewritten")
            }

            // 3. App termination flush
            let b2 = TextBox("App terminate test")
            let tv2 = makeEditor(b2)
            let coord2 = tv2.delegate as! SwashTextView.Coordinator
            (tv2 as? SwashNSTextView)?.writingToolsActiveOverride = true
            if #available(macOS 15.0, *) {
                coord2.textViewWritingToolsWillBegin(tv2)
            }
            tv2.insertText(" flushed", replacementRange: NSRange(location: (tv2.string as NSString).length, length: 0))
            pump(0.1)
            NotificationCenter.default.post(name: NSApplication.willTerminateNotification, object: NSApp)
            pump(0.1)
            log("writing-tools-app-terminate-flush", "App terminate test", b2.text,
                "app termination flushes pending writing tools edits",
                expect: "App terminate test flushed")

            // 4. Dismantle flush (e.g. view switching / rebuilds)
            let b3 = TextBox("Dismantle test")
            let tv3 = makeEditor(b3)
            let coord3 = tv3.delegate as! SwashTextView.Coordinator
            (tv3 as? SwashNSTextView)?.writingToolsActiveOverride = true
            if #available(macOS 15.0, *) {
                coord3.textViewWritingToolsWillBegin(tv3)
            }
            tv3.insertText(" dismantled", replacementRange: NSRange(location: (tv3.string as NSString).length, length: 0))
            pump(0.1)
            if let sv3 = tv3.enclosingScrollView {
                SwashTextView.dismantleNSView(sv3, coordinator: coord3)
                pump(0.1)
                log("writing-tools-dismantle-flush", "Dismantle test", b3.text,
                    "dismantleNSView flushes pending writing tools edits",
                    expect: "Dismantle test dismantled")
            }

            // 6. AppKit isWritingToolsActive == false safety net
            let b5 = TextBox("AppKit safety net")
            let tv5 = makeEditor(b5)
            let coord5 = tv5.delegate as! SwashTextView.Coordinator
            if #available(macOS 15.0, *) {
                coord5.textViewWritingToolsWillBegin(tv5)
            }
            // Writing Tools ended or crashed without didEnd, so tv5 reports isWritingToolsActive == false
            (tv5 as? SwashNSTextView)?.writingToolsActiveOverride = false
            tv5.insertText(" updated", replacementRange: NSRange(location: (tv5.string as NSString).length, length: 0))
            pump(0.1)
            log("writing-tools-appkit-state-safety-net", "AppKit safety net",
                "active=\(coord5.isWritingToolsActive) text=\(b5.text)",
                "AppKit inactive state clears isWritingToolsActive and flushes",
                expect: "active=false text=AppKit safety net updated")
        }

        try? out.write(toFile: CommandLine.arguments[1], atomically: true, encoding: .utf8)
        print(out)
        print(failures.isEmpty ? "INTERACTION: all expectations passed" : "INTERACTION FAILURES:\n" + failures.joined(separator: "\n"))
        exit(failures.isEmpty ? 0 : 1)
    }
}

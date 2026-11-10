//
//  EditorClipboardTests.swift
//  SwashiOSTests
//
//  Copy and paste in the iOS Edit Text editor: copies carry the raw Markdown (Swash's own type and
//  plain text) plus RTF and HTML; pasted HTML and RTF are converted to Markdown. Most cases use a
//  private named pasteboard; the end-to-end paste goes through the general one, as the editor does.
//

import SwiftUI
import UIKit
import UniformTypeIdentifiers
import XCTest
import PixerateMarkdown
@testable import Swash

@MainActor
final class EditorClipboardTests: XCTestCase {
    private var pasteboard: UIPasteboard!
    private var harnesses: [EditorHarness] = []

    override func setUp() async throws {
        try await super.setUp()
        pasteboard = UIPasteboard(name: UIPasteboard.Name("com.pixerate.SwashiOSTests.\(UUID().uuidString)"), create: true)
    }

    override func tearDown() async throws {
        if let pasteboard { UIPasteboard.remove(withName: pasteboard.name) }
        for harness in harnesses { harness.tearDown() }
        harnesses.removeAll()
        try await super.tearDown()
    }

    private func editor(_ markdown: String) throws -> EditorHarness {
        let harness = try EditorHarness(markdown)
        harnesses.append(harness)
        return harness
    }

    private func string(_ type: String) -> String? {
        pasteboard.data(forPasteboardType: type).flatMap { String(data: $0, encoding: .utf8) }
    }

    // MARK: Copy

    func testCopyWritesRawMarkdownAndRichText() throws {
        let markdown = "Some **bold** and *italic* text with ![img](x.png) inside."
        let e = try editor(markdown)
        EditorClipboard.copy(NSRange(location: 0, length: e.storage.length), from: e.storage, to: pasteboard)

        XCTAssertEqual(string(EditorClipboard.swashMarkdownType), markdown, "Swash's own type is the exact source, image included")
        XCTAssertEqual(pasteboard.string, markdown, "plain-text apps get the Markdown")
        let rtf = try XCTUnwrap(pasteboard.data(forPasteboardType: UTType.rtf.identifier), "RTF for rich-text apps")
        let html = try XCTUnwrap(string(UTType.html.identifier), "HTML for rich-text apps")

        let attributed = try NSAttributedString(data: rtf, options: [.documentType: NSAttributedString.DocumentType.rtf], documentAttributes: nil)
        XCTAssertTrue(attributed.string.contains("Some bold and italic text"), "markers are not copied as text: \(attributed.string.debugDescription)")
        XCTAssertFalse(attributed.string.contains("**"))
        var sawBold = false
        attributed.enumerateAttribute(.font, in: NSRange(location: 0, length: attributed.length)) { value, range, _ in
            if let font = value as? UIFont, font.fontDescriptor.symbolicTraits.contains(.traitBold),
               (attributed.string as NSString).substring(with: range).contains("bold") { sawBold = true }
        }
        XCTAssertTrue(sawBold, "bold survives in RTF")
        XCTAssertTrue(html.contains("bold"))
        XCTAssertFalse(html.contains("**"))
    }

    func testCopyOfAPartialSelectionAfterAnAttachment() throws {
        let markdown = "![img](x.png)\n\n- first item\n- second"
        let e = try editor(markdown)
        e.caret(before: "first")
        let start = e.textView.selectedRange.location
        e.caret(after: "first item")
        let end = e.textView.selectedRange.location
        EditorClipboard.copy(NSRange(location: start, length: end - start), from: e.storage, to: pasteboard)
        XCTAssertEqual(string(EditorClipboard.swashMarkdownType), "first item")
    }

    func testCopyOfAListKeepsItsMarkersAsText() throws {
        let markdown = "- one\n- two"
        let e = try editor(markdown)
        EditorClipboard.copy(NSRange(location: 0, length: e.storage.length), from: e.storage, to: pasteboard)
        XCTAssertEqual(string(EditorClipboard.swashMarkdownType), markdown)
        let rtf = try XCTUnwrap(pasteboard.data(forPasteboardType: UTType.rtf.identifier))
        let attributed = try NSAttributedString(data: rtf, options: [.documentType: NSAttributedString.DocumentType.rtf], documentAttributes: nil)
        XCTAssertFalse(attributed.string.contains("- one"), "the hidden Markdown marker isn't copied")
        XCTAssertTrue(attributed.string.contains("one") && attributed.string.contains("two"))
    }

    func testCopyOfATableWritesItsSourceAndTabSeparatedText() throws {
        let markdown = "| A | B |\n|---|---|\n| 1 | 2 |"
        let e = try editor(markdown)
        XCTAssertEqual(e.attachments().count, 1)
        EditorClipboard.copy(NSRange(location: 0, length: e.storage.length), from: e.storage, to: pasteboard)
        XCTAssertEqual(string(EditorClipboard.swashMarkdownType), markdown)
        let rtf = try XCTUnwrap(pasteboard.data(forPasteboardType: UTType.rtf.identifier))
        let attributed = try NSAttributedString(data: rtf, options: [.documentType: NSAttributedString.DocumentType.rtf], documentAttributes: nil)
        XCTAssertTrue(attributed.string.contains("A\tB"), attributed.string.debugDescription)
        XCTAssertTrue(attributed.string.contains("1\t2"), attributed.string.debugDescription)
    }

    func testEmptySelectionCopiesNothing() throws {
        let e = try editor("Hello")
        pasteboard.string = "unchanged"
        EditorClipboard.copy(NSRange(location: 2, length: 0), from: e.storage, to: pasteboard)
        XCTAssertEqual(pasteboard.string, "unchanged")
    }

    // MARK: Paste conversion

    func testSwashMarkdownPastesVerbatim() {
        pasteboard.setItems([[EditorClipboard.swashMarkdownType: Data("**x** ![a](b.png)".utf8), UTType.utf8PlainText.identifier: "x"]])
        XCTAssertEqual(EditorClipboard.markdownForPaste(from: pasteboard), "**x** ![a](b.png)")
    }

    func testHTMLPastesAsMarkdown() throws {
        pasteboard.setItems([[
            UTType.html.identifier: Data("<p>Hello <b>world</b> and <a href=\"https://example.com\">a link</a></p>".utf8),
            UTType.utf8PlainText.identifier: "Hello world and a link",
        ]])
        let markdown = try XCTUnwrap(EditorClipboard.markdownForPaste(from: pasteboard))
        XCTAssertTrue(markdown.contains("**world**"), markdown)
        XCTAssertTrue(markdown.contains("[a link](https://example.com)"), markdown)
    }

    func testHTMLListPastesAsMarkdownList() throws {
        pasteboard.setItems([[UTType.html.identifier: Data("<ul><li>one</li><li>two</li></ul>".utf8)]])
        let markdown = try XCTUnwrap(EditorClipboard.markdownForPaste(from: pasteboard))
        let lines = markdown.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        XCTAssertTrue(lines.contains { $0.hasSuffix("one") && ($0.hasPrefix("-") || $0.hasPrefix("*")) }, markdown)
        XCTAssertTrue(lines.contains { $0.hasSuffix("two") && ($0.hasPrefix("-") || $0.hasPrefix("*")) }, markdown)
    }

    func testRTFPastesAsMarkdown() throws {
        // Links survive the RTF → HTML → Markdown route. (Bold and italic don't yet: the HTML that
        // UIKit writes for RTF styles them with CSS classes, which the converter doesn't read.)
        let rich = NSMutableAttributedString(string: "see ", attributes: [.font: UIFont.systemFont(ofSize: 12)])
        rich.append(NSAttributedString(string: "the site", attributes: [.font: UIFont.systemFont(ofSize: 12), .link: URL(string: "https://example.com")!]))
        let rtf = try rich.data(from: NSRange(location: 0, length: rich.length), documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
        pasteboard.setItems([[UTType.rtf.identifier: rtf, UTType.utf8PlainText.identifier: "see the site"]])
        let markdown = try XCTUnwrap(EditorClipboard.markdownForPaste(from: pasteboard))
        XCTAssertTrue(markdown.contains("[the site](https://example.com)"), markdown)
    }

    func testPreformattedCodeHTMLPastesAsPlainText() {
        pasteboard.setItems([[
            UTType.html.identifier: Data("<div style=\"white-space: pre;\"><span>let x = 1</span></div>".utf8),
            UTType.utf8PlainText.identifier: "    let x = 1",
        ]])
        XCTAssertNil(EditorClipboard.markdownForPaste(from: pasteboard), "code editors' HTML keeps its plain text")
    }

    func testHTMLWithoutFormattingPastesAsPlainText() {
        pasteboard.setItems([[
            UTType.html.identifier: Data("<p>just *text* here</p>".utf8),
            UTType.utf8PlainText.identifier: "just *text* here",
        ]])
        XCTAssertNil(EditorClipboard.markdownForPaste(from: pasteboard), "no formatting gained: paste the plain text, unescaped")
    }

    func testPlainTextOnlyIsLeftToUIKit() {
        pasteboard.string = "plain"
        XCTAssertNil(EditorClipboard.markdownForPaste(from: pasteboard))
    }

    // MARK: Through the text view (general pasteboard)

    func testCopyThenPasteInTheEditorIsLossless() throws {
        let general = UIPasteboard.general
        let saved = general.items
        defer { general.items = saved }

        let source = try editor("Text with ![img](x.png) and **bold**")
        source.textView.selectedRange = NSRange(location: 0, length: source.storage.length)
        source.textView.copy(nil)
        XCTAssertEqual(general.data(forPasteboardType: EditorClipboard.swashMarkdownType).flatMap { String(data: $0, encoding: .utf8) },
                       "Text with ![img](x.png) and **bold**")

        let target = try editor("Start: ")
        target.caret(after: "Start: ")
        target.textView.paste(nil)
        target.pump()
        XCTAssertEqual(target.text, "Start: Text with ![img](x.png) and **bold**")
        XCTAssertEqual(target.attachments().count, 1, "the pasted image is collapsed")
        XCTAssertEqual(target.rawSelection, NSRange(location: (target.text as NSString).length, length: 0), "the caret follows the paste")
    }

    func testPastingHTMLInTheEditorConvertsIt() throws {
        let general = UIPasteboard.general
        let saved = general.items
        defer { general.items = saved }
        general.setItems([[
            UTType.html.identifier: Data("<p>an <i>emphasised</i> word</p>".utf8),
            UTType.utf8PlainText.identifier: "an emphasised word",
        ]])
        let e = try editor("![img](x.png) ")
        e.caret(after: "![img](x.png) ")
        e.textView.paste(nil)
        e.pump()
        XCTAssertTrue(e.text.hasPrefix("![img](x.png) an "), e.text)
        XCTAssertTrue(e.text.contains("*emphasised*") || e.text.contains("_emphasised_"), e.text)
    }

    func testCutRemovesTheSelectionAndCopiesIt() throws {
        let general = UIPasteboard.general
        let saved = general.items
        defer { general.items = saved }
        let e = try editor("Keep ![img](x.png) drop")
        e.caret(before: "![img]")
        let start = e.textView.selectedRange.location
        e.textView.selectedRange = NSRange(location: start, length: e.storage.length - start)
        e.textView.cut(nil)
        e.pump()
        XCTAssertEqual(e.text, "Keep ")
        XCTAssertEqual(general.data(forPasteboardType: EditorClipboard.swashMarkdownType).flatMap { String(data: $0, encoding: .utf8) }, "![img](x.png) drop")
    }
}

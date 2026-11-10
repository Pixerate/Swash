//
//  StyledTextViewTests.swift
//  SwashiOSTests
//
//  The iOS Edit Text editor hosted in a window: incremental vs full restyling (GOTCHAS #20),
//  raw ↔ storage offsets with collapsed tables and images (GOTCHAS #9), structural editing through
//  the text view, and block decorations (GOTCHAS #53).
//

import SwiftUI
import UIKit
import XCTest
import PixerateMarkdown
@testable import Swash

@MainActor
final class StyledTextViewTests: XCTestCase {
    private var harnesses: [EditorHarness] = []

    private func editor(_ markdown: String, file: StaticString = #filePath, line: UInt = #line) throws -> EditorHarness {
        let harness = try EditorHarness(markdown, file: file, line: line)
        harnesses.append(harness)
        return harness
    }

    override func tearDown() async throws {
        for harness in harnesses { harness.tearDown() }
        harnesses.removeAll()
        try await super.tearDown()
    }

    static let mixed = "# Title\n\nIntro with **bold** and ![img](x.png) here.\n\n- one\n- two\n\n| A | B |\n|---|---|\n| 1 | 2 |\n\n> quote\n\n```swift\nlet x = 1\n```\n\nLast paragraph."

    // MARK: - Hosting

    func testHostsAndStylesTheDocument() throws {
        let e = try editor(Self.mixed)
        XCTAssertGreaterThanOrEqual(e.coordinator.fullPassCount, 1, "the first pass is a full one")
        XCTAssertEqual(swashRawMarkdown(from: e.storage), Self.mixed, "the storage stands for the raw Markdown")
        XCTAssertEqual(e.text, Self.mixed, "styling doesn't change the document")
        let kinds = e.attachments().map { $0.attachment is TableTextAttachment ? "table" : "image" }
        XCTAssertEqual(kinds, ["image", "table"])
        XCTAssertLessThan(e.storage.length, (Self.mixed as NSString).length, "tables and images are collapsed")
    }

    // MARK: - Incremental restyling (GOTCHAS #20)

    func testIncrementalRestyleMatchesFullRestyle() throws {
        let scenarios: [(name: String, anchor: String, insertion: String, incremental: Bool)] = [
            ("type in paragraph", "Intro with", " more", true),
            ("make bold", "Last", "**", true),
            ("open a fence", "Intro", "\n```\n", true),
            ("type in list", "- one", " item", true),
            ("type in quote", "> quote", " text", true),
            ("before table", "- two", " and", true),
            ("after image", "here", " now", true),
            ("in code", "let x", "y", true),
            ("open string in code", "let x =", " \"", true),
            ("at start", "# Title", "!", true),
            ("at end", "Last paragraph.", " End", true),
            ("setext underline", "Last paragraph.", "\n---", true),
            ("add reference definition", "Last paragraph.", "\n\n[r]: https://r.com", false),
        ]
        for scenario in scenarios {
            let e = try editor(Self.mixed)
            e.caret(after: scenario.anchor)
            let incrementalBefore = e.coordinator.incrementalPassCount
            let fullBefore = e.coordinator.fullPassCount
            e.type(scenario.insertion)
            let expectedText = (Self.mixed as NSString).replacingCharacters(
                in: NSRange(location: NSMaxRange((Self.mixed as NSString).range(of: scenario.anchor)), length: 0), with: scenario.insertion)
            XCTAssertEqual(e.text, expectedText, "\(scenario.name): document text")
            XCTAssertEqual(swashRawMarkdown(from: e.storage), expectedText, "\(scenario.name): storage")
            if scenario.incremental {
                XCTAssertGreaterThan(e.coordinator.incrementalPassCount, incrementalBefore, "\(scenario.name): restyled incrementally")
                XCTAssertEqual(e.coordinator.fullPassCount, fullBefore, "\(scenario.name): no full pass")
            } else {
                XCTAssertGreaterThan(e.coordinator.fullPassCount, fullBefore, "\(scenario.name): restyled fully")
            }
            let incremental = e.fingerprint()
            e.forceFullRestyle()
            let full = e.fingerprint()
            XCTAssertEqual(incremental, full, "\(scenario.name): incremental result differs from a full restyle: \(firstDifference(incremental, full))")
        }
    }

    func testTableCellEditKeepsNextKeystrokeConsistent() throws {
        let e = try editor(Self.mixed)
        guard let table = e.attachments().compactMap({ $0.attachment as? TableTextAttachment }).first else {
            return XCTFail("no table attachment")
        }
        var data = table.tableData
        data.rows[0][0] = "longer cell"
        table.onUpdate?(data)
        e.pump()
        XCTAssertTrue(e.text.contains("| longer cell |"), "the cell edit reaches the document: \(e.text)")
        e.caret(after: "Last paragraph.")
        e.type("!")
        XCTAssertTrue(e.text.hasSuffix("Last paragraph.!"))
        XCTAssertTrue(e.text.contains("| longer cell |"))
        let afterTyping = e.fingerprint()
        e.forceFullRestyle()
        XCTAssertEqual(afterTyping, e.fingerprint(), firstDifference(afterTyping, e.fingerprint()))
    }

    func testExternalTextChangeRestylesFully() throws {
        let e = try editor("First")
        let fullBefore = e.coordinator.fullPassCount
        e.box.text = "# Replaced\n\n![img](y.png)"
        e.host.rootView = StyledTextView(text: Binding(get: { e.box.text }, set: { e.box.text = $0 }),
                                         controller: e.controller, flavor: .github, baseURL: nil)
        e.pump()
        XCTAssertGreaterThan(e.coordinator.fullPassCount, fullBefore)
        XCTAssertEqual(swashRawMarkdown(from: e.storage), "# Replaced\n\n![img](y.png)")
        XCTAssertEqual(e.attachments().count, 1)
    }

    // MARK: - Raw ↔ storage offsets (GOTCHAS #9)

    func testOffsetMappingAroundAttachments() throws {
        let e = try editor(Self.mixed)
        let raw = Self.mixed as NSString
        let image = raw.range(of: "![img](x.png)")
        let table = raw.range(of: "| A | B |\n|---|---|\n| 1 | 2 |")
        let attachments = e.attachments()
        XCTAssertEqual(attachments.count, 2)
        guard attachments.count == 2 else { return }
        let imageStorage = attachments[0].location
        let tableStorage = attachments[1].location

        // Before the first attachment, offsets agree
        XCTAssertEqual(imageStorage, image.location)
        XCTAssertEqual(e.coordinator.rawRange(forStorage: NSRange(location: 3, length: 2), in: e.textView), NSRange(location: 3, length: 2))
        // An attachment character stands for its whole source
        XCTAssertEqual(e.coordinator.rawRange(forStorage: NSRange(location: imageStorage, length: 1), in: e.textView), image)
        XCTAssertEqual(e.coordinator.rawRange(forStorage: NSRange(location: tableStorage, length: 1), in: e.textView), table)
        XCTAssertEqual(e.coordinator.storageRange(forRaw: image, in: e.textView), NSRange(location: imageStorage, length: 1))
        XCTAssertEqual(e.coordinator.storageRange(forRaw: table, in: e.textView), NSRange(location: tableStorage, length: 1))
        // A raw location inside an attachment's source snaps to the attachment
        XCTAssertEqual(e.coordinator.storageRange(forRaw: NSRange(location: image.location + 3, length: 0), in: e.textView).location, imageStorage)
        // After both attachments, the shift is both sources minus their attachment characters
        let last = raw.range(of: "Last paragraph.")
        let shift = (image.length - 1) + (table.length - 1)
        XCTAssertEqual(e.coordinator.storageRange(forRaw: last, in: e.textView), NSRange(location: last.location - shift, length: last.length))
        XCTAssertEqual((e.storage.string as NSString).substring(with: NSRange(location: last.location - shift, length: last.length)), "Last paragraph.")
        // Round trips everywhere outside attachments
        for location in stride(from: 0, through: e.storage.length, by: 1) {
            let rawRange = e.coordinator.rawRange(forStorage: NSRange(location: location, length: 0), in: e.textView)
            XCTAssertEqual(e.coordinator.storageRange(forRaw: rawRange, in: e.textView).location, location, "storage \(location)")
        }
    }

    func testSelectionIsPublishedInRawOffsets() throws {
        let e = try editor(Self.mixed)
        e.caret(after: "Last")
        let expected = NSRange(location: NSMaxRange((Self.mixed as NSString).range(of: "Last")), length: 0)
        XCTAssertEqual(e.rawSelection, expected)
        XCTAssertEqual(e.controller.selection, expected)
        XCTAssertLessThan(e.textView.selectedRange.location, expected.location, "the storage caret is shifted by the attachments")
    }

    func testTypingNextToAttachments() throws {
        let e = try editor("Before ![img](x.png) after\n\n| A |\n|---|\n| 1 |\n\nEnd")
        // Right after the image
        e.caret(after: "![img](x.png)")
        e.type("X")
        XCTAssertEqual(e.text, "Before ![img](x.png)X after\n\n| A |\n|---|\n| 1 |\n\nEnd")
        // Right before the image
        e.caret(before: "![img]")
        e.type("Y")
        XCTAssertEqual(e.text, "Before Y![img](x.png)X after\n\n| A |\n|---|\n| 1 |\n\nEnd")
        // After the table
        e.caret(after: "End")
        e.type("!")
        XCTAssertEqual(e.text, "Before Y![img](x.png)X after\n\n| A |\n|---|\n| 1 |\n\nEnd!")
        XCTAssertEqual(e.attachments().count, 2, "attachments survive edits next to them")
        XCTAssertEqual(e.rawSelection, NSRange(location: (e.text as NSString).length, length: 0))
    }

    func testControllerEditsUseRawOffsets() throws {
        let e = try editor(Self.mixed)
        let raw = Self.mixed as NSString
        let last = raw.range(of: "Last")
        let updated = raw.replacingCharacters(in: last, with: "Final")
        e.controller.apply(MarkdownEdit(text: updated, selection: NSRange(location: last.location, length: 5)), actionName: "Test")
        e.pump()
        XCTAssertEqual(e.text, updated)
        XCTAssertEqual(swashRawMarkdown(from: e.storage), updated)
        XCTAssertEqual(e.rawSelection, NSRange(location: last.location, length: 5))
        XCTAssertEqual(e.attachments().count, 2)
    }

    func testDeletingAnAttachmentRemovesItsSource() throws {
        let e = try editor("A ![img](x.png) B")
        e.caret(after: "![img](x.png)")
        e.backspace()
        XCTAssertEqual(e.text, "A  B")
        XCTAssertEqual(e.attachments().count, 0)
    }

    // MARK: - Structural editing through the text view

    func testReturnContinuesAList() throws {
        let e = try editor("- one")
        e.caret(after: "one")
        e.pressReturn()
        XCTAssertEqual(e.text, "- one\n- ")
        XCTAssertEqual(e.rawSelection, NSRange(location: 8, length: 0))
        e.type("two")
        XCTAssertEqual(e.text, "- one\n- two")
    }

    func testReturnContinuesNumberedAndTaskLists() throws {
        let numbered = try editor("1. one")
        numbered.caret(after: "one")
        numbered.pressReturn()
        XCTAssertEqual(numbered.text, "1. one\n2. ")

        let tasks = try editor("- [x] done")
        tasks.caret(after: "done")
        tasks.pressReturn()
        XCTAssertEqual(tasks.text, "- [x] done\n- [ ] ")
    }

    func testReturnOnAnEmptyItemEndsTheList() throws {
        let e = try editor("- one\n- ")
        e.select(raw: NSRange(location: 8, length: 0))
        e.pressReturn()
        XCTAssertFalse(e.text.hasSuffix("- "), "the empty item is unformatted: \(e.text.debugDescription)")
        XCTAssertTrue(e.text.hasPrefix("- one\n"))
    }

    func testReturnInAParagraphInsertsANewline() throws {
        let e = try editor("Hello world")
        e.caret(after: "Hello")
        e.pressReturn()
        XCTAssertEqual(e.text, "Hello\n world")
    }

    func testBackspaceAtItemStartUnformats() throws {
        let e = try editor("- item")
        e.caret(before: "item")
        e.backspace()
        XCTAssertEqual(e.text, "item")
        XCTAssertEqual(e.rawSelection, NSRange(location: 0, length: 0))
    }

    func testBackspaceAtHeadingStartUnformats() throws {
        let e = try editor("Intro\n\n## Heading")
        e.caret(before: "Heading")
        e.backspace()
        XCTAssertEqual(e.text, "Intro\n\nHeading")
    }

    func testBackspaceInTextDeletesACharacter() throws {
        let e = try editor("Hello")
        e.caret(after: "Hello")
        e.backspace()
        XCTAssertEqual(e.text, "Hell")
    }

    func testTabAndShiftTabIndentListItems() throws {
        let e = try editor("- one\n- two")
        e.caret(after: "two")
        e.keyCommand("\t")
        XCTAssertEqual(e.text, "- one\n  - two")
        e.keyCommand("\t", modifiers: .shift)
        XCTAssertEqual(e.text, "- one\n- two")
    }

    func testTabOutsideAListInsertsATab() throws {
        let e = try editor("Hello")
        e.caret(after: "Hello")
        e.keyCommand("\t")
        XCTAssertEqual(e.text, "Hello\t")
    }

    // MARK: "/" block menu

    private func blockMenuButtons(in e: EditorHarness) -> [String: UIButton] {
        guard let bar = e.textView.inputAccessoryView, String(describing: type(of: bar)).contains("BlockMenuBar") else { return [:] }
        var buttons: [String: UIButton] = [:]
        func collect(_ view: UIView) {
            if let button = view as? UIButton, let title = button.configuration?.title { buttons[title] = button }
            view.subviews.forEach(collect)
        }
        collect(bar)
        return buttons
    }

    func testSlashOnAnEmptyLineOffersBlocksAndInsertsTheChoice() throws {
        let e = try editor("Intro\n\n")
        e.select(raw: NSRange(location: 7, length: 0))
        e.type("/")
        let buttons = blockMenuButtons(in: e)
        XCTAssertEqual(Set(buttons.keys), Set(MarkdownEditingCommands.BlockInsert.allCases.map(\.title)), "the menu offers every block type")
        let kind = MarkdownEditingCommands.BlockInsert.bulletList
        let expected = try XCTUnwrap(MarkdownEditingCommands.insertBlock(kind, text: "Intro\n\n/", slashLocation: 7))
        buttons[kind.title]?.sendActions(for: .primaryActionTriggered)
        e.pump()
        XCTAssertEqual(e.text, expected.text, "the \"/\" is replaced by the block")
        XCTAssertEqual(e.rawSelection, expected.selection)
        XCTAssertTrue(blockMenuButtons(in: e).isEmpty, "choosing closes the menu")
    }

    func testSlashMenuInsertsACodeBlock() throws {
        let e = try editor("")
        e.type("/")
        let kind = MarkdownEditingCommands.BlockInsert.codeBlock
        let expected = try XCTUnwrap(MarkdownEditingCommands.insertBlock(kind, text: "/", slashLocation: 0))
        let button = try XCTUnwrap(blockMenuButtons(in: e)[kind.title])
        button.sendActions(for: .primaryActionTriggered)
        e.pump()
        XCTAssertEqual(e.text, expected.text)
        XCTAssertTrue(e.text.contains("```"))
        let afterInsert = e.fingerprint()
        e.forceFullRestyle()
        XCTAssertEqual(afterInsert, e.fingerprint(), firstDifference(afterInsert, e.fingerprint()))
    }

    func testSlashMenuInsertsATableAsAnAttachment() throws {
        let e = try editor("Intro\n\n")
        e.select(raw: NSRange(location: 7, length: 0))
        e.type("/")
        let expected = try XCTUnwrap(MarkdownEditingCommands.insertBlock(.table, text: "Intro\n\n/", slashLocation: 7))
        let button = try XCTUnwrap(blockMenuButtons(in: e)[MarkdownEditingCommands.BlockInsert.table.title])
        button.sendActions(for: .primaryActionTriggered)
        e.pump()
        XCTAssertEqual(e.text, expected.text)
        XCTAssertEqual(e.attachments().compactMap { $0.attachment as? TableTextAttachment }.count, 1, "the inserted table is collapsed")
        XCTAssertEqual(swashRawMarkdown(from: e.storage), expected.text)
    }

    func testSlashMidSentenceDoesNotOpenTheMenu() throws {
        let e = try editor("and")
        e.caret(after: "and")
        e.type("/")
        XCTAssertEqual(e.text, "and/")
        XCTAssertTrue(blockMenuButtons(in: e).isEmpty)
    }

    func testTypingAfterSlashClosesTheMenuAndKeepsTheSlash() throws {
        let e = try editor("")
        e.type("/")
        XCTAssertFalse(blockMenuButtons(in: e).isEmpty)
        e.textView.dismissBlockMenu()
        e.pump()
        XCTAssertTrue(blockMenuButtons(in: e).isEmpty)
        XCTAssertEqual(e.text, "/")
    }

    // MARK: Tasks

    private func taskMarkers(in e: EditorHarness) -> [(range: NSRange, info: ListMarkerInfo)] {
        var result: [(NSRange, ListMarkerInfo)] = []
        e.storage.enumerateAttribute(.listMarker, in: NSRange(location: 0, length: e.storage.length), options: []) { value, range, _ in
            if let info = value as? ListMarkerInfo, info.isTask { result.append((range, info)) }
        }
        return result
    }

    func testTaskCheckboxHitTestingAndToggling() throws {
        let e = try editor("- [ ] buy milk\n- [x] done")
        var markers = taskMarkers(in: e)
        XCTAssertEqual(markers.map(\.info.isChecked), [false, true])
        guard let first = markers.first else { return }

        // The tap target: just left of the item's text, on its line
        let layoutManager = e.textView.layoutManager
        let contentGlyph = layoutManager.glyphIndexForCharacter(at: NSMaxRange(first.range))
        let lineRect = layoutManager.lineFragmentRect(forGlyphAt: contentGlyph, effectiveRange: nil)
        let contentX = lineRect.minX + layoutManager.location(forGlyphAt: contentGlyph).x
        let inset = e.textView.textContainerInset
        let onBox = CGPoint(x: contentX - 12 + inset.left, y: lineRect.midY + inset.top)
        XCTAssertEqual(e.textView.taskMarkerRange(at: onBox), first.range)
        let onText = CGPoint(x: contentX + 40 + inset.left, y: lineRect.midY + inset.top)
        XCTAssertNil(e.textView.taskMarkerRange(at: onText), "taps on the item's text don't toggle it")

        e.coordinator.toggleTask(markerRange: first.range, in: e.textView)
        e.pump()
        XCTAssertEqual(e.text, "- [x] buy milk\n- [x] done")
        markers = taskMarkers(in: e)
        XCTAssertEqual(markers.map(\.info.isChecked), [true, true])
        e.coordinator.toggleTask(markerRange: markers[1].range, in: e.textView)
        e.pump()
        XCTAssertEqual(e.text, "- [x] buy milk\n- [ ] done")
    }

    func testTaskToggleAfterAnAttachment() throws {
        let e = try editor("![img](x.png)\n\n- [ ] item")
        guard let marker = taskMarkers(in: e).first else { return XCTFail("no task marker") }
        e.coordinator.toggleTask(markerRange: marker.range, in: e.textView)
        e.pump()
        XCTAssertEqual(e.text, "![img](x.png)\n\n- [x] item")
    }

    func testStructuralEditsAreUndoable() throws {
        let e = try editor("- one")
        e.caret(after: "one")
        e.pressReturn()
        XCTAssertEqual(e.text, "- one\n- ")
        let undoManager = try XCTUnwrap(e.textView.undoManager)
        XCTAssertTrue(undoManager.canUndo)
        undoManager.undo()
        e.pump()
        XCTAssertEqual(e.text, "- one")
    }

    // MARK: - Block decorations (GOTCHAS #53)

    /// Raw ranges (as storage paragraphs) carrying `.blockDecorations`, merged.
    private func decoratedParagraphs(in e: EditorHarness) -> [(range: NSRange, decorations: [BlockDecoration])] {
        var result: [(NSRange, [BlockDecoration])] = []
        let ns = e.storage.string as NSString
        var location = 0
        while location < ns.length {
            let paragraph = ns.paragraphRange(for: NSRange(location: location, length: 0))
            let decorations = e.storage.attribute(.blockDecorations, at: paragraph.location, effectiveRange: nil) as? [BlockDecoration] ?? []
            result.append((paragraph, decorations))
            location = NSMaxRange(paragraph)
        }
        return result
    }

    func testBlockDecorationsCoverTheirParagraphs() throws {
        let markdown = "Intro\n\n> quote one\n> quote two\n\nMiddle\n\n```swift\nlet x = 1\nlet y = 2\n```\n\n---\n\nEnd"
        let e = try editor(markdown)
        let ns = e.storage.string as NSString
        let paragraphs = decoratedParagraphs(in: e)
        func decorations(of text: String) -> [BlockDecoration] {
            paragraphs.first { ns.substring(with: $0.range).contains(text) }?.decorations ?? []
        }
        XCTAssertTrue(decorations(of: "Intro").isEmpty)
        XCTAssertTrue(decorations(of: "Middle").isEmpty)
        XCTAssertTrue(decorations(of: "End").isEmpty)
        let quoteOne = decorations(of: "quote one"), quoteTwo = decorations(of: "quote two")
        XCTAssertEqual(quoteOne.map(\.kind), [.box])
        XCTAssertTrue(quoteOne.first === quoteTwo.first, "one box over the whole quote")
        let code = decorations(of: "let x"), code2 = decorations(of: "let y")
        XCTAssertEqual(code.map(\.kind), [.box])
        XCTAssertTrue(code.first === code2.first)
        XCTAssertFalse(code.first === quoteOne.first)
        XCTAssertEqual(decorations(of: "---").map(\.kind), [.rule])

        // Text inside a box is inset past its left edge (border and padding)
        let quoteIndex = ns.range(of: "quote one").location
        let quoteStyle = try XCTUnwrap(e.storage.attribute(.paragraphStyle, at: quoteIndex, effectiveRange: nil) as? NSParagraphStyle)
        let box = try XCTUnwrap(quoteOne.first)
        XCTAssertGreaterThanOrEqual(quoteStyle.headIndent, box.left + box.leftBorderWidth)
        XCTAssertLessThan(quoteStyle.tailIndent, 0, "the box's right inset")
    }

    func testBoxPaddingBecomesParagraphSpacing() throws {
        let markdown = "Intro\n\n> one\n> two\n> three\n\nEnd"
        let e = try editor(markdown)
        let ns = e.storage.string as NSString
        func style(of text: String) throws -> NSParagraphStyle {
            let location = ns.range(of: text).location
            XCTAssertNotEqual(location, NSNotFound)
            return try XCTUnwrap(e.storage.attribute(.paragraphStyle, at: location, effectiveRange: nil) as? NSParagraphStyle)
        }
        let box = try XCTUnwrap((e.storage.attribute(.blockDecorations, at: ns.range(of: "one").location, effectiveRange: nil) as? [BlockDecoration])?.first)
        XCTAssertGreaterThan(box.padding, 0)
        let first = try style(of: "one"), middle = try style(of: "two"), last = try style(of: "three")
        XCTAssertGreaterThanOrEqual(first.paragraphSpacingBefore, box.padding, "top padding before the first paragraph")
        XCTAssertGreaterThanOrEqual(last.paragraphSpacing, box.padding, "bottom padding after the last paragraph")
        XCTAssertLessThan(middle.paragraphSpacingBefore, box.padding, "no padding between a box's paragraphs")
        XCTAssertLessThan(middle.paragraphSpacing, box.padding)
    }

    func testNestedBoxesAreOutermostFirst() throws {
        let e = try editor("> outer\n>\n> ```\n> code\n> ```")
        let ns = e.storage.string as NSString
        let outer = e.storage.attribute(.blockDecorations, at: ns.range(of: "outer").location, effectiveRange: nil) as? [BlockDecoration] ?? []
        let inner = e.storage.attribute(.blockDecorations, at: ns.range(of: "code").location, effectiveRange: nil) as? [BlockDecoration] ?? []
        XCTAssertEqual(outer.count, 1)
        XCTAssertEqual(inner.count, 2)
        XCTAssertTrue(inner.first === outer.first, "the quote's box comes first")
        if inner.count == 2 { XCTAssertGreaterThan(inner[1].left, inner[0].left, "the inner box sits inside the outer one") }
    }

    func testDecorationsAfterIncrementalEditMatchFullRestyle() throws {
        let e = try editor("> quote\n\nText\n\n```\ncode\n```")
        e.caret(after: "quote")
        e.type(" more")
        e.caret(after: "code")
        e.type("\nline")
        let incremental = e.fingerprint()
        e.forceFullRestyle()
        XCTAssertEqual(incremental, e.fingerprint(), firstDifference(incremental, e.fingerprint()))
    }
}

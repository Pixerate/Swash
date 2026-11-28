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
    private var savedPartnerMode: Any?

    /// The writing partner is off: these tests check the editor's own editing and styling, and the
    /// partner's fixes would land or not depending on how long a test pumps (GOTCHAS #114)
    override func setUp() async throws {
        try await super.setUp()
        savedPartnerMode = UserDefaults.standard.object(forKey: WritingPartnerDefaults.mode)
        UserDefaults.standard.set(WritingPartnerMode.off.rawValue, forKey: WritingPartnerDefaults.mode)
    }

    private func editor(_ markdown: String, file: StaticString = #filePath, line: UInt = #line) throws -> EditorHarness {
        let harness = try EditorHarness(markdown, file: file, line: line)
        harnesses.append(harness)
        return harness
    }

    override func tearDown() async throws {
        for harness in harnesses { harness.tearDown() }
        harnesses.removeAll()
        if let savedPartnerMode {
            UserDefaults.standard.set(savedPartnerMode, forKey: WritingPartnerDefaults.mode)
        } else {
            UserDefaults.standard.removeObject(forKey: WritingPartnerDefaults.mode)
        }
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

    func testKeyboardBarCharacterIsAnUndoableKeystroke() throws {
        let e = try editor("Title")
        e.caret(before: "Title")
        e.textView.typeFromBar("#")
        e.pump()
        XCTAssertEqual(e.text, "#Title")
        let undoManager = try XCTUnwrap(e.textView.undoManager)
        XCTAssertTrue(undoManager.canUndo, "a character from the keyboard bar is undoable")
        undoManager.undo()
        e.pump()
        XCTAssertEqual(e.text, "Title")
    }

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

    // MARK: Edit menu and format panel (#72)

    func testEditMenuOffersInlineFormatsDirectlyAndBlocksInFormat() throws {
        let e = try editor("Some bold text")
        e.select(raw: NSRange(location: 5, length: 4))
        let menu = try XCTUnwrap(e.textView.editMenu(for: e.textView.selectedRange, suggestedActions: []))
        let palette = try XCTUnwrap(menu.children.compactMap { $0 as? UIMenu }.first { $0.options.contains(.displayAsPalette) },
                                    "inline formats are a palette of the menu itself, not a submenu")
        let titles = palette.children.compactMap { ($0 as? UIAction)?.title }
        XCTAssertTrue(titles.contains("Bold") && titles.contains("Italic"), "palette has the inline formats: \(titles)")
        XCTAssertTrue(menu.children.contains { ($0 as? UIMenu)?.title == "Format" }, "block commands stay in Format")
    }

    func testFormatPanelReplacesTheKeyboardUntilEditingEnds() throws {
        let e = try editor("Hello")
        e.caret(after: "Hello")
        XCTAssertFalse(e.textView.isShowingFormatPanel)
        e.textView.toggleFormatPanel()
        XCTAssertTrue(e.textView.isShowingFormatPanel, "Aa shows the panel in place of the keyboard")
        e.textView.toggleFormatPanel()
        XCTAssertFalse(e.textView.isShowingFormatPanel, "Aa again brings the keyboard back")
        e.textView.toggleFormatPanel()
        _ = e.textView.resignFirstResponder()
        XCTAssertFalse(e.textView.isShowingFormatPanel, "the keyboard comes back the next time editing starts")
    }

    func testRecentFormatCommandsStoreOrderingCapAndPersistence() throws {
        let suiteName = "SwashRecentFormatTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = RecentFormatCommands(defaults: defaults)
        XCTAssertEqual(
            store.commands,
            [.bold, .italic, .link, .bulletList, .heading(1)],
            "seeds with sensible defaults when UserDefaults is empty"
        )

        // Using an existing command moves it to the front without duplicating
        store.record(.link)
        XCTAssertEqual(store.commands, [.link, .bold, .italic, .bulletList, .heading(1)])

        // Using a new variant adds it at the front, reaching the cap of 6
        store.record(.heading(2))
        XCTAssertEqual(store.commands, [.heading(2), .link, .bold, .italic, .bulletList, .heading(1)])
        XCTAssertEqual(store.commands.count, RecentFormatCommands.maxCount)

        // Recording beyond the cap drops the oldest command
        store.record(.quote)
        XCTAssertEqual(store.commands, [.quote, .heading(2), .link, .bold, .italic, .bulletList])
        XCTAssertEqual(store.commands.count, RecentFormatCommands.maxCount)

        store.record(.taskList)
        XCTAssertEqual(store.commands, [.taskList, .quote, .heading(2), .link, .bold, .italic])

        // Unavailable commands on iOS are ignored
        store.record(.table)
        store.record(.footnote)
        XCTAssertEqual(store.commands, [.taskList, .quote, .heading(2), .link, .bold, .italic])

        // Persists across store instances (simulating app relaunch)
        let relaunched = RecentFormatCommands(defaults: defaults)
        XCTAssertEqual(relaunched.commands, [.taskList, .quote, .heading(2), .link, .bold, .italic])

        // Reset restores the default seed
        relaunched.reset()
        XCTAssertEqual(relaunched.commands, RecentFormatCommands.defaultCommands)
    }

    func testKeyboardBarShowsRecentFormatsAndSelectedState() throws {
        let suiteName = "SwashKeyboardBarTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let e = try editor("Plain\n\n**bold** and [site](https://example.com)\n\n## Subheading\n\n1. first")
        e.textView.recentFormats = RecentFormatCommands(defaults: defaults)

        XCTAssertEqual(
            e.textView.recentFormatButtons.map { $0.accessibilityLabel },
            ["Bold", "Italic", "Link", "Bullet List", "Heading 1"],
            "initial bar shows the seeded recent commands"
        )

        // Using Heading 2 puts that variant at the front of the bar and applies it to "Plain"
        e.caret(after: "Plain")
        e.textView.invokeFormatCommand(.heading(2))
        e.pump()
        XCTAssertEqual(
            e.textView.recentFormatButtons.map { $0.accessibilityLabel },
            ["Heading 2", "Bold", "Italic", "Link", "Bullet List", "Heading 1"]
        )
        XCTAssertEqual(e.textView.recentButton(for: .heading(2))?.isSelected, true, "Heading 2 button shows selected on the heading line")

        // Exceeding 6 recents caps the bar at 6 recent buttons
        e.textView.invokeFormatCommand(.numberedList)
        e.pump()
        XCTAssertEqual(e.textView.recentFormatButtons.count, RecentFormatCommands.maxCount)
        XCTAssertEqual(e.textView.recentFormatButtons.first?.accessibilityLabel, "Numbered List")
        XCTAssertNil(e.textView.recentButton(for: .heading(1)), "oldest recent dropped past cap")
        XCTAssertEqual(e.textView.recentButton(for: .numberedList)?.isSelected, true)

        // Caret inside **bold** selects the Bold button and clears Numbered List
        e.caret(after: "**bo")
        e.textView.delegate?.textViewDidChangeSelection?(e.textView)
        XCTAssertEqual(e.textView.recentButton(for: .bold)?.isSelected, true)
        XCTAssertEqual(e.textView.recentButton(for: .numberedList)?.isSelected, false)
        XCTAssertEqual(e.textView.recentButton(for: .heading(2))?.isSelected, false)

        // Caret inside link selects the Link button
        e.caret(after: "[si")
        e.textView.delegate?.textViewDidChangeSelection?(e.textView)
        XCTAssertEqual(e.textView.recentButton(for: .link)?.isSelected, true)
        XCTAssertEqual(e.textView.recentButton(for: .bold)?.isSelected, false)
    }

    func testFormatPanelOffersEveryAvailableIOSFormatGroupedByManifestGroup() throws {
        let panelEntries = FormatManifestLayout.formatPanelEntries
        let expectedMenuEntries = FormatManifest.entries(for: .menu).filter(\.command.isAvailableOnIOS)
        XCTAssertEqual(panelEntries.map(\.command), expectedMenuEntries.map(\.command))
        XCTAssertTrue(panelEntries.allSatisfy(\.command.isAvailableOnIOS))

        let allAvailableCommands: [FormatCommand] = [
            .bold, .italic, .strikethrough, .code, .link,
            .heading(1), .heading(2), .heading(3), .paragraph,
            .bulletList, .numberedList, .taskList, .quote, .codeBlock,
        ]
        for command in allAvailableCommands {
            XCTAssertTrue(panelEntries.contains { $0.command == command }, "panel includes \(command)")
        }

        let panel = FormatPanel(entries: panelEntries, activeFormats: [.bold, .heading(2)], apply: { _ in }, close: {})
        XCTAssertEqual(panel.textStyles.map(\.command), [.heading(1), .heading(2), .heading(3), .paragraph])
        XCTAssertEqual(panel.groups.count, 2)
        XCTAssertEqual(panel.groups.first?.map(\.command), [.bold, .italic, .strikethrough, .code, .link])
        XCTAssertEqual(panel.groups.last?.map(\.command), [.bulletList, .numberedList, .taskList, .quote, .codeBlock])
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

    // MARK: - Pointer and keyboard navigation for code badges and block menu

    func testCodeBadgeButtonsHavePointerInteractionAndMenu() throws {
        let e = try editor("```swift\nlet x = 1\n```")
        e.textView.layoutSubviews()
        e.pump()
        XCTAssertEqual(e.textView.codeBadgeButtons.count, 1)
        let button = e.textView.codeBadgeButtons[0]
        XCTAssertFalse(button.isHidden)
        XCTAssertTrue(button.isPointerInteractionEnabled)
        XCTAssertNotNil(button.menu)
        XCTAssertTrue(button.accessibilityLabel?.contains("Swift") == true)
        XCTAssertEqual(button.accessibilityHint, "Double-tap or click to choose code language")
    }

    func testEditMenuOffersCodeLanguageForFencedCodeBlock() throws {
        let e = try editor("```swift\nlet x = 1\n```")
        e.caret(after: "let x")
        let textRange = try XCTUnwrap(e.textView.selectedTextRange)
        let menu = e.textView.editMenu(for: textRange, suggestedActions: [])
        let langMenu = menu?.children.compactMap { $0 as? UIMenu }.first(where: { $0.title == "Code Language" })
        XCTAssertNotNil(langMenu, "editMenu should include a 'Code Language' submenu when caret is inside a code block")

        let allActions: [UIAction] = (langMenu?.children ?? []).flatMap { item -> [UIAction] in
            if let action = item as? UIAction { return [action] }
            if let sub = item as? UIMenu { return sub.children.compactMap { $0 as? UIAction } }
            return []
        }
        let pythonAction = allActions.first(where: { $0.title == "Python" })
        XCTAssertNotNil(pythonAction)

        e.textView.coordinator?.setCodeLanguage("python", atStorageLocation: 0, in: e.textView)
        e.pump()
        XCTAssertTrue(e.text.hasPrefix("```python\n"))
    }

    func testBlockMenuViewControllerKeyboardNavigation() throws {
        var chosenKind: MarkdownEditingCommands.BlockInsert?
        let menu = BlockMenuViewController { kind in
            chosenKind = kind
        }
        XCTAssertEqual(menu.selectedIndex, 0)

        menu.beginAppearanceTransition(true, animated: false)
        menu.endAppearanceTransition()
        XCTAssertEqual(menu.selectedIndex, 0)

        // Down arrow advances selection
        menu.selectNext()
        XCTAssertEqual(menu.selectedIndex, 1)

        // Up arrow moves back
        menu.selectPrevious()
        XCTAssertEqual(menu.selectedIndex, 0)

        // Up arrow wraps to end
        menu.selectPrevious()
        XCTAssertEqual(menu.selectedIndex, menu.kinds.count - 1)

        // Down arrow wraps to start
        menu.selectNext()
        XCTAssertEqual(menu.selectedIndex, 0)

        // Return triggers selection
        menu.chooseSelected()
        XCTAssertEqual(chosenKind, menu.kinds[0])

        // Table cell has hoverStyle configured
        let cell = menu.tableView(menu.tableView, cellForRowAt: IndexPath(row: 0, section: 0))
        XCTAssertNotNil(cell.hoverStyle)
    }

    func testStyledUITextViewKeyCommandsInBlockMenu() throws {
        let e = try editor("Text\n\n")
        e.host.traitOverrides.horizontalSizeClass = .regular
        e.window.layoutIfNeeded()

        var chosenKind: MarkdownEditingCommands.BlockInsert?
        e.textView.presentBlockMenu { kind in
            chosenKind = kind
        }

        let keyCommands = try XCTUnwrap(e.textView.keyCommands)
        let inputs = keyCommands.map(\.input)
        XCTAssertTrue(inputs.contains(UIKeyCommand.inputDownArrow))
        XCTAssertTrue(inputs.contains(UIKeyCommand.inputUpArrow))
        XCTAssertTrue(inputs.contains("\r"))
        XCTAssertTrue(inputs.contains(UIKeyCommand.inputEscape))

        if let menu = e.textView.blockMenuPopover as? BlockMenuViewController {
            XCTAssertEqual(menu.selectedIndex, 0)
            e.textView.handleBlockMenuDown(UIKeyCommand(input: UIKeyCommand.inputDownArrow, modifierFlags: [], action: #selector(StyledUITextView.handleBlockMenuDown(_:))))
            XCTAssertEqual(menu.selectedIndex, 1)

            e.textView.handleBlockMenuUp(UIKeyCommand(input: UIKeyCommand.inputUpArrow, modifierFlags: [], action: #selector(StyledUITextView.handleBlockMenuUp(_:))))
            XCTAssertEqual(menu.selectedIndex, 0)

            e.textView.handleBlockMenuReturn(UIKeyCommand(input: "\r", modifierFlags: [], action: #selector(StyledUITextView.handleBlockMenuReturn(_:))))
            XCTAssertEqual(chosenKind, menu.kinds[0])
        }

        // Dismiss closes popover
        e.textView.presentBlockMenu { _ in }
        XCTAssertNotNil(e.textView.blockMenuPopover)
        e.textView.handleBlockMenuEscape(UIKeyCommand(input: UIKeyCommand.inputEscape, modifierFlags: [], action: #selector(StyledUITextView.handleBlockMenuEscape(_:))))
        XCTAssertNil(e.textView.blockMenuPopover)
    }

    // MARK: - Focus mode, typewriter scrolling, distraction-free & note links (#57)

    func testFocusModeDimsOutsideCurrentParagraphOrSentence() throws {
        let markdown = "First paragraph here.\n\nSecond paragraph. Another sentence here.\n\nThird paragraph."
        let e = try editor(markdown)
        let layoutManager = try XCTUnwrap(e.textView.layoutManager as? StyledLayoutManager)
        XCTAssertNil(layoutManager.focusedCharacterRange)

        // Paragraph focus on the second paragraph
        e.caret(after: "Second")
        e.setWritingOptions(WritingOptions(focus: .paragraph))
        let ns = e.storage.string as NSString
        let secondPara = ns.paragraphRange(for: ns.range(of: "Second paragraph"))
        XCTAssertEqual(layoutManager.focusedCharacterRange, secondPara)
        XCTAssertEqual(layoutManager.focusAlpha(for: ns.range(of: "First").location), StyledLayoutManager.unfocusedAlpha)
        XCTAssertEqual(layoutManager.focusAlpha(for: ns.range(of: "Second").location), 1)
        XCTAssertEqual(layoutManager.focusAlpha(for: ns.range(of: "Another sentence").location), 1)
        XCTAssertEqual(layoutManager.focusAlpha(for: ns.range(of: "Third").location), StyledLayoutManager.unfocusedAlpha)

        // Sentence focus narrows to the current sentence within the second paragraph
        e.setWritingOptions(WritingOptions(focus: .sentence))
        XCTAssertEqual(layoutManager.focusAlpha(for: ns.range(of: "Second").location), 1)
        XCTAssertEqual(layoutManager.focusAlpha(for: ns.range(of: "Another sentence").location), StyledLayoutManager.unfocusedAlpha)

        // Moving the selection updates the focused sentence
        e.caret(after: "Another")
        e.textView.delegate?.textViewDidChangeSelection?(e.textView)
        XCTAssertEqual(layoutManager.focusAlpha(for: ns.range(of: "Second").location), StyledLayoutManager.unfocusedAlpha)
        XCTAssertEqual(layoutManager.focusAlpha(for: ns.range(of: "Another").location), 1)

        // Turning Focus Mode off clears the focused range
        e.setWritingOptions(WritingOptions(focus: nil))
        XCTAssertNil(layoutManager.focusedCharacterRange)
        XCTAssertEqual(layoutManager.focusAlpha(for: ns.range(of: "First").location), 1)
    }

    func testTypewriterScrollingAndDistractionFreeFormattingBar() throws {
        let lines = (1...40).map { "Line \($0) of the document." }.joined(separator: "\n\n")
        let e = try editor(lines)
        XCTAssertNotNil(e.textView.inputAccessoryView, "formatting bar is installed by default")
        XCTAssertEqual(e.textView.textContainerInset.top, 20)

        // Distraction-free + typewriter scrolling
        e.setWritingOptions(WritingOptions(typewriter: true, readableColumn: true, columnWidth: 200), formattingEnabled: false)
        XCTAssertNil(e.textView.inputAccessoryView, "distraction-free mode hides the formatting bar")
        XCTAssertEqual(e.textView.textContainerInset.top, (e.textView.bounds.height / 2).rounded(), "typewriter scrolling adds vertical margin")
        XCTAssertGreaterThan(e.textView.textContainerInset.left, 14, "readable column insets the sides when wider than the column")

        // The harness leaves the caret at the end of the text, so start from the top explicitly
        e.select(raw: NSRange(location: 0, length: 0))
        e.textView.delegate?.textViewDidChangeSelection?(e.textView)
        let offsetNearTop = e.textView.contentOffset.y
        e.caret(after: "Line 25")
        e.textView.delegate?.textViewDidChangeSelection?(e.textView)
        XCTAssertGreaterThan(e.textView.contentOffset.y, offsetNearTop + 100, "typewriter scrolling scrolls to keep the caret centred")
        let caret = e.textView.caretRect(for: try XCTUnwrap(e.textView.selectedTextRange).end)
        let insets = e.textView.adjustedContentInset
        let visibleMidY = e.textView.contentOffset.y + insets.top + (e.textView.bounds.height - insets.top - insets.bottom) / 2
        XCTAssertEqual(caret.midY, visibleMidY, accuracy: 30, "the caret's line sits in the middle of the visible area")

        // Exiting distraction-free restores the formatting bar
        e.setWritingOptions(WritingOptions(), formattingEnabled: true)
        XCTAssertNotNil(e.textView.inputAccessoryView)
        XCTAssertEqual(e.textView.textContainerInset.top, 20)
    }

    func testRelativeAndWikiNoteLinksResolveInFolder() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("SwashNoteLinks-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        let indexURL = folder.appendingPathComponent("Index.md")
        let otherURL = folder.appendingPathComponent("Other.md")
        let ideasURL = folder.appendingPathComponent("Ideas.md")
        let markdown = "See [other](Other.md) and [[Ideas]] for more."
        try markdown.write(to: indexURL, atomically: true, encoding: .utf8)
        try "# Other\n".write(to: otherURL, atomically: true, encoding: .utf8)
        try "# Ideas\n".write(to: ideasURL, atomically: true, encoding: .utf8)

        let e = try editor(markdown)
        e.setWritingOptions(WritingOptions(), baseURL: indexURL)

        let ns = markdown as NSString
        let relativePos = NSRange(location: ns.range(of: "other").location + 1, length: 0)
        XCTAssertEqual(e.textView.noteURL(at: relativePos)?.standardizedFileURL, otherURL.standardizedFileURL)

        let wikiPos = NSRange(location: ns.range(of: "Ideas").location + 1, length: 0)
        XCTAssertEqual(e.textView.noteURL(at: wikiPos)?.standardizedFileURL, ideasURL.standardizedFileURL)
    }

    func testConflictResolutionChoicesAndKeepCurrent() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("SwashConflicts-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        let fileURL = folder.appendingPathComponent("Note.md")
        try "# Current\n\nBody text.".write(to: fileURL, atomically: true, encoding: .utf8)

        XCTAssertTrue(DocumentConflicts.unresolved(at: fileURL).isEmpty)
        let choices = DocumentConflicts.choices(at: fileURL)
        XCTAssertEqual(choices.count, 1)
        XCTAssertEqual(choices.first?.title, "This Version")
        XCTAssertNil(try DocumentConflicts.resolve(at: fileURL, keeping: choices.first?.version))
    }

    // MARK: - Caret size (SWA-64 / #186)

    func testCaretRectHeightMatchesVisibleTextAndNeverCollapsesToDot() throws {
        let markdown = "# Heading\n\nIntro with **bold** and *italic* text.\n\n- List item\n\n"
        let e = try editor(markdown)

        func caretRectAt(raw: NSRange) throws -> CGRect {
            e.select(raw: raw)
            let pos = try XCTUnwrap(e.textView.selectedTextRange?.start)
            return e.textView.caretRect(for: pos)
        }

        let baseHeight = e.coordinator.baseFont.lineHeight

        // 1. Heading: at start of heading, caret height matches heading font line height (~28+ pt)
        // and is never a dot (< 5 pt) or stretched by paragraphSpacingBefore
        let headingRange = (markdown as NSString).range(of: "Heading")
        let headingCaret = try caretRectAt(raw: NSRange(location: headingRange.location, length: 0))
        let headingFont = try XCTUnwrap(e.storage.attribute(.font, at: e.coordinator.storageRange(forRaw: headingRange, in: e.textView).location, effectiveRange: nil) as? UIFont)
        XCTAssertEqual(headingCaret.height, headingFont.lineHeight, accuracy: 0.5, "caret at heading matches heading line height")
        XCTAssertGreaterThan(headingCaret.height, baseHeight, "heading caret is larger than body text")

        // 2. Empty line between heading and body: matches baseFont line height, never heading height or dot
        let emptyLine1Location = (markdown as NSString).range(of: "\n\nIntro").location + 1
        let emptyLineCaret = try caretRectAt(raw: NSRange(location: emptyLine1Location, length: 0))
        XCTAssertEqual(emptyLineCaret.height, baseHeight, accuracy: 0.5, "caret on empty line matches body font line height")

        // 3. Normal body text: matches baseFont line height
        let bodyRange = (markdown as NSString).range(of: "Intro with")
        let bodyCaret = try caretRectAt(raw: NSRange(location: bodyRange.location, length: 0))
        XCTAssertEqual(bodyCaret.height, baseHeight, accuracy: 0.5, "caret in body text matches body font line height")

        // 4. Next to bold markers: **bold**
        let boldRange = (markdown as NSString).range(of: "bold")
        // Just before "bold" (at or next to the leading ** marker)
        let boldStartCaret = try caretRectAt(raw: NSRange(location: boldRange.location, length: 0))
        XCTAssertEqual(boldStartCaret.height, baseHeight, accuracy: 0.5, "caret next to bold marker matches body text")
        XCTAssertGreaterThan(boldStartCaret.height, 10, "caret is never a collapsed dot")
        // Just after "bold" (next to trailing ** marker)
        let boldEndCaret = try caretRectAt(raw: NSRange(location: NSMaxRange(boldRange), length: 0))
        XCTAssertEqual(boldEndCaret.height, baseHeight, accuracy: 0.5, "caret after bold matches body text")

        // 5. Next to italic markers: *italic*
        let italicRange = (markdown as NSString).range(of: "italic")
        let italicStartCaret = try caretRectAt(raw: NSRange(location: italicRange.location, length: 0))
        XCTAssertEqual(italicStartCaret.height, baseHeight, accuracy: 0.5, "caret next to italic marker matches body text")
        let italicEndCaret = try caretRectAt(raw: NSRange(location: NSMaxRange(italicRange), length: 0))
        XCTAssertEqual(italicEndCaret.height, baseHeight, accuracy: 0.5, "caret after italic matches body text")

        // 6. List item: next to hidden prefix marker "- "
        let listRange = (markdown as NSString).range(of: "List item")
        let listCaret = try caretRectAt(raw: NSRange(location: listRange.location, length: 0))
        XCTAssertEqual(listCaret.height, baseHeight, accuracy: 0.5, "caret at list item matches body text")
        XCTAssertGreaterThan(listCaret.height, 10, "caret at list item is never a dot")

        // 7. Trailing empty line at end of document
        let trailingCaret = try caretRectAt(raw: NSRange(location: (markdown as NSString).length, length: 0))
        XCTAssertEqual(trailingCaret.height, baseHeight, accuracy: 0.5, "caret at trailing empty line matches body text")

        // 8. Empty document
        let emptyDoc = try editor("")
        let emptyPos = try XCTUnwrap(emptyDoc.textView.position(from: emptyDoc.textView.beginningOfDocument, offset: 0))
        let emptyDocCaret = emptyDoc.textView.caretRect(for: emptyPos)
        XCTAssertEqual(emptyDocCaret.height, emptyDoc.coordinator.baseFont.lineHeight, accuracy: 0.5, "caret in empty document matches body font line height")
    }

    // MARK: - List formatting commands (SWA-68 / #190)

    private func listMarkers(in e: EditorHarness) -> [(range: NSRange, info: ListMarkerInfo)] {
        var result: [(NSRange, ListMarkerInfo)] = []
        e.storage.enumerateAttribute(.listMarker, in: NSRange(location: 0, length: e.storage.length), options: []) { value, range, _ in
            if let info = value as? ListMarkerInfo { result.append((range, info)) }
        }
        return result
    }

    func testChoosingEachListTypeOnAnEmptyLineAppliesImmediatelyAndTogglesOff() throws {
        let cases: [(command: FormatCommand, marker: String, glyph: String)] = [
            (.bulletList, "- ", "•"),
            (.numberedList, "1. ", "1."),
            (.taskList, "- [ ] ", "☐"),
        ]

        for item in cases {
            // 1. Empty document / single empty line
            let empty = try editor("")
            empty.textView.invokeFormatCommand(item.command)
            XCTAssertEqual(empty.text, item.marker, "\(item.command) on empty line inserts \(item.marker.debugDescription) immediately")
            XCTAssertEqual(empty.rawSelection, NSRange(location: (item.marker as NSString).length, length: 0), "caret sits after the marker")
            XCTAssertEqual(empty.textView.selectedRange, NSRange(location: (item.marker as NSString).length, length: 0))
            XCTAssertEqual(listMarkers(in: empty).map(\.info.text), [item.glyph], "marker is styled synchronously without waiting for the next keystroke")
            XCTAssertTrue(empty.textView.activeFormats.contains(item.command), "format button shows active on the empty list item")

            // Caret rect on the empty list item has body line height and sits at the line's baseline
            let caretPos = try XCTUnwrap(empty.textView.selectedTextRange?.end)
            let caretRect = empty.textView.caretRect(for: caretPos)
            XCTAssertEqual(caretRect.height, empty.coordinator.baseFont.lineHeight, accuracy: 0.5)
            XCTAssertGreaterThanOrEqual(caretRect.minY, empty.textView.textContainerInset.top - 1)

            // Picking the same list type again on the empty item removes the list (toggle)
            empty.textView.invokeFormatCommand(item.command)
            XCTAssertEqual(empty.text, "", "picking \(item.command) again removes the marker")
            XCTAssertEqual(empty.rawSelection, NSRange(location: 0, length: 0))
            XCTAssertTrue(listMarkers(in: empty).isEmpty, "list marker attribute is removed immediately")
            XCTAssertFalse(empty.textView.activeFormats.contains(item.command))

            // 2. Empty line between paragraphs, followed by typing into the new item
            let between = try editor("First\n\nLast")
            between.select(raw: NSRange(location: 6, length: 0))
            between.textView.invokeFormatCommand(item.command)
            let expectedEmptyMid = "First\n\(item.marker)\nLast"
            XCTAssertEqual(between.text, expectedEmptyMid, "\(item.command) on blank middle line")
            XCTAssertEqual(between.rawSelection, NSRange(location: 6 + (item.marker as NSString).length, length: 0))
            XCTAssertEqual(listMarkers(in: between).map(\.info.text), [item.glyph], "marker is styled immediately on middle line")
            XCTAssertTrue(between.textView.activeFormats.contains(item.command))

            between.type("Item text")
            XCTAssertEqual(between.text, "First\n\(item.marker)Item text\nLast", "next typed text lands inside the list item")
            XCTAssertEqual(listMarkers(in: between).map(\.info.text), [item.glyph])
        }
    }

    func testChoosingEachListTypeOnALineWithTextAppliesImmediatelyAndTogglesOff() throws {
        let cases: [(command: FormatCommand, marker: String, glyph: String)] = [
            (.bulletList, "- ", "•"),
            (.numberedList, "1. ", "1."),
            (.taskList, "- [ ] ", "☐"),
        ]

        for item in cases {
            let e = try editor("Buy groceries")
            e.caret(after: "Buy")
            let initialCaret = e.rawSelection.location

            e.textView.invokeFormatCommand(item.command)
            let markerLen = (item.marker as NSString).length
            XCTAssertEqual(e.text, "\(item.marker)Buy groceries", "\(item.command) on line with text")
            XCTAssertEqual(e.rawSelection, NSRange(location: initialCaret + markerLen, length: 0), "caret stays at the same place in the text")
            XCTAssertEqual(listMarkers(in: e).map(\.info.text), [item.glyph], "marker is styled synchronously")
            XCTAssertTrue(e.textView.activeFormats.contains(item.command), "format button shows active")

            // Picking the same list type again removes the list (toggle)
            e.textView.invokeFormatCommand(item.command)
            XCTAssertEqual(e.text, "Buy groceries", "picking \(item.command) again toggles the list off")
            XCTAssertEqual(e.rawSelection, NSRange(location: initialCaret, length: 0))
            XCTAssertTrue(listMarkers(in: e).isEmpty)
            XCTAssertFalse(e.textView.activeFormats.contains(item.command))
        }
    }

    func testSwitchingBetweenListTypesOnEmptyAndNonEmptyLines() throws {
        let e = try editor("")
        e.textView.invokeFormatCommand(.bulletList)
        XCTAssertEqual(e.text, "- ")
        XCTAssertEqual(listMarkers(in: e).map(\.info.text), ["•"])

        // Switch empty bullet item directly to numbered, then to task list
        e.textView.invokeFormatCommand(.numberedList)
        XCTAssertEqual(e.text, "1. ")
        XCTAssertEqual(e.rawSelection, NSRange(location: 3, length: 0))
        XCTAssertEqual(listMarkers(in: e).map(\.info.text), ["1."])
        XCTAssertTrue(e.textView.activeFormats.contains(.numberedList))
        XCTAssertFalse(e.textView.activeFormats.contains(.bulletList))

        e.textView.invokeFormatCommand(.taskList)
        XCTAssertEqual(e.text, "- [ ] ")
        XCTAssertEqual(e.rawSelection, NSRange(location: 6, length: 0))
        XCTAssertEqual(listMarkers(in: e).map(\.info.text), ["☐"])
        XCTAssertTrue(e.textView.activeFormats.contains(.taskList))

        // Type text and switch back to bullet list
        e.type("milk")
        XCTAssertEqual(e.text, "- [ ] milk")
        e.textView.invokeFormatCommand(.bulletList)
        XCTAssertEqual(e.text, "- milk")
        XCTAssertEqual(listMarkers(in: e).map(\.info.text), ["•"])
    }

    // MARK: - Insert Affordance Overlay (SWA-94)

    func testInsertAffordanceRevealsAfterDebounceOnEmptyLine() throws {
        let e = try editor("Hello\n\nWorld")
        _ = e.textView.becomeFirstResponder()
        e.pump(0.1)

        // Caret on the empty middle line
        e.select(raw: NSRange(location: 6, length: 0))
        e.pump(0.1)

        // Before debounce finishes, affordance shouldn't be visible
        if let button = e.textView.insertAffordanceButton {
            XCTAssertTrue(button.isHidden || button.alpha == 0, "Affordance should not be visible immediately")
        }

        // Wait for 750ms debounce (plus buffer)
        e.pump(0.85)

        let button = try XCTUnwrap(e.textView.insertAffordanceButton, "Affordance button must exist after debounce")
        XCTAssertFalse(button.isHidden, "Affordance button should be visible")
        XCTAssertEqual(button.alpha, 1.0, accuracy: 0.05, "Affordance button alpha should be 1.0")

        // Button should be centered at the caret
        let caret = e.textView.caretRect(for: e.textView.selectedTextRange!.start)
        XCTAssertEqual(button.center.x, caret.minX, accuracy: 2.0)
        XCTAssertEqual(button.center.y, caret.midY, accuracy: 2.0)
    }

    func testInsertAffordanceDoesNotShowOnNonEmptyLine() throws {
        let e = try editor("Hello\nWorld")
        _ = e.textView.becomeFirstResponder()
        e.pump(0.1)

        // Move caret to non-empty line
        e.select(raw: NSRange(location: 2, length: 0))
        e.pump(0.1)

        // Wait beyond debounce
        e.pump(0.85)

        if let button = e.textView.insertAffordanceButton {
            XCTAssertTrue(button.isHidden || button.alpha == 0, "Affordance must not show on a non-empty line")
        }
    }

    func testInsertAffordanceHidesImmediatelyOnTyping() throws {
        let e = try editor("")
        _ = e.textView.becomeFirstResponder()
        e.pump(0.1)
        e.select(raw: NSRange(location: 0, length: 0))
        e.pump(0.85)

        let button = try XCTUnwrap(e.textView.insertAffordanceButton)
        XCTAssertFalse(button.isHidden)

        // Type a character
        e.type("a")

        XCTAssertTrue(button.isHidden, "Affordance must hide immediately upon typing")
        XCTAssertEqual(button.alpha, 0, "Affordance alpha must be 0 immediately upon typing")
    }

    func testInsertAffordanceHidesOnSelectionChange() throws {
        let e = try editor("First\n\nSecond")
        _ = e.textView.becomeFirstResponder()
        e.pump(0.1)

        // Move to empty line and wait for affordance
        e.select(raw: NSRange(location: 6, length: 0))
        e.pump(0.85)

        let button = try XCTUnwrap(e.textView.insertAffordanceButton)
        XCTAssertFalse(button.isHidden)

        // Move selection to non-empty line
        e.select(raw: NSRange(location: 1, length: 0))

        XCTAssertTrue(button.isHidden, "Affordance must hide immediately upon selection change")
    }

    func testInsertAffordanceHidesOnScroll() throws {
        let e = try editor("First\n\nSecond")
        _ = e.textView.becomeFirstResponder()
        e.pump(0.1)

        e.select(raw: NSRange(location: 6, length: 0))
        e.pump(0.85)

        let button = try XCTUnwrap(e.textView.insertAffordanceButton)
        XCTAssertFalse(button.isHidden)

        // Simulate scrolling
        e.textView.setContentOffset(CGPoint(x: 0, y: 50), animated: false)
        e.coordinator.scrollViewDidScroll(e.textView)

        XCTAssertTrue(button.isHidden, "Affordance must hide immediately upon scrolling")
    }

    func testInsertAffordanceTimerCancelledIfInterruptedBeforeFiring() throws {
        let e = try editor("")
        _ = e.textView.becomeFirstResponder()
        e.pump(0.1)
        e.select(raw: NSRange(location: 0, length: 0))

        // Wait 350ms (less than 750ms)
        e.pump(0.35)

        // Type before timer fires
        e.type("x")

        // Wait remainder of time
        e.pump(0.55)

        if let button = e.textView.insertAffordanceButton {
            XCTAssertTrue(button.isHidden || button.alpha == 0, "Affordance must not show if typing occurred before debounce elapsed")
        }
    }

    func testInsertAffordanceTapOpensInsertPanel() throws {
        let e = try editor("")
        _ = e.textView.becomeFirstResponder()
        e.pump(0.1)
        e.select(raw: NSRange(location: 0, length: 0))
        e.pump(0.85)

        let button = try XCTUnwrap(e.textView.insertAffordanceButton)
        XCTAssertFalse(button.isHidden)
        XCTAssertTrue(button.isAccessibilityElement)

        // Tap the affordance button
        button.sendActions(for: .touchUpInside)
        e.pump(0.1)

        // The button should hide immediately and fall out of accessibility tree
        XCTAssertTrue(button.isHidden, "Affordance must hide immediately upon tap")
        XCTAssertEqual(button.alpha, 0, "Affordance alpha must be 0 upon tap")
        XCTAssertFalse(button.isAccessibilityElement, "Affordance must not be an accessibility element when hidden")

        // The insert panel should now be presented
        XCTAssertTrue(e.textView.isShowingInsertPanel, "Tapping insert affordance should open insert panel")
        XCTAssertTrue(e.textView.inputView is InsertPanelInputView, "Input view should be InsertPanelInputView")
    }

    func testInsertAffordanceVoiceOverAccessibilityState() throws {
        let e = try editor("First\n\nSecond")
        _ = e.textView.becomeFirstResponder()
        e.pump(0.1)

        // Caret on empty line (offset 6)
        e.select(raw: NSRange(location: 6, length: 0))
        e.pump(0.1)

        // Before debounce, button is either nil or not an accessibility element
        if let button = e.textView.insertAffordanceButton {
            XCTAssertFalse(button.isAccessibilityElement, "Affordance must not be an accessibility element before visible")
        }

        // Wait for debounce reveal
        e.pump(0.85)

        let button = try XCTUnwrap(e.textView.insertAffordanceButton)
        XCTAssertFalse(button.isHidden)
        XCTAssertEqual(button.alpha, 1.0, accuracy: 0.05)
        XCTAssertTrue(button.isAccessibilityElement, "Affordance must be an accessibility element strictly while visible")
        XCTAssertEqual(button.accessibilityLabel, "Insert block", "Accessibility label must be 'Insert block'")
        XCTAssertTrue(button.accessibilityTraits.contains(.button), "Accessibility traits must include .button")
        XCTAssertEqual(button.accessibilityIdentifier, "EmptyLineInsertButton")

        // Accessibility activation triggers the button action
        XCTAssertTrue(button.accessibilityActivate())
        e.pump(0.1)

        XCTAssertTrue(button.isHidden)
        XCTAssertFalse(button.isAccessibilityElement, "Affordance must not be accessible after tap/activation")
        XCTAssertTrue(e.textView.isShowingInsertPanel)
    }

    func testTappingEmptyLineInsertAffordanceOpensInsertPanelAndInsertsAtTargetLine() throws {
        let e = try editor("Intro\n\nOutro")
        _ = e.textView.becomeFirstResponder()
        e.pump(0.1)

        // Caret on the empty line (offset 6)
        e.select(raw: NSRange(location: 6, length: 0))
        e.pump(0.85)

        let button = try XCTUnwrap(e.textView.insertAffordanceButton)
        XCTAssertFalse(button.isHidden)

        // Tap affordance
        button.sendActions(for: .primaryActionTriggered)
        e.pump(0.1)

        XCTAssertTrue(button.isHidden)
        XCTAssertFalse(button.isAccessibilityElement)
        XCTAssertTrue(e.textView.isShowingInsertPanel)

        // Insert a callout block via the insert panel callback
        e.textView.handleInsertBlock(.callout)
        e.pump(0.1)

        XCTAssertFalse(e.textView.isShowingInsertPanel)
        XCTAssertNil(e.textView.inputView)
        XCTAssertEqual(e.textView.markdownText, "Intro\n> [!NOTE]\n> \nOutro")
        XCTAssertEqual(e.textView.markdownSelection.location, "Intro\n> [!NOTE]\n> ".count)
    }

    func testBlockInsertKindCommands() throws {
        // Table
        let tableEdit = MarkdownEditingCommands.insertBlock(.table, text: "Intro\n\nOutro", at: 6)
        XCTAssertTrue(tableEdit.text.contains("| Column 1 | Column 2 |"))
        XCTAssertTrue(tableEdit.text.contains("| --- | --- |"))
        XCTAssertTrue(tableEdit.text.contains("|  |  |"))

        // Code block
        let codeEdit = MarkdownEditingCommands.insertBlock(.codeBlock, text: "", at: 0)
        XCTAssertEqual(codeEdit.text, "```\n\n```")
        XCTAssertEqual(codeEdit.selection.location, 4)

        // Math
        let mathEdit = MarkdownEditingCommands.insertBlock(.math, text: "", at: 0)
        XCTAssertEqual(mathEdit.text, "$$\n\n$$")
        XCTAssertEqual(mathEdit.selection.location, 3)

        // Mermaid
        let mermaidEdit = MarkdownEditingCommands.insertBlock(.mermaid, text: "", at: 0)
        XCTAssertEqual(mermaidEdit.text, "```mermaid\ngraph TD\n    \n```")
        XCTAssertEqual(mermaidEdit.selection.location, "```mermaid\ngraph TD\n    ".count)

        // Image
        let imageEdit = MarkdownEditingCommands.insertBlock(.image, text: "", at: 0)
        XCTAssertEqual(imageEdit.text, "![Image]()")
        XCTAssertEqual(imageEdit.selection.location, "![Image](".count)
    }

    func testInsertAffordanceDoesNotShowWhenPreferenceDisabled() throws {
        UserDefaults.standard.set(false, forKey: AppSettings.showEmptyLineInsertAffordance)
        defer { UserDefaults.standard.removeObject(forKey: AppSettings.showEmptyLineInsertAffordance) }

        let e = try editor("")
        _ = e.textView.becomeFirstResponder()
        e.pump(0.1)
        e.select(raw: NSRange(location: 0, length: 0))
        e.pump(0.85)

        if let button = e.textView.insertAffordanceButton {
            XCTAssertTrue(button.isHidden || button.alpha == 0, "Affordance must not show when showEmptyLineInsertAffordance is disabled")
        }
    }

    func testInsertAffordanceDynamicToggleDismissesActiveAffordanceImmediately() throws {
        UserDefaults.standard.set(true, forKey: AppSettings.showEmptyLineInsertAffordance)
        defer { UserDefaults.standard.removeObject(forKey: AppSettings.showEmptyLineInsertAffordance) }

        let e = try editor("")
        _ = e.textView.becomeFirstResponder()
        e.pump(0.1)
        e.select(raw: NSRange(location: 0, length: 0))
        e.pump(0.85)

        let button = try XCTUnwrap(e.textView.insertAffordanceButton)
        XCTAssertFalse(button.isHidden)
        XCTAssertEqual(button.alpha, 1.0)

        // Toggle preference to false dynamically via coordinator / UserDefaults notification
        UserDefaults.standard.set(false, forKey: AppSettings.showEmptyLineInsertAffordance)
        NotificationCenter.default.post(name: UserDefaults.didChangeNotification, object: nil)
        e.pump(0.05)

        XCTAssertTrue(button.isHidden || button.alpha == 0, "Toggling preference off must immediately dismiss active affordance")
        XCTAssertFalse(e.coordinator.showEmptyLineInsertAffordance)

        // Toggle back on
        UserDefaults.standard.set(true, forKey: AppSettings.showEmptyLineInsertAffordance)
        NotificationCenter.default.post(name: UserDefaults.didChangeNotification, object: nil)
        XCTAssertTrue(e.coordinator.showEmptyLineInsertAffordance)
    }

    // MARK: - Insert Panel & Keyboard Bar Toggle (SWA-92)

    func testInsertPanelToggleAndMutualExclusivityWithFormatPanel() throws {
        let e = try editor("# Test")
        let textView = e.textView

        // Initially neither panel is showing
        XCTAssertFalse(textView.isShowingInsertPanel)
        XCTAssertFalse(textView.isShowingFormatPanel)

        // Toggle Insert panel
        textView.toggleInsertPanel()
        XCTAssertTrue(textView.isShowingInsertPanel)
        XCTAssertFalse(textView.isShowingFormatPanel)
        XCTAssertTrue(textView.inputView is InsertPanelInputView)

        // Opening format panel while insert panel is showing dismisses insert panel
        textView.toggleFormatPanel()
        XCTAssertTrue(textView.isShowingFormatPanel)
        XCTAssertFalse(textView.isShowingInsertPanel)
        XCTAssertTrue(textView.inputView is FormatPanelInputView)

        // Opening insert panel while format panel is showing dismisses format panel
        textView.toggleInsertPanel()
        XCTAssertTrue(textView.isShowingInsertPanel)
        XCTAssertFalse(textView.isShowingFormatPanel)
        XCTAssertTrue(textView.inputView is InsertPanelInputView)

        // Resigning first responder dismisses the panel
        _ = textView.resignFirstResponder()
        XCTAssertFalse(textView.isShowingInsertPanel)
        XCTAssertNil(textView.inputView)
    }
}



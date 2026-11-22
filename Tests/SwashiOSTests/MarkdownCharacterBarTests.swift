//
//  MarkdownCharacterBarTests.swift
//  SwashiOSTests
//
//  Tests for the Markdown character quick access bar above the iOS keyboard (#191).
//

import XCTest
import UIKit
@testable import Swash

@MainActor
final class MarkdownCharacterBarTests: XCTestCase {
    func testMarkdownCharacterEntriesCompletenessAndAccessibilityLabels() {
        let expectedCharacters = ["#", "*", "_", "`", ">", "-", "[", "]", "(", ")", "|", "!", "~"]
        let actualCharacters = MarkdownCharacterBar.entries.map(\.character)
        XCTAssertEqual(actualCharacters, expectedCharacters)

        let expectedLabels: [String: String] = [
            "#": "Number sign",
            "*": "Asterisk",
            "_": "Underscore",
            "`": "Backtick",
            ">": "Greater than",
            "-": "Hyphen",
            "[": "Left bracket",
            "]": "Right bracket",
            "(": "Left parenthesis",
            ")": "Right parenthesis",
            "|": "Vertical bar",
            "!": "Exclamation mark",
            "~": "Tilde",
        ]

        for entry in MarkdownCharacterBar.entries {
            XCTAssertEqual(entry.accessibilityLabel, expectedLabels[entry.character], "Unexpected label for \(entry.character)")
        }

        // Verify variants for `#` and '`'
        let hashEntry = try? XCTUnwrap(MarkdownCharacterBar.entries.first { $0.character == "#" })
        XCTAssertEqual(hashEntry?.variants, ["##", "###"])

        let backtickEntry = try? XCTUnwrap(MarkdownCharacterBar.entries.first { $0.character == "`" })
        XCTAssertEqual(backtickEntry?.variants, ["```"])
    }

    func testCharacterButtonConfigurationAndActions() {
        var tapped = false
        var chosenVariant: String? = nil

        let button = GlassAccessoryBar.characterButton(
            character: "#",
            label: "Number sign",
            action: UIAction { _ in tapped = true },
            variants: ["##", "###"],
            onVariant: { chosenVariant = $0 }
        )

        XCTAssertEqual(button.accessibilityLabel, "Number sign")
        XCTAssertEqual(button.largeContentTitle, "# (Number sign)")
        XCTAssertFalse(button.showsMenuAsPrimaryAction, "Menu should be for secondary/long-press action")
        XCTAssertNotNil(button.menu)
        XCTAssertEqual(button.menu?.children.count, 2)

        // Trigger primary action
        button.sendActions(for: .primaryActionTriggered)
        XCTAssertTrue(tapped)

        // Trigger menu variant
        if let firstAction = button.menu?.children.first as? UIAction {
            XCTAssertEqual(firstAction.title, "##")
            // Invoke the action
            firstAction.performWithSender(nil, target: nil)
            XCTAssertEqual(chosenVariant, "##")
        } else {
            XCTFail("Expected UIAction in menu")
        }
    }

    func testSourceModeOrderingInKeyboardBar() {
        let textView = MarkdownEditingTextView(usingTextLayoutManager: false)
        XCTAssertTrue(textView.isSourceMode)

        textView.installFormattingBar(enabled: true)
        guard let bar = textView.inputAccessoryView as? GlassAccessoryBar else {
            XCTFail("Expected GlassAccessoryBar")
            return
        }

        // Collect all buttons in the bar
        let buttons = allButtons(in: bar)
        let labels = buttons.compactMap(\.accessibilityLabel)

        // The format panel button "Format" is leading
        XCTAssertEqual(labels.first, "Format")

        // In Source mode, character buttons appear first (before format commands like Bold)
        let hashIndex = labels.firstIndex(of: "Number sign")
        let boldIndex = labels.firstIndex(of: "Bold")

        XCTAssertNotNil(hashIndex, "Expected Number sign button in bar")
        XCTAssertNotNil(boldIndex, "Expected Bold button in bar")
        if let hashIndex, let boldIndex {
            XCTAssertLessThan(hashIndex, boldIndex, "In Source mode, character strip should appear before format buttons")
        }
    }

    func testFormattedModeOrderingInKeyboardBar() {
        let textView = StyledUITextView(frame: .zero, textContainer: nil)
        XCTAssertFalse(textView.isSourceMode)

        textView.installFormattingBar(enabled: true)
        guard let bar = textView.inputAccessoryView as? GlassAccessoryBar else {
            XCTFail("Expected GlassAccessoryBar")
            return
        }

        let buttons = allButtons(in: bar)
        let labels = buttons.compactMap(\.accessibilityLabel)

        XCTAssertEqual(labels.first, "Format")

        // In Formatted mode, format commands appear first, and characters follow
        let hashIndex = labels.firstIndex(of: "Number sign")
        let boldIndex = labels.firstIndex(of: "Bold")

        XCTAssertNotNil(hashIndex, "Expected Number sign button in bar")
        XCTAssertNotNil(boldIndex, "Expected Bold button in bar")
        if let hashIndex, let boldIndex {
            XCTAssertLessThan(boldIndex, hashIndex, "In Formatted mode, format buttons should appear before character strip")
        }
    }

    func testTypingCharactersAndUndoInSourceMode() {
        let textView = MarkdownEditingTextView(usingTextLayoutManager: false)
        textView.installFormattingBar(enabled: true)

        let buttons = textView.makeCharacterButtons()
        let hashButton = try? XCTUnwrap(buttons.first { $0.accessibilityLabel == "Number sign" })

        // Type `#`
        hashButton?.sendActions(for: .primaryActionTriggered)
        XCTAssertEqual(textView.text, "#")

        // Undo should remove the characters just like typed text
        textView.undoManager?.undo()
        XCTAssertEqual(textView.text, "")
    }

    func testTypingCharactersAndUndoInFormattedMode() {
        let textView = StyledUITextView(frame: .zero, textContainer: nil)
        textView.installFormattingBar(enabled: true)

        let buttons = textView.makeCharacterButtons()
        let bracketButton = try? XCTUnwrap(buttons.first { $0.accessibilityLabel == "Left bracket" })

        bracketButton?.sendActions(for: .primaryActionTriggered)
        XCTAssertEqual(textView.text, "[")

        textView.undoManager?.undo()
        XCTAssertEqual(textView.text, "")
    }

    func testLongPressVariantInsertion() {
        let textView = MarkdownEditingTextView(usingTextLayoutManager: false)
        textView.installFormattingBar(enabled: true)

        let buttons = textView.makeCharacterButtons()
        let backtickButton = try? XCTUnwrap(buttons.first { $0.accessibilityLabel == "Backtick" })

        guard let fenceAction = backtickButton?.menu?.children.first as? UIAction else {
            XCTFail("Expected variant action for backtick")
            return
        }

        XCTAssertEqual(fenceAction.title, "```")
        fenceAction.performWithSender(nil, target: nil)
        XCTAssertEqual(textView.text, "```")

        textView.undoManager?.undo()
        XCTAssertEqual(textView.text, "")
    }

    // MARK: - Helpers

    private func allButtons(in view: UIView) -> [UIButton] {
        var result: [UIButton] = []
        if let button = view as? UIButton {
            result.append(button)
        }
        for subview in view.subviews {
            result.append(contentsOf: allButtons(in: subview))
        }
        return result
    }
}

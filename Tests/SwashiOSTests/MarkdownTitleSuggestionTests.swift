//
//  MarkdownTitleSuggestionTests.swift
//  SwashiOSTests
//

import XCTest
@testable import Swash

final class MarkdownTitleSuggestionTests: XCTestCase {

    // MARK: - Empty Document

    func testEmptyDocumentReturnsNil() {
        XCTAssertNil(MarkdownTitleSuggestion.suggest(from: ""))
        XCTAssertNil(MarkdownTitleSuggestion.suggest(from: "   "))
        XCTAssertNil(MarkdownTitleSuggestion.suggest(from: "\n\n\t  \n"))
        XCTAssertNil(MarkdownTitleSuggestion.suggest(from: "---\n---"))
        XCTAssertNil(MarkdownTitleSuggestion.suggest(from: "---\ntitle: \n---"))
    }

    // MARK: - H1 First Line

    func testH1FirstLine() {
        XCTAssertEqual(MarkdownTitleSuggestion.suggest(from: "# Trip Plan\nSome body text"), "Trip Plan")
        XCTAssertEqual(MarkdownTitleSuggestion.suggest(from: "#   Trip Plan  \nSome body text"), "Trip Plan")
        XCTAssertEqual(MarkdownTitleSuggestion.suggest(from: "# Trip Plan #\nSome body text"), "Trip Plan")
        XCTAssertEqual(MarkdownTitleSuggestion.suggest(from: "# Trip Plan ###\nSome body text"), "Trip Plan")
        XCTAssertEqual(MarkdownTitleSuggestion.suggest(from: "\n\n# Trip Plan\nSome text"), "Trip Plan")
    }

    // MARK: - Setext Heading

    func testSetextHeading() {
        XCTAssertEqual(MarkdownTitleSuggestion.suggest(from: "Trip Plan\n===\nSome body text"), "Trip Plan")
        XCTAssertEqual(MarkdownTitleSuggestion.suggest(from: "Trip Plan\n========\nSome body text"), "Trip Plan")
        XCTAssertEqual(MarkdownTitleSuggestion.suggest(from: "\n\nTrip Plan\n===\nSome text"), "Trip Plan")
        XCTAssertEqual(MarkdownTitleSuggestion.suggest(from: "Trip Plan  \n  ===\nSome text"), "Trip Plan")
    }

    // MARK: - Front Matter

    func testFrontMatterWithTitle() {
        let doc = """
        ---
        title: Trip Plan
        author: Jack
        ---
        # Other Heading
        Some body text
        """
        XCTAssertEqual(MarkdownTitleSuggestion.suggest(from: doc), "Trip Plan")
    }

    func testFrontMatterWithQuotedTitle() {
        let doc = """
        ---
        title: "Trip Plan: Summer"
        author: Jack
        ---
        Some body text
        """
        XCTAssertEqual(MarkdownTitleSuggestion.suggest(from: doc), "Trip Plan Summer")
    }

    func testFrontMatterWithoutTitlePrefersH1() {
        let doc = """
        ---
        author: Jack
        date: 2026-11-22
        ---
        # Trip Plan
        Some body text
        """
        XCTAssertEqual(MarkdownTitleSuggestion.suggest(from: doc), "Trip Plan")
    }

    func testFrontMatterWithoutTitleUsesFirstPlainLine() {
        let doc = """
        ---
        author: Jack
        ---
        Just a simple note without heading
        Second line
        """
        XCTAssertEqual(MarkdownTitleSuggestion.suggest(from: doc), "Just a simple note without heading")
    }

    // MARK: - Plain First Line

    func testPlainFirstLine() {
        XCTAssertEqual(MarkdownTitleSuggestion.suggest(from: "Just a simple note without headings\nSecond line"), "Just a simple note without headings")
        XCTAssertEqual(MarkdownTitleSuggestion.suggest(from: "  A note with leading whitespace  "), "A note with leading whitespace")
        XCTAssertEqual(MarkdownTitleSuggestion.suggest(from: "- List item first\n- Second item"), "List item first")
        XCTAssertEqual(MarkdownTitleSuggestion.suggest(from: "* Star bullet item"), "Star bullet item")
        XCTAssertEqual(MarkdownTitleSuggestion.suggest(from: "+ Plus bullet item"), "Plus bullet item")
        XCTAssertEqual(MarkdownTitleSuggestion.suggest(from: "1. First step in instructions"), "First step in instructions")
        XCTAssertEqual(MarkdownTitleSuggestion.suggest(from: "1) Alternate ordered item"), "Alternate ordered item")
        XCTAssertEqual(MarkdownTitleSuggestion.suggest(from: "- [ ] Buy groceries"), "Buy groceries")
        XCTAssertEqual(MarkdownTitleSuggestion.suggest(from: "- [x] Finished task"), "Finished task")
        XCTAssertEqual(MarkdownTitleSuggestion.suggest(from: "> A memorable quote"), "A memorable quote")
        XCTAssertEqual(MarkdownTitleSuggestion.suggest(from: ">> Nested blockquote text"), "Nested blockquote text")
        XCTAssertEqual(MarkdownTitleSuggestion.suggest(from: "## Secondary Section Heading\nSome text"), "Secondary Section Heading")
    }

    // MARK: - Emphasis and Links

    func testEmphasisAndLinks() {
        let text1 = "# **Bold** and *Italic* and [Link](https://example.com)"
        XCTAssertEqual(MarkdownTitleSuggestion.suggest(from: text1), "Bold and Italic and Link")

        let text2 = "First line with `code` and ~~strike~~ and [Swash](https://swash.app)"
        XCTAssertEqual(MarkdownTitleSuggestion.suggest(from: text2), "First line with code and strike and Swash")

        let text3 = "![Photo of Cat](cat.jpg) is lovely"
        XCTAssertEqual(MarkdownTitleSuggestion.suggest(from: text3), "Photo of Cat is lovely")

        let text4 = "# Title with [Reference][1] and [Shortcut]\n\n[1]: https://example.com"
        XCTAssertEqual(MarkdownTitleSuggestion.suggest(from: text4), "Title with Reference and Shortcut")

        let text5 = "# Autolink <https://swash.app> and <b>HTML tag</b>"
        XCTAssertEqual(MarkdownTitleSuggestion.suggest(from: text5), "Autolink httpsswash.app and HTML tag")
    }

    // MARK: - Long Lines

    func testLongLinesTrimmedOnWordBoundary() {
        let longHeading = "# This is a very long heading that definitely exceeds the sixty character limit by quite a lot"
        guard let suggestion = MarkdownTitleSuggestion.suggest(from: longHeading) else {
            XCTFail("Expected non-nil suggestion")
            return
        }
        XCTAssertLessThanOrEqual(suggestion.count, 60)
        XCTAssertEqual(suggestion, "This is a very long heading that definitely exceeds the")
    }

    func testLongLineWithoutSpacesTruncatedToSixty() {
        let singleWord = "# " + String(repeating: "A", count: 80)
        guard let suggestion = MarkdownTitleSuggestion.suggest(from: singleWord) else {
            XCTFail("Expected non-nil suggestion")
            return
        }
        XCTAssertEqual(suggestion.count, 60)
        XCTAssertEqual(suggestion, String(repeating: "A", count: 60))
    }

    // MARK: - First H1 in ~20 Lines

    func testFirstH1WithinFirstTwentyLines() {
        let doc = """
        Intro line 1
        Intro line 2
        Intro line 3

        # Trip Plan
        Body text after heading
        """
        XCTAssertEqual(MarkdownTitleSuggestion.suggest(from: doc), "Trip Plan")
    }

    func testSetextHeadingWithinFirstTwentyLines() {
        let doc = """
        Intro line 1
        Intro line 2

        Trip Plan
        =========
        Body text after heading
        """
        XCTAssertEqual(MarkdownTitleSuggestion.suggest(from: doc), "Trip Plan")
    }

    // MARK: - Invalid Characters Removed

    func testInvalidFilenameCharactersRemoved() {
        let doc = "# Trip / Plan : Vacation \\ 2026"
        XCTAssertEqual(MarkdownTitleSuggestion.suggest(from: doc), "Trip Plan Vacation 2026")
    }

    // MARK: - Clean File Name

    func testCleanFileName() {
        XCTAssertEqual(MarkdownTitleSuggestion.cleanFileName("Trip / Plan: Summer\\2026"), "Trip - Plan- Summer-2026")
        XCTAssertEqual(MarkdownTitleSuggestion.cleanFileName("   "), "Untitled")
        XCTAssertEqual(MarkdownTitleSuggestion.cleanFileName("Regular Note"), "Regular Note")
    }

    // MARK: - iPad Title Menu Rename

    func testUntitledDocumentOffersRenameToSuggestion() {
        let documentText = "# Trip Plan\n\nSome notes about the upcoming trip."
        let suggestion = MarkdownTitleSuggestion.suggest(from: documentText)
        XCTAssertEqual(suggestion, "Trip Plan")

        // An untitled document ("Untitled") should offer rename when suggestion differs
        let currentDocumentTitle = "Untitled"
        let canRename = suggestion != nil && !suggestion!.isEmpty && currentDocumentTitle != suggestion!
        XCTAssertTrue(canRename, "Untitled document starting with '# Trip Plan' should offer rename to 'Trip Plan'")

        // If the document is already named "Trip Plan", it should not offer rename to the same title
        let renamedTitle = "Trip Plan"
        let canRenameAgain = suggestion != nil && !suggestion!.isEmpty && renamedTitle != suggestion!
        XCTAssertFalse(canRenameAgain, "Document already named 'Trip Plan' should not offer rename to 'Trip Plan'")
    }
}

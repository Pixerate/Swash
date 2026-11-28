//
//  SizeClassContinuityTests.swift
//  SwashiOSTests
//
//  Opening or closing an iPhone Duo (or rotating a Pro Max, resizing an iPad window) changes the
//  horizontal size class, which swaps the document screen between the outline split view and the
//  bare editor. The editor must come through with the same text view: caret, focus, undo history
//  and, when the keyboard is down, scroll position intact (#65).
//

import SwiftUI
import UIKit
import XCTest
@testable import Swash

@MainActor
final class SizeClassContinuityTests: XCTestCase {
    final class DocumentBox {
        var document: SwashDocument
        init(_ document: SwashDocument) { self.document = document }
        /// Nonisolated: an isolated deinit crashes on the iOS Simulator (GOTCHAS #103).
        nonisolated deinit {}
    }

    private var window: UIWindow?
    private var host: UIHostingController<AnyView>?
    private var box: DocumentBox?

    override func tearDown() async throws {
        window?.isHidden = true
        window?.rootViewController = nil
        window = nil
        host = nil
        box = nil
    }

    private func pump(_ seconds: TimeInterval = 0.3) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
        window?.layoutIfNeeded()
    }

    /// Pumps the run loop until `condition` holds or `timeout` passes.
    private func wait(until condition: () -> Bool, timeout: TimeInterval) {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline { pump(0.1) }
    }

    /// Waits until the editor's styling passes have stopped changing its content height.
    private func settle(_ textView: UIScrollView) {
        let deadline = Date().addingTimeInterval(10)
        var height = textView.contentSize.height
        repeat {
            pump(0.3)
            let current = textView.contentSize.height
            if abs(current - height) < 0.5 { return }
            height = current
        } while Date() < deadline
    }

    /// The document screen at compact width, with a long document.
    private func hostDocument() throws -> (UIHostingController<AnyView>, MarkdownEditingTextView) {
        var text = "# Fold Test\n\n"
        for index in 1...60 { text += "## Section \(index)\n\nParagraph \(index): the quick brown fox.\n\n" }
        let box = DocumentBox(SwashDocument(text: text))
        self.box = box
        let binding = Binding(get: { box.document }, set: { box.document = $0 })
        let host = UIHostingController(rootView: AnyView(NavigationStack { IOSContentView(document: binding, fileURL: nil) }))
        self.host = host
        host.traitOverrides.horizontalSizeClass = .compact

        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        self.window = window
        window.frame = CGRect(x: 0, y: 0, width: 800, height: 800)
        window.rootViewController = host
        window.isHidden = false
        pump(1)
        let editor = try XCTUnwrap(EditorHarness.find(MarkdownEditingTextView.self, in: host.view), "no editor in the document screen")
        return (host, editor)
    }

    private let sizeClasses: [UIUserInterfaceSizeClass] = [.regular, .compact, .regular]

    /// Typing: the same text view keeps the caret, the keyboard and its undo stack, and the caret
    /// stays in view (UIKit scrolls it there when the text reflows).
    func testTypingSurvivesSizeClassChanges() throws {
        let (host, original) = try hostDocument()
        XCTAssertTrue(original.becomeFirstResponder())
        original.selectedRange = NSRange(location: 40, length: 0)
        original.insertText("Typed. ")
        pump()
        let selection = original.selectedRange
        // The hosted test window doesn't always report `canUndo` for typed text, so check that the
        // undo stack itself survives
        let undoManager = original.undoManager
        let couldUndo = undoManager?.canUndo ?? false

        for sizeClass in sizeClasses {
            host.traitOverrides.horizontalSizeClass = sizeClass
            pump(0.6)
            let label = "at size class \(sizeClass.rawValue)"
            let current = try XCTUnwrap(EditorHarness.find(MarkdownEditingTextView.self, in: host.view), "no editor \(label)")
            XCTAssertTrue(current === original, "the editor's text view was rebuilt \(label)")
            XCTAssertEqual(current.selectedRange, selection, "caret moved \(label)")
            // The editor takes the keyboard back asynchronously, which can take longer than the
            // pump on a slow CI runner
            wait(until: { current.isFirstResponder }, timeout: 3)
            XCTAssertTrue(current.isFirstResponder,
                          "focus lost \(label) (in a window: \(current.window != nil), key: \(current.window?.isKeyWindow ?? false))")
            XCTAssertTrue(current.undoManager === undoManager, "undo manager replaced \(label)")
            XCTAssertEqual(current.undoManager?.canUndo ?? false, couldUndo, "undo history lost \(label)")
            if let caret = current.selectedTextRange?.end {
                let caretRect = current.caretRect(for: caret)
                let visible = current.bounds.inset(by: current.adjustedContentInset)
                XCTAssertTrue(visible.intersects(caretRect), "caret scrolled out of view \(label)")
            }
        }
        XCTAssertTrue(box?.document.text.contains("Typed. ") ?? false)
    }

    /// The character at the top of the visible text.
    private func topCharacter(of textView: UITextView) -> Int {
        let top = textView.contentOffset.y + textView.adjustedContentInset.top - textView.textContainerInset.top
        let glyph = textView.layoutManager.glyphIndex(for: CGPoint(x: 0, y: top), in: textView.textContainer)
        return textView.layoutManager.characterIndexForGlyph(at: glyph)
    }

    /// Reading at a new width (an iPhone Duo opening or closing): the same text stays at the top,
    /// not the same pixel offset, which shows other text once the lines rewrap.
    func testReadingPositionFollowsTheTextAcrossWidthChanges() throws {
        let (_, editor) = try hostDocument()
        let window = try XCTUnwrap(window)
        settle(editor)
        editor.setContentOffset(CGPoint(x: 0, y: 600), animated: false)
        settle(editor)
        let anchor = topCharacter(of: editor)
        XCTAssertGreaterThan(anchor, 100, "the document didn't scroll")

        for width in [CGFloat(420), 800, 360] {
            window.frame.size.width = width
            settle(editor)
            assertTopShows(anchor, in: editor, "at width \(width)")
        }
    }

    /// Reading (keyboard down): the same text view keeps the same text at the top. Not the same
    /// pixel offset: moving the view into the new host sets its width to 0 and back, and the
    /// content height it reports (estimated, with non-contiguous layout) differs every time.
    func testReadingPositionSurvivesSizeClassChanges() throws {
        let (host, original) = try hostDocument()
        settle(original)
        original.setContentOffset(CGPoint(x: 0, y: 400), animated: false)
        settle(original)
        let anchor = topCharacter(of: original)
        XCTAssertGreaterThan(anchor, 100, "the document didn't scroll")

        for sizeClass in sizeClasses {
            host.traitOverrides.horizontalSizeClass = sizeClass
            pump(0.6)
            let label = "at size class \(sizeClass.rawValue)"
            let current = try XCTUnwrap(EditorHarness.find(MarkdownEditingTextView.self, in: host.view), "no editor \(label)")
            XCTAssertTrue(current === original, "the editor's text view was rebuilt \(label)")
            XCTAssertFalse(current.isFirstResponder, "the keyboard came up \(label)")
            settle(current)
            assertTopShows(anchor, in: current, label)
        }
    }

    /// The line holding `anchor` is the one at the top of the visible text.
    private func assertTopShows(_ anchor: Int, in textView: UITextView, _ label: String,
                                file: StaticString = #filePath, line sourceLine: UInt = #line) {
        let glyph = textView.layoutManager.glyphIndexForCharacter(at: anchor)
        let line = textView.layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
        let visibleTop = textView.contentOffset.y + textView.adjustedContentInset.top - textView.textContainerInset.top
        XCTAssertEqual(line.minY, visibleTop, accuracy: line.height + 1,
                       "\(label) the top shows character \(topCharacter(of: textView)), not \(anchor)'s line",
                       file: file, line: sourceLine)
    }
}

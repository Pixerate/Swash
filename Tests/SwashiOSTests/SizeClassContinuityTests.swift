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
            XCTAssertTrue(current.isFirstResponder, "focus lost \(label)")
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

    /// Reading (keyboard down): the same text view keeps its scroll position.
    func testReadingPositionSurvivesSizeClassChanges() throws {
        let (host, original) = try hostDocument()
        settle(original)
        original.setContentOffset(CGPoint(x: 0, y: 400), animated: false)
        settle(original)
        let offset = original.contentOffset.y
        XCTAssertGreaterThan(offset, 100, "the document didn't scroll")

        for sizeClass in sizeClasses {
            host.traitOverrides.horizontalSizeClass = sizeClass
            pump(0.6)
            let label = "at size class \(sizeClass.rawValue)"
            let current = try XCTUnwrap(EditorHarness.find(MarkdownEditingTextView.self, in: host.view), "no editor \(label)")
            XCTAssertTrue(current === original, "the editor's text view was rebuilt \(label)")
            XCTAssertFalse(current.isFirstResponder, "the keyboard came up \(label)")
            XCTAssertEqual(current.contentOffset.y, offset, accuracy: 1, "scroll position lost \(label)")
        }
    }
}

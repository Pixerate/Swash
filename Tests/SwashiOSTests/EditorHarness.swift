//
//  EditorHarness.swift
//  SwashiOSTests
//
//  Hosts the real Edit Text editor (`StyledTextView`, a UIViewRepresentable) in a window inside
//  the test host app, the iOS counterpart of Tests/EditorAudit's headless NSTextView harness.
//  Edits go through the text view (insertText, deleteBackward, key commands) so the delegate's
//  structural editing runs, and styling passes are awaited by pumping the main run loop.
//

import SwiftUI
import UIKit
import XCTest
import PixerateMarkdown
@testable import Swash

@MainActor
final class EditorHarness {
    /// The document text, as SwiftUI's binding would see it.
    final class TextBox {
        var text: String
        init(_ text: String) { self.text = text }
    }

    let box: TextBox
    let controller = IOSEditorController()
    let window: UIWindow
    let host: UIHostingController<StyledTextView>
    let textView: StyledUITextView
    var flavor: MarkdownFlavor

    var coordinator: StyledTextView.Coordinator { textView.coordinator! }
    var text: String { box.text }
    var storage: NSTextStorage { textView.textStorage }

    init(_ markdown: String, flavor: MarkdownFlavor = .github, size: CGSize = CGSize(width: 390, height: 800),
         file: StaticString = #filePath, line: UInt = #line) throws {
        box = TextBox(markdown)
        self.flavor = flavor
        let box = box
        let binding = Binding(get: { box.text }, set: { box.text = $0 })
        host = UIHostingController(rootView: StyledTextView(text: binding, controller: controller, flavor: flavor, baseURL: nil))
        // The "/" menu is a bar above the keyboard in compact width, a popover in regular width
        host.traitOverrides.horizontalSizeClass = .compact

        guard let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first else {
            XCTFail("The test host app has no window scene", file: file, line: line)
            throw XCTSkip("no window scene")
        }
        window = UIWindow(windowScene: scene)
        window.frame = CGRect(origin: .zero, size: size)
        window.rootViewController = host
        window.isHidden = false
        window.layoutIfNeeded()

        guard let found = Self.find(StyledUITextView.self, in: host.view) else {
            XCTFail("No StyledUITextView in the hosted view", file: file, line: line)
            throw XCTSkip("editor not hosted")
        }
        textView = found
        // The first styling pass is scheduled for the next run-loop turn, and the first editor in a
        // process can take a while to get there
        let deadline = Date().addingTimeInterval(10)
        while found.coordinator.map({ $0.fullPassCount == 0 }) ?? true, Date() < deadline { pump(0.05) }
        XCTAssertGreaterThan(found.coordinator?.fullPassCount ?? 0, 0, "the editor was never styled", file: file, line: line)
        pump()
    }

    func tearDown() {
        window.isHidden = true
        window.rootViewController = nil
    }

    static func find<T: UIView>(_ type: T.Type, in view: UIView) -> T? {
        if let match = view as? T { return match }
        for subview in view.subviews {
            if let match = find(type, in: subview) { return match }
        }
        return nil
    }

    /// Runs the main run loop so async styling passes and SwiftUI updates land.
    func pump(_ seconds: TimeInterval = 0.15) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
        window.layoutIfNeeded()
    }

    // MARK: Selection (raw-Markdown offsets)

    /// Puts the caret (or a selection) at a raw-Markdown range.
    func select(raw range: NSRange) {
        textView.selectedRange = coordinator.storageRange(forRaw: range, in: textView)
    }

    /// Puts the caret just after the first occurrence of `anchor` in the raw Markdown.
    func caret(after anchor: String, file: StaticString = #filePath, line: UInt = #line) {
        let found = (text as NSString).range(of: anchor)
        XCTAssertNotEqual(found.location, NSNotFound, "anchor \(anchor.debugDescription) not in \(text.debugDescription)", file: file, line: line)
        select(raw: NSRange(location: NSMaxRange(found), length: 0))
    }

    /// Puts the caret just before the first occurrence of `anchor` in the raw Markdown.
    func caret(before anchor: String, file: StaticString = #filePath, line: UInt = #line) {
        let found = (text as NSString).range(of: anchor)
        XCTAssertNotEqual(found.location, NSNotFound, "anchor \(anchor.debugDescription) not in \(text.debugDescription)", file: file, line: line)
        select(raw: NSRange(location: found.location, length: 0))
    }

    var rawSelection: NSRange { textView.markdownSelection }

    // MARK: Typing
    //
    // A programmatic `insertText`/`deleteBackward` doesn't consult the delegate: the keyboard asks
    // `textView(_:shouldChangeTextIn:replacementText:)` first and only then inserts. Do the same, so
    // the editor's structural editing (Return, Backspace, "/") runs as it does for real key presses.

    private func shouldChange(_ range: NSRange, to replacement: String) -> Bool {
        textView.delegate?.textView?(textView, shouldChangeTextIn: range, replacementText: replacement) ?? true
    }

    func type(_ string: String) {
        if shouldChange(textView.selectedRange, to: string) {
            textView.insertText(string)
        }
        pump()
    }

    func pressReturn() { type("\n") }

    func backspace() {
        let selection = textView.selectedRange
        let range = selection.length > 0 ? selection : NSRange(location: max(0, selection.location - 1), length: selection.location > 0 ? 1 : 0)
        if range.length > 0, shouldChange(range, to: "") {
            textView.deleteBackward()
        }
        pump()
    }

    /// Runs the hardware-keyboard command for `input` (Tab, Shift-Tab) as UIKit would.
    func keyCommand(_ input: String, modifiers: UIKeyModifierFlags = [], file: StaticString = #filePath, line: UInt = #line) {
        guard let command = textView.keyCommands?.first(where: { $0.input == input && $0.modifierFlags == modifiers }),
              let action = command.action else {
            XCTFail("no key command for \(input.debugDescription) \(modifiers)", file: file, line: line)
            return
        }
        textView.perform(action, with: command)
        pump()
    }

    // MARK: Styling

    /// A full restyle, as after an external change.
    func forceFullRestyle() {
        coordinator.forceFullRestyle = true
        coordinator.highlight(in: textView)
        pump(0.05)
    }

    /// Every attribute run as text, for comparing two styling passes. Colours are resolved for a
    /// fixed appearance: unnamed dynamic colours are new objects on every call (GOTCHAS #61).
    func fingerprint() -> String {
        let traits = UITraitCollection(userInterfaceStyle: .light)
        func describe(_ color: UIColor?) -> String {
            guard let color else { return "-" }
            var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
            color.resolvedColor(with: traits).getRed(&r, green: &g, blue: &b, alpha: &a)
            return String(format: "%.3f,%.3f,%.3f,%.3f", r, g, b, a)
        }
        var out = ""
        let ns = storage.string as NSString
        storage.enumerateAttributes(in: NSRange(location: 0, length: storage.length), options: []) { attributes, range, _ in
            var parts = [ns.substring(with: range).debugDescription]
            if let font = attributes[.font] as? UIFont { parts.append("\(font.fontName)@\(font.pointSize)") }
            if let color = attributes[.foregroundColor] as? UIColor { parts.append("fg=\(describe(color))") }
            if let color = attributes[.backgroundColor] as? UIColor { parts.append("bg=\(describe(color))") }
            if let p = attributes[.paragraphStyle] as? NSParagraphStyle {
                parts.append("p\(p.headIndent)/\(p.firstLineHeadIndent)/\(p.tailIndent)/\(p.paragraphSpacingBefore)/\(p.paragraphSpacing)/\(p.lineSpacing)")
            }
            if let decorations = attributes[.blockDecorations] as? [BlockDecoration] {
                parts.append("deco[" + decorations.map { "\($0.kind)@\($0.left)-\($0.right)/\($0.padding)/\(describe($0.fill))" }.joined(separator: ",") + "]")
            }
            if let marker = attributes[.listMarker] as? ListMarkerInfo { parts.append("m\(marker.text)@\(marker.indent)") }
            if attributes[.link] != nil { parts.append("link") }
            if attributes[.strikethroughStyle] != nil { parts.append("strike") }
            if let attachment = attributes[.attachment] { parts.append(attachment is TableTextAttachment ? "TABLE" : "IMAGE") }
            if attributes[.codeBadge] != nil { parts.append("badge") }
            out += parts.joined(separator: " ") + "\n"
        }
        return out
    }

    /// Attachments in the storage, in order, with their storage locations.
    func attachments() -> [(location: Int, attachment: NSTextAttachment)] {
        var result: [(Int, NSTextAttachment)] = []
        storage.enumerateAttribute(.attachment, in: NSRange(location: 0, length: storage.length), options: []) { value, range, _ in
            if let attachment = value as? NSTextAttachment { result.append((range.location, attachment)) }
        }
        return result
    }
}

/// The first line on which two fingerprints differ, for failure messages.
func firstDifference(_ a: String, _ b: String) -> String {
    let left = a.split(separator: "\n", omittingEmptySubsequences: false)
    let right = b.split(separator: "\n", omittingEmptySubsequences: false)
    for (index, pair) in zip(left, right).enumerated() where pair.0 != pair.1 {
        return "line \(index): \(pair.0)  vs  \(pair.1)"
    }
    return "lengths \(left.count) vs \(right.count)"
}

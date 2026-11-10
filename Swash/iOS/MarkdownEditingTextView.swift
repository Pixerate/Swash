//
//  MarkdownEditingTextView.swift
//  Swash
//
//  Shared by the iOS Source and Edit Text editors: the controller SwiftUI uses to edit through
//  the live text view, and a UITextView with the formatting bar, Tab / Shift-Tab list indentation
//  and Markdown formatting in the edit menu.
//

#if os(iOS)
import SwiftUI
import UIKit
import PixerateMarkdown

/// Lets SwiftUI read the selection and apply edits through whichever editor is on screen, so they
/// go through UIKit's undo manager and keep the selection (the iOS counterpart of
/// `SwashEditorController`, GOTCHAS #10). Selections and edits are in raw-Markdown offsets.
@MainActor
final class IOSEditorController {
    fileprivate(set) weak var textView: MarkdownEditingTextView?
    /// Called by the formatting bar, the edit menu and Tab handling; set by the hosting view.
    var onFormatCommand: ((FormatCommand) -> Void)?

    var isAttached: Bool { textView != nil }

    var selection: NSRange {
        textView?.markdownSelection ?? NSRange(location: 0, length: 0)
    }

    func apply(_ edit: MarkdownEdit, actionName: String) {
        textView?.applyMarkdownEdit(edit, actionName: actionName)
    }

    func attach(_ textView: MarkdownEditingTextView) {
        self.textView = textView
        textView.controller = self
    }

    func focus() {
        textView?.becomeFirstResponder()
    }
}

/// A TextKit 1 UITextView (the same text system as the macOS editor) with Markdown editing aids.
/// Subclasses map selections and edits between the view's storage and the raw Markdown.
class MarkdownEditingTextView: UITextView {
    fileprivate(set) weak var controller: IOSEditorController?
    private var formattingBarEnabled: Bool?
    /// Set while a Markdown edit replaces text, so the delegate doesn't intercept the replacement.
    var isApplyingEdit = false
    /// The document's flavour, for finding links (Slack mrkdwn writes them as `<url|text>`).
    var flavor: MarkdownFlavor = .github

    /// The selection in raw-Markdown offsets.
    var markdownSelection: NSRange { selectedRange }

    /// The document as raw Markdown.
    var markdownText: String { text ?? "" }

    /// Applies a whole-document rewrite as one undoable edit and selects `edit.selection`.
    func applyMarkdownEdit(_ edit: MarkdownEdit, actionName: String) {
        applyMinimalEdit(edit, actionName: actionName)
        delegate?.textViewDidChange?(self)
    }

    /// Replaces only the span that differs with `edit.text`, through `UITextInput` so it is
    /// undoable, then selects `edit.selection`. Offsets are the view's own (storage) offsets.
    func applyMinimalEdit(_ edit: MarkdownEdit, actionName: String) {
        let old = text as NSString? ?? ""
        let new = edit.text as NSString
        var prefix = 0
        let maxPrefix = min(old.length, new.length)
        while prefix < maxPrefix, old.character(at: prefix) == new.character(at: prefix) { prefix += 1 }
        var suffix = 0
        while suffix < old.length - prefix, suffix < new.length - prefix,
              old.character(at: old.length - 1 - suffix) == new.character(at: new.length - 1 - suffix) { suffix += 1 }
        let oldRange = NSRange(location: prefix, length: old.length - prefix - suffix)
        let replacement = new.substring(with: NSRange(location: prefix, length: new.length - prefix - suffix))
        replaceUndoably(oldRange, with: replacement, actionName: actionName)
        let length = (text as NSString? ?? "").length
        let location = min(edit.selection.location, length)
        selectedRange = NSRange(location: location, length: min(edit.selection.length, length - location))
        scrollRangeToVisible(selectedRange)
    }

    /// Replaces a storage range through `UITextInput`, registering one undo step.
    func replaceUndoably(_ range: NSRange, with replacement: String, actionName: String) {
        guard let start = position(from: beginningOfDocument, offset: range.location),
              let end = position(from: start, offset: range.length),
              let textRange = textRange(from: start, to: end) else { return }
        isApplyingEdit = true
        defer { isApplyingEdit = false }
        undoManager?.beginUndoGrouping()
        replace(textRange, withText: replacement)
        undoManager?.setActionName(actionName)
        undoManager?.endUndoGrouping()
    }

    // MARK: Hardware keyboard

    override var keyCommands: [UIKeyCommand]? {
        let indent = UIKeyCommand(input: "\t", modifierFlags: [], action: #selector(indentLine))
        let outdent = UIKeyCommand(input: "\t", modifierFlags: .shift, action: #selector(outdentLine))
        indent.wantsPriorityOverSystemBehavior = true
        outdent.wantsPriorityOverSystemBehavior = true
        return (super.keyCommands ?? []) + [indent, outdent]
    }

    @objc private func indentLine() {
        if let edit = MarkdownEditingCommands.indent(text: markdownText, selection: markdownSelection) {
            applyMarkdownEdit(edit, actionName: "Indent")
        } else {
            insertText("\t")
        }
    }

    @objc private func outdentLine() {
        guard let edit = MarkdownEditingCommands.outdent(text: markdownText, selection: markdownSelection) else { return }
        applyMarkdownEdit(edit, actionName: "Outdent")
    }

    // MARK: Edit menu

    /// The edit menu for delegates' `editMenuForTextIn`: the system actions, Open Link when the
    /// selection is in a link (links aren't followed by tapping while editing, and iOS has no
    /// ⌘-click), and the Format submenu.
    func editMenu(for range: NSRange, suggestedActions: [UIMenuElement]) -> UIMenu? {
        var actions = suggestedActions
        if let url = linkURL(at: markdownSelection) {
            let open = UIAction(title: "Open Link", image: UIImage(systemName: "safari")) { _ in
                UIApplication.shared.open(url)
            }
            actions.insert(UIMenu(options: .displayInline, children: [open]), at: 0)
        }
        if let menu = formattingMenu(for: range, suggestedActions: actions) { return menu }
        return actions.count == suggestedActions.count ? nil : UIMenu(children: actions)
    }

    /// The URL of the link at `selection` (raw-Markdown offsets), if it is one the system can
    /// open: a destination with a scheme, a `www.` autolink or an email address. Relative links
    /// and fragments have nowhere to go from here.
    func linkURL(at selection: NSRange) -> URL? {
        let text = markdownText
        var destination: String?
        if flavor == .slack {
            destination = LinkDetector.findLink(at: selection, in: text, flavor: .slack, includeBareURLs: true)?.url
        } else if let node = MarkdownFormatting(text: text).link(at: selection), case .link(let target, _, _) = node.kind {
            destination = target
        }
        guard var target = destination?.trimmingCharacters(in: .whitespacesAndNewlines), !target.isEmpty else { return nil }
        if !target.contains(":") {
            if target.lowercased().hasPrefix("www.") {
                target = "https://" + target
            } else if target.contains("@"), !target.contains("/") {
                target = "mailto:" + target
            }
        }
        guard let url = MarkdownSyntax.url(target), let scheme = url.scheme, !scheme.isEmpty else { return nil }
        return url
    }

    /// The edit menu with a Format submenu, for delegates' `editMenuForTextIn`.
    func formattingMenu(for range: NSRange, suggestedActions: [UIMenuElement]) -> UIMenu? {
        guard formattingBarEnabled == true, range.length > 0 else { return nil }
        func action(_ title: String, _ symbol: String, _ command: FormatCommand) -> UIAction {
            UIAction(title: title, image: UIImage(systemName: symbol)) { [weak self] _ in self?.controller?.onFormatCommand?(command) }
        }
        let format = UIMenu(title: "Format", image: UIImage(systemName: "textformat"), children: [
            action("Bold", "bold", .bold),
            action("Italic", "italic", .italic),
            action("Strikethrough", "strikethrough", .strikethrough),
            action("Code", "chevron.left.forwardslash.chevron.right", .code),
            action("Link…", "link", .link),
        ])
        return UIMenu(children: suggestedActions + [format])
    }

    // MARK: Formatting bar

    /// Shows the formatting bar above the software keyboard (hidden when Slack mrkdwn is
    /// selected, whose delimiters the AST engine does not write yet).
    func installFormattingBar(enabled: Bool) {
        guard formattingBarEnabled != enabled else { return }
        formattingBarEnabled = enabled
        inputAccessoryView = enabled ? makeFormattingBar() : nil
        reloadInputViews()
    }

    /// Puts the formatting bar back after another accessory (the "/" block menu) replaced it.
    func restoreFormattingBar() {
        inputAccessoryView = formattingBarEnabled == true ? makeFormattingBar() : nil
        reloadInputViews()
    }

    private func makeFormattingBar() -> UIView {
        let bar = UIToolbar(frame: CGRect(x: 0, y: 0, width: 320, height: 44))
        bar.autoresizingMask = .flexibleWidth
        func item(_ symbol: String, _ label: String, _ command: FormatCommand) -> UIBarButtonItem {
            let item = UIBarButtonItem(image: UIImage(systemName: symbol), primaryAction: UIAction(title: label) { [weak self] _ in
                self?.controller?.onFormatCommand?(command)
            })
            item.accessibilityLabel = label
            return item
        }
        func action(_ title: String, _ symbol: String, _ command: FormatCommand) -> UIAction {
            UIAction(title: title, image: UIImage(systemName: symbol)) { [weak self] _ in
                self?.controller?.onFormatCommand?(command)
            }
        }
        let headings = UIBarButtonItem(image: UIImage(systemName: "textformat.size"), menu: UIMenu(title: "Text Style", children: [
            action("Heading 1", "1.square", .heading(1)),
            action("Heading 2", "2.square", .heading(2)),
            action("Heading 3", "3.square", .heading(3)),
            action("Paragraph", "text.alignleft", .paragraph),
        ]))
        headings.accessibilityLabel = "Text Style"
        let blocks = UIBarButtonItem(image: UIImage(systemName: "list.bullet"), menu: UIMenu(title: "Blocks", children: [
            action("Bullet List", "list.bullet", .bulletList),
            action("Numbered List", "list.number", .numberedList),
            action("To-do List", "checklist", .taskList),
            action("Quote", "text.quote", .quote),
            action("Code Block", "curlybraces", .codeBlock),
        ]))
        blocks.accessibilityLabel = "Blocks"
        let dismiss = UIBarButtonItem(image: UIImage(systemName: "keyboard.chevron.compact.down"), primaryAction: UIAction(title: "Hide Keyboard") { [weak self] _ in
            self?.resignFirstResponder()
        })
        dismiss.accessibilityLabel = "Hide Keyboard"
        bar.items = [
            headings,
            item("bold", "Bold", .bold),
            item("italic", "Italic", .italic),
            item("strikethrough", "Strikethrough", .strikethrough),
            item("chevron.left.forwardslash.chevron.right", "Code", .code),
            item("link", "Link", .link),
            blocks,
            .flexibleSpace(),
            dismiss,
        ]
        bar.sizeToFit()
        return bar
    }
}
#endif

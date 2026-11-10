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

    /// The edit menu with a Format submenu, for delegates' `editMenuForTextIn`. As in the Mac's
    /// bubble menu, it offers the manifest's `bubble` commands that apply to the selection
    /// (`enabledWhen`), with the manifest's labels, groups and order.
    func formattingMenu(for range: NSRange, suggestedActions: [UIMenuElement]) -> UIMenu? {
        guard formattingBarEnabled == true, range.length > 0 else { return nil }
        let selection = markdownSelection
        let formatting = MarkdownFormatting(text: markdownText)
        let entries = FormatManifest.entries(for: .bubble).filter {
            $0.command.isAvailableOnIOS && formatting.isEnabled($0.command, selection: selection)
        }
        guard !entries.isEmpty else { return nil }
        let sections = FormatManifestLayout.groups(entries).map { group in
            UIMenu(options: .displayInline, children: menuElements(for: group))
        }
        let format = UIMenu(title: "Format", image: UIImage(systemName: "textformat"), children: sections)
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

    private func action(_ entry: FormatMenuEntry) -> UIAction {
        let action = UIAction(title: entry.label, image: UIImage(systemName: entry.command.symbolName)) { [weak self] _ in
            self?.controller?.onFormatCommand?(entry.command)
        }
        if let shortcut = entry.shortcut {
            action.discoverabilityTitle = "\(entry.label) (\(shortcut.displayString))"
        }
        return action
    }

    /// A group's menu items: a command's variants become a submenu named after the command
    /// (Heading › Heading 1–3); other commands are plain actions.
    private func menuElements(for group: [FormatMenuEntry]) -> [UIMenuElement] {
        FormatManifestLayout.commandRuns(group).map { run -> UIMenuElement in
            guard run.count > 1 else { return action(run[0]) }
            let title = run[0].command.definition?.label ?? run[0].label
            return UIMenu(title: title, image: UIImage(systemName: run[0].command.variantsSymbolName), children: run.map(action))
        }
    }

    /// Inline formats are buttons. Every other manifest group is a menu named after the group,
    /// and a command's variants (Heading 1–3) get a menu of their own.
    private func makeFormattingBar() -> UIView {
        let bar = UIToolbar(frame: CGRect(x: 0, y: 0, width: 320, height: 44))
        bar.autoresizingMask = .flexibleWidth
        var items: [UIBarButtonItem] = []
        for group in FormatManifestLayout.groups(FormatManifestLayout.keyboardBarEntries) {
            if group.allSatisfy(\.command.isInlineFormat) {
                for entry in group {
                    let item = UIBarButtonItem(image: UIImage(systemName: entry.command.symbolName), primaryAction: action(entry))
                    item.accessibilityLabel = entry.label
                    items.append(item)
                }
                continue
            }
            let runs = FormatManifestLayout.commandRuns(group)
            for run in runs where run.count > 1 {
                let title = run[0].command.definition?.label ?? run[0].label
                let item = UIBarButtonItem(image: UIImage(systemName: run[0].command.variantsSymbolName),
                                           menu: UIMenu(title: title, children: run.map(action)))
                item.accessibilityLabel = title
                items.append(item)
            }
            let rest = runs.filter { $0.count == 1 }.map { $0[0] }
            if let first = rest.first {
                let item = UIBarButtonItem(image: UIImage(systemName: FormatManifestLayout.symbolName(forGroup: first.group)),
                                           menu: UIMenu(title: first.group, children: rest.map(action)))
                item.accessibilityLabel = first.group
                items.append(item)
            }
        }
        let dismiss = UIBarButtonItem(image: UIImage(systemName: "keyboard.chevron.compact.down"), primaryAction: UIAction(title: "Hide Keyboard") { [weak self] _ in
            self?.resignFirstResponder()
        })
        dismiss.accessibilityLabel = "Hide Keyboard"
        bar.items = items + [.flexibleSpace(), dismiss]
        bar.sizeToFit()
        return bar
    }
}

/// How the iOS surfaces lay out the generated format manifest (`FormatManifest`, from
/// PixerateMarkdown): which commands they offer and how they group them. Labels, order, groups
/// and shortcuts come from the manifest; only the icons are Swash's.
enum FormatManifestLayout {
    /// The formatting bar's commands: the manifest's `keyboardBar` surface, or its Format menu
    /// commands while the manifest places none there.
    static var keyboardBarEntries: [FormatMenuEntry] {
        let bar = FormatManifest.entries(for: .keyboardBar)
        return (bar.isEmpty ? FormatManifest.entries(for: .menu) : bar).filter(\.command.isAvailableOnIOS)
    }

    /// Splits entries into the manifest's groups (consecutive entries with the same group).
    static func groups(_ entries: [FormatMenuEntry]) -> [[FormatMenuEntry]] {
        split(entries) { $0.group == $1.group }
    }

    /// Splits entries into runs from the same manifest command, so a command's variants
    /// (Heading 1–3) stay together.
    static func commandRuns(_ entries: [FormatMenuEntry]) -> [[FormatMenuEntry]] {
        split(entries) { $0.command.manifestInvocation?.id == $1.command.manifestInvocation?.id }
    }

    private static func split(_ entries: [FormatMenuEntry], together: (FormatMenuEntry, FormatMenuEntry) -> Bool) -> [[FormatMenuEntry]] {
        var result: [[FormatMenuEntry]] = []
        for entry in entries {
            if let last = result.last?.last, together(last, entry) {
                result[result.count - 1].append(entry)
            } else {
                result.append([entry])
            }
        }
        return result
    }

    /// The icon for a group's menu on the formatting bar.
    static func symbolName(forGroup group: String) -> String {
        switch group {
        case "Block": return "list.bullet"
        case "Insert": return "plus.circle"
        default: return "ellipsis.circle"
        }
    }
}

extension FormatCommand {
    /// Whether the iOS editors can apply the command. Table conversion, callouts, footnotes and
    /// the table of contents are macOS editor features (`FormatCommandEdits` has no edit for them).
    var isAvailableOnIOS: Bool {
        switch self {
        case .table, .callout, .footnote, .tableOfContents: return false
        default: return true
        }
    }

    /// Inline formats, which the formatting bar shows as buttons.
    var isInlineFormat: Bool {
        switch self {
        case .bold, .italic, .strikethrough, .code, .link: return true
        default: return false
        }
    }

    /// The command's icon on iOS (the manifest has labels and shortcuts, not icons).
    var symbolName: String {
        switch self {
        case .bold: return "bold"
        case .italic: return "italic"
        case .strikethrough: return "strikethrough"
        case .code: return "chevron.left.forwardslash.chevron.right"
        case .link: return "link"
        case .heading(let level): return (1...6).contains(level) ? "\(level).square" : "textformat.size"
        case .paragraph: return "text.alignleft"
        case .bulletList: return "list.bullet"
        case .numberedList: return "list.number"
        case .taskList: return "checklist"
        case .quote: return "text.quote"
        case .codeBlock: return "curlybraces"
        case .table: return "tablecells"
        case .callout: return "exclamationmark.bubble"
        case .footnote: return "textformat.superscript"
        case .tableOfContents: return "list.bullet.indent"
        }
    }

    /// The icon for a menu of the command's variants (Heading 1–3).
    var variantsSymbolName: String {
        if case .heading = self { return "textformat.size" }
        return symbolName
    }
}
#endif

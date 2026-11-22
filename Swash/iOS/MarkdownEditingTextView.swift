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
import MacAppKitExtras
import PixerateMarkdown

/// Lets SwiftUI read the selection and apply edits through whichever editor is on screen, so they
/// go through UIKit's undo manager and keep the selection (the iOS counterpart of
/// `SwashEditorController`, GOTCHAS #10). Selections and edits are in raw-Markdown offsets.
@MainActor
final class IOSEditorController {
    fileprivate(set) weak var textView: MarkdownEditingTextView?
    /// Called by the formatting bar, the edit menu and Tab handling; set by the hosting view.
    var onFormatCommand: ((FormatCommand) -> Void)?
    /// The document's flavour, so the edit menu checks commands against the right parse (Slack
    /// mrkdwn has its own inline syntax, SlackMarkdown.swift); set by the hosting view.
    var flavor: MarkdownFlavor = .github

    var isAttached: Bool { textView != nil }

    /// Whether the writing partner is paused for this document (#112, #109). Kept here rather than
    /// in the editor's session, so switching between Source and Formatted keeps it.
    private(set) var partnerPaused = false
    /// Called when the partner pauses or resumes itself (the undo reminder's Pause button).
    var onPartnerPauseChange: ((Bool) -> Void)?

    func setPartnerPaused(_ paused: Bool) {
        partnerPaused = paused
        textView?.writingPartner?.setPaused(paused, in: textView?.writingPartnerHost)
    }

    var selection: NSRange {
        textView?.markdownSelection ?? NSRange(location: 0, length: 0)
    }

    func apply(_ edit: MarkdownEdit, actionName: String) {
        textView?.applyMarkdownEdit(edit, actionName: actionName)
    }

    func attach(_ textView: MarkdownEditingTextView) {
        self.textView = textView
        textView.controller = self
        if let partner = textView.writingPartner {
            if partner.isPaused != partnerPaused { partner.setPaused(partnerPaused, in: textView.writingPartnerHost) }
            partner.onPauseChange = { [weak self] paused in
                guard let self, paused != self.partnerPaused else { return }
                self.partnerPaused = paused
                self.onPartnerPauseChange?(paused)
            }
        }
    }

    func focus() {
        textView?.becomeFirstResponder()
    }

    /// Nonisolated: an isolated deinit crashes on the iOS Simulator (GOTCHAS #103).
    nonisolated deinit {}
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
    /// The document's file URL, for resolving relative and `[[wiki]]` note links in its folder.
    var baseURL: URL?
    /// The writing partner and this editor as its host, set by the editor's coordinator (#109).
    weak var writingPartner: WritingPartnerSession?
    weak var writingPartnerHost: IOSWritingPartnerHost?

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
        var commands = (super.keyCommands ?? []) + [indent, outdent]
        if let partner = writingPartner, partner.hasActiveIntroduction || partner.hasActiveUndoReminder
            || partner.hasActiveSuggestion || !partner.suggestions.isEmpty {
            let escape = UIKeyCommand(input: UIKeyCommand.inputEscape, modifierFlags: [], action: #selector(dismissPartner))
            escape.wantsPriorityOverSystemBehavior = true
            commands.append(escape)
        }
        if writingPartner?.hasActiveSuggestion == true {
            let accept = UIKeyCommand(input: "\r", modifierFlags: .alternate, action: #selector(acceptPartnerSuggestion))
            accept.discoverabilityTitle = "Accept Suggestion"
            commands.append(accept)
        }
        return commands
    }

    // MARK: Writing partner

    /// Tab accepts the partner's suggestion at the caret (as on the Mac) before it indents.
    @discardableResult
    func acceptPartnerSuggestionAtCaret() -> Bool {
        guard let partner = writingPartner, let host = writingPartnerHost else { return false }
        if partner.hasActiveSuggestion {
            partner.acceptActiveSuggestion()
            return true
        }
        return partner.acceptSuggestionAtCaret(in: host)
    }

    @objc private func acceptPartnerSuggestion() {
        acceptPartnerSuggestionAtCaret()
    }

    /// Esc: closes the partner's note, or dismisses the suggestion at the caret.
    @objc private func dismissPartner() {
        guard let partner = writingPartner, let host = writingPartnerHost else { return }
        if partner.dismissIntroduction(in: host) { return }
        if partner.dismissUndoReminder(in: host) { return }
        if partner.hasActiveSuggestion {
            partner.dismissActiveSuggestion()
            return
        }
        partner.dismissSuggestion(in: host)
    }

    /// The partner's actions for the edit menu: a suggestion at the caret, the marks to check.
    func writingPartnerMenu() -> UIMenu? {
        guard let partner = writingPartner, let host = writingPartnerHost else { return nil }
        var actions: [UIMenuElement] = []
        let atCaret = partner.suggestionsForCaret(in: host)
        if let suggestion = atCaret.last {
            let isMark = suggestion.markID != nil
            actions.append(UIAction(title: "Use “\(suggestion.edit.replacement)”", image: UIImage(systemName: "checkmark")) { [weak self] _ in
                self?.acceptPartnerSuggestionAtCaret()
            })
            actions.append(UIAction(title: isMark ? "Keep as Written" : "Dismiss Suggestion", image: UIImage(systemName: "xmark")) { [weak partner, weak host] _ in
                guard let partner, let host else { return }
                partner.dismissSuggestion(in: host)
            })
        }
        if !partner.marks.isEmpty, atCaret.isEmpty {
            let count = partner.marks.count
            actions.append(UIAction(title: count == 1 ? "Check 1 Mark" : "Check \(count) Marks", image: UIImage(systemName: "text.badge.checkmark")) { [weak partner, weak host] _ in
                guard let partner, let host else { return }
                partner.reviewMarks(in: host)
            })
        }
        return actions.isEmpty ? nil : UIMenu(title: "Writing Partner", options: .displayInline, children: actions)
    }

    @objc private func indentLine() {
        if acceptPartnerSuggestionAtCaret() { return }
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

    /// The edit menu for delegates' `editMenuForTextIn`: the system actions, Open Note / Open Link
    /// when the selection is in a link (links aren't followed by tapping while editing, and iOS has
    /// no ⌘-click), and the Format submenu.
    func editMenu(for range: NSRange, suggestedActions: [UIMenuElement]) -> UIMenu? {
        var actions = suggestedActions
        if let partner = writingPartnerMenu() {
            actions.insert(partner, at: 0)
        }
        if let note = noteURL(at: markdownSelection) {
            let open = UIAction(title: "Open Note", image: UIImage(systemName: "doc.text")) { _ in
                DocumentOpener.open(note)
            }
            actions.insert(UIMenu(options: .displayInline, children: [open]), at: 0)
        } else if let url = linkURL(at: markdownSelection) {
            let open = UIAction(title: "Open Link", image: UIImage(systemName: "safari")) { _ in
                UIApplication.shared.open(url)
            }
            actions.insert(UIMenu(options: .displayInline, children: [open]), at: 0)
        }
        if let block = MarkdownParser.fencedCodeBlock(containing: markdownSelection, in: markdownText) {
            let current = (block.language ?? "").lowercased()
            let blockLocation = block.fullRange.location
            func action(_ title: String, _ value: String?) -> UIAction {
                UIAction(title: title, state: (value ?? "") == current ? .on : .off) { [weak self] _ in
                    guard let self = self else { return }
                    let text = self.markdownText
                    guard let edit = MarkdownEditingCommands.setCodeLanguage(value, text: text, location: blockLocation) else { return }
                    // The command puts the caret at the block's start; keep the selection instead,
                    // shifted by the fence line's change in length.
                    let selection = self.markdownSelection
                    let delta = (edit.text as NSString).length - (text as NSString).length
                    let kept = selection.location > blockLocation
                        ? NSRange(location: selection.location + delta, length: selection.length) : selection
                    self.applyMarkdownEdit(MarkdownEdit(text: edit.text, selection: kept), actionName: "Code Language")
                }
            }
            var languages = MarkdownEditingCommands.commonLanguages.map { action($0.capitalized, $0) }
            if !current.isEmpty, !MarkdownEditingCommands.commonLanguages.contains(current) {
                languages.insert(action(block.language ?? current, block.language), at: 0)
            }
            let langMenu = UIMenu(title: "Code Language", image: UIImage(systemName: "chevron.left.forwardslash.chevron.right"), children: [
                UIMenu(options: .displayInline, children: [action("Plain Text", nil)]),
                UIMenu(options: .displayInline, children: languages),
            ])
            actions.insert(langMenu, at: 0)
        }
        if let menu = formattingMenu(for: range, suggestedActions: actions) { return menu }
        return actions.count == suggestedActions.count ? nil : UIMenu(children: actions)
    }

    /// The Markdown note in the document's folder that a relative link or `[[wiki]]` link at
    /// `selection` (raw-Markdown offsets) points to, if any.
    func noteURL(at selection: NSRange) -> URL? {
        guard let baseURL = baseURL else { return nil }
        let root = baseURL.deletingLastPathComponent().standardizedFileURL
        _ = FolderAccessManager.shared.ensureAccess(for: root)
        let text = markdownText
        for wiki in NoteLinkResolver.wikiLinks(in: text) {
            if NSLocationInRange(selection.location, wiki.range) || NSIntersectionRange(selection, wiki.range).length > 0 {
                let files = FolderScanner.scan(root).files
                if let resolved = NoteLinkResolver.resolveWiki(wiki.target, from: baseURL, root: root, files: files) {
                    return resolved
                }
            }
        }
        if let node = MarkdownFormatting(text: text).link(at: selection), case .link(let target, _, _) = node.kind {
            return NoteLinkResolver.resolve(target, from: baseURL, root: root)
        }
        return nil
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

    /// The edit menu's formatting, which `editMenu(for:suggestedActions:)` adds. As in the Mac's
    /// bubble menu, it offers the manifest's `bubble` commands that apply to the selection
    /// (`enabledWhen`), with the manifest's labels, groups and order. Inline formats are actions of
    /// the menu itself (a palette), not a submenu, so the system menu scrolls through them and
    /// lists them when it expands, as in Notes (#72); block commands stay in Format.
    func formattingMenu(for range: NSRange, suggestedActions: [UIMenuElement]) -> UIMenu? {
        guard formattingBarEnabled == true, range.length > 0 else { return nil }
        let selection = markdownSelection
        let formatting = MarkdownFormatting(text: markdownText, flavor: controller?.flavor ?? .github)
        let entries = FormatManifest.entries(for: .bubble).filter {
            $0.command.isAvailableOnIOS && formatting.isEnabled($0.command, selection: selection)
        }
        guard !entries.isEmpty else { return nil }
        var formatElements: [UIMenuElement] = []
        let inline = entries.filter(\.command.isInlineFormat)
        if !inline.isEmpty {
            formatElements.append(UIMenu(options: [.displayInline, .displayAsPalette], children: inline.map(action)))
        }
        let blocks = entries.filter { !$0.command.isInlineFormat }
        if !blocks.isEmpty {
            let sections = FormatManifestLayout.groups(blocks).map { group in
                UIMenu(options: .displayInline, children: menuElements(for: group))
            }
            formatElements.append(UIMenu(title: "Format", image: UIImage(systemName: "textformat"), children: sections))
        }
        return UIMenu(children: suggestedActions + formatElements)
    }

    // MARK: Formatting bar

    /// Shows the formatting bar above the software keyboard.
    func installFormattingBar(enabled: Bool) {
        guard formattingBarEnabled != enabled else { return }
        formattingBarEnabled = enabled
        inputAccessoryView = enabled ? makeFormattingBar() : nil
        if !enabled { inputView = nil }
        reloadInputViews()
    }

    /// Whether the format panel is showing in place of the keyboard.
    var isShowingFormatPanel: Bool { inputView is FormatPanelInputView }

    /// Swaps the keyboard for the format panel (Aa), or back, as Notes does.
    func toggleFormatPanel() {
        if isShowingFormatPanel {
            inputView = nil
        } else {
            inputView = FormatPanelInputView(
                entries: FormatManifestLayout.keyboardBarEntries,
                apply: { [weak self] command in self?.controller?.onFormatCommand?(command) },
                close: { [weak self] in self?.toggleFormatPanel() })
        }
        formatPanelButton?.isSelected = isShowingFormatPanel
        if !isFirstResponder { becomeFirstResponder() }
        reloadInputViews()
    }

    /// The keyboard comes back the next time editing starts.
    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned, isShowingFormatPanel {
            inputView = nil
            formatPanelButton?.isSelected = false
        }
        return resigned
    }

    private weak var formatPanelButton: UIButton?

    /// Whether the editor is in Markdown source mode. In Source mode, character buttons appear
    /// first on the keyboard bar (#191).
    open var isSourceMode: Bool {
        get {
            if let custom = objc_getAssociatedObject(self, &isSourceModeKey) as? Bool {
                return custom
            }
            return !(self is StyledUITextView)
        }
        set {
            objc_setAssociatedObject(self, &isSourceModeKey, newValue, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
            if formattingBarEnabled == true {
                restoreFormattingBar()
            }
        }
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

    /// Aa opens the format panel; inline formats are buttons; every other manifest group is a
    /// menu named after the group, and a command's variants (Heading 1–3) get a menu of their own.
    /// The items scroll in a glass capsule (`GlassAccessoryBar`), so none is clipped (#72).
    /// In Source mode, character buttons appear first; in Formatted mode, format commands come first (#191).
    private func makeFormattingBar() -> UIView {
        var items: [UIView] = []
        let panel = GlassAccessoryBar.iconButton(symbol: "textformat", label: "Format",
                                                 action: UIAction(title: "Format") { [weak self] _ in self?.toggleFormatPanel() })
        panel.configurationUpdateHandler = { button in
            var configuration = button.configuration
            configuration?.baseForegroundColor = button.isSelected ? .tintColor : .label
            button.configuration = configuration
        }
        panel.isSelected = isShowingFormatPanel
        formatPanelButton = panel
        items.append(panel)

        var formatButtons: [UIView] = []
        for group in FormatManifestLayout.groups(FormatManifestLayout.keyboardBarEntries) {
            if group.allSatisfy(\.command.isInlineFormat) {
                for entry in group {
                    formatButtons.append(GlassAccessoryBar.iconButton(symbol: entry.command.symbolName,
                                                                      label: entry.label.replacingOccurrences(of: "…", with: ""),
                                                                      action: action(entry)))
                }
                continue
            }
            let runs = FormatManifestLayout.commandRuns(group)
            for run in runs where run.count > 1 {
                let title = run[0].command.definition?.label ?? run[0].label
                formatButtons.append(GlassAccessoryBar.iconButton(symbol: run[0].command.variantsSymbolName, label: title,
                                                                  menu: UIMenu(title: title, children: run.map(action))))
            }
            let rest = runs.filter { $0.count == 1 }.map { $0[0] }
            if let first = rest.first {
                formatButtons.append(GlassAccessoryBar.iconButton(symbol: FormatManifestLayout.symbolName(forGroup: first.group), label: first.group,
                                                                  menu: UIMenu(title: first.group, children: rest.map(action))))
            }
        }

        let characterButtons = makeCharacterButtons()

        if isSourceMode {
            items.append(contentsOf: characterButtons)
            if !formatButtons.isEmpty {
                items.append(GlassAccessoryBar.separatorView())
                items.append(contentsOf: formatButtons)
            }
        } else {
            items.append(contentsOf: formatButtons)
            if !characterButtons.isEmpty {
                items.append(GlassAccessoryBar.separatorView())
                items.append(contentsOf: characterButtons)
            }
        }

        let dismiss = GlassAccessoryBar.trailingButton(symbol: "keyboard.chevron.compact.down", label: "Hide Keyboard",
                                                       action: UIAction(title: "Hide Keyboard") { [weak self] _ in
            _ = self?.resignFirstResponder()
        })
        return GlassAccessoryBar(items: items, trailing: dismiss, groupedInCapsule: true)
    }

    /// Types `string` from the keyboard bar as a keystroke would: the delegate is asked first, so
    /// structural editing, the "/" menu and the writing partner see it, and the change is an undo
    /// step. A plain `insertText` from code does neither, and wipes the undo history (GOTCHAS #68).
    func typeFromBar(_ string: String) {
        let range = selectedRange
        guard delegate?.textView?(self, shouldChangeTextIn: range, replacementText: string) ?? true,
              let textRange = selectedTextRange else { return }
        // Edit Text restyles on the next turn of the run loop, which clears an undo step made
        // outside its own edits: go through the coordinator, which restyles in the same step
        if let styled = self as? StyledUITextView, let coordinator = styled.coordinator {
            coordinator.replaceSelection(with: string, in: styled, actionName: "Typing")
            return
        }
        undoManager?.beginUndoGrouping()
        replace(textRange, withText: string)
        undoManager?.setActionName("Typing")
        undoManager?.endUndoGrouping()
    }

    /// Generates character buttons for the accessory bar (#191).
    func makeCharacterButtons() -> [UIButton] {
        MarkdownCharacterBar.entries.map { entry in
            GlassAccessoryBar.characterButton(
                character: entry.character,
                label: entry.accessibilityLabel,
                action: UIAction(title: entry.character) { [weak self] _ in
                    self?.typeFromBar(entry.character)
                },
                variants: entry.variants,
                onVariant: { [weak self] variant in
                    self?.typeFromBar(variant)
                }
            )
        }
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

private var isSourceModeKey: UInt8 = 0

// MARK: - Markdown character bar

/// An entry in the Markdown character strip on the keyboard bar (#191).
struct MarkdownCharacterEntry: Equatable {
    let character: String
    let accessibilityLabel: String
    let variants: [String]

    init(_ character: String, label: String, variants: [String] = []) {
        self.character = character
        self.accessibilityLabel = label
        self.variants = variants
    }
}

/// The Markdown characters that are awkward to reach on the iOS keyboard (#191).
enum MarkdownCharacterBar {
    static let entries: [MarkdownCharacterEntry] = [
        MarkdownCharacterEntry("#", label: "Number sign", variants: ["##", "###"]),
        MarkdownCharacterEntry("*", label: "Asterisk", variants: ["**"]),
        MarkdownCharacterEntry("_", label: "Underscore", variants: ["__"]),
        MarkdownCharacterEntry("`", label: "Backtick", variants: ["```"]),
        MarkdownCharacterEntry(">", label: "Greater than"),
        MarkdownCharacterEntry("-", label: "Hyphen", variants: ["---"]),
        MarkdownCharacterEntry("[", label: "Left bracket", variants: ["[ ]"]),
        MarkdownCharacterEntry("]", label: "Right bracket"),
        MarkdownCharacterEntry("(", label: "Left parenthesis"),
        MarkdownCharacterEntry(")", label: "Right parenthesis"),
        MarkdownCharacterEntry("|", label: "Vertical bar"),
        MarkdownCharacterEntry("!", label: "Exclamation mark"),
        MarkdownCharacterEntry("~", label: "Tilde", variants: ["~~"]),
    ]
}
#endif

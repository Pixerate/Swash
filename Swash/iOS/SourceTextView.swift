//
//  SourceTextView.swift
//  Swash
//
//  The iOS and iPadOS Markdown source editor: plain monospaced text with Markdown-aware Return,
//  Backspace and Tab, the formatting bar and formatting in the edit menu.
//

#if os(iOS)
import SwiftUI
import MacAppKitExtras
import UIKit
import PixerateMarkdown

struct SourceTextView: UIViewRepresentable {
    @Binding var text: String
    let controller: IOSEditorController
    var scrollSync: ScrollSync?
    var formattingEnabled: Bool = true
    /// Space under the navigation bar and banner (see `UIScrollView.setTopBarInset`).
    var topInset: CGFloat = 0
    var flavor: MarkdownFlavor = .github
    var baseURL: URL? = nil
    /// Settings › Text Size (before Dynamic Type, which the font applies itself).
    var textSize: CGFloat = EditorTypography.defaultTextSize

    func makeUIView(context: Context) -> EditorHostView<MarkdownEditingTextView> {
        controller.seedInitialText(text)
        if let existing = controller.retainedSourceTextView {
            let host = EditorHostView(textView: existing, controller: controller)
            controller.activeSourceHost = host
            updateUIView(host, context: context)
            controller.restoreScroll(in: existing)
            return host
        }

        let textView = MarkdownEditingTextView(usingTextLayoutManager: false)
        textView.delegate = context.coordinator
        textView.font = Self.font(textSize: textSize)
        context.coordinator.lastTextSize = textSize
        textView.adjustsFontForContentSizeCategory = true
        textView.textColor = .label
        textView.backgroundColor = .systemBackground
        textView.textContainerInset = UIEdgeInsets(top: 16, left: 12, bottom: 16, right: 12)
        textView.alwaysBounceVertical = true
        textView.keyboardDismissMode = .interactive
        // Smart punctuation rewrites Markdown syntax (quotes in code, "--" in tables and rules)
        textView.smartQuotesType = .no
        textView.smartDashesType = .no
        textView.smartInsertDeleteType = .no
        textView.autocapitalizationType = .sentences
        textView.dataDetectorTypes = []
        let targetSelection = Self.clampedSelection(controller.savedSelection, in: text)
        if let initial = controller.initialText, controller.hasUserEdits, initial != text {
            textView.text = initial
            textView.applyMinimalEdit(MarkdownEdit(text: text, selection: targetSelection), actionName: "Typing")
        } else {
            textView.text = text
            textView.selectedRange = targetSelection
        }
        controller.attach(textView)
        textView.flavor = flavor
        textView.baseURL = baseURL
        textView.installFormattingBar(enabled: formattingEnabled)
        scrollSync?.register(textView)
        textView.setTopBarInset(topInset)
        if controller.savedScrollOffsetY > 0 {
            controller.restoreScroll(in: textView)
        }
        context.coordinator.lastBaseURL = baseURL
        context.coordinator.installWritingPartner(in: textView)
        controller.retainedSourceTextView = textView
        let host = EditorHostView(textView: textView, controller: controller)
        controller.activeSourceHost = host
        return host
    }

    func updateUIView(_ host: EditorHostView<MarkdownEditingTextView>, context: Context) {
        let textView = host.textView
        host.adoptTextView()
        context.coordinator.parent = self
        textView.delegate = context.coordinator
        controller.attach(textView)
        scrollSync?.register(textView)
        if context.coordinator.lastBaseURL != nil, context.coordinator.lastBaseURL != baseURL {
            context.coordinator.writingPartner.resetBandleaderSession()
        }
        context.coordinator.lastBaseURL = baseURL
        let targetSelection = Self.clampedSelection(controller.savedSelection, in: text)
        if textView.text != text {
            let offset = textView.contentOffset
            if controller.hasUserEdits {
                textView.applyMinimalEdit(MarkdownEdit(text: text, selection: targetSelection), actionName: "Typing")
            } else {
                textView.text = text
                textView.selectedRange = targetSelection
            }
            textView.contentOffset = offset
            textView.refreshFormattingBarState()
        } else if !textView.isFirstResponder, textView.selectedRange != targetSelection {
            textView.selectedRange = targetSelection
            textView.refreshFormattingBarState()
        }
        textView.flavor = flavor
        textView.baseURL = baseURL
        textView.installFormattingBar(enabled: formattingEnabled)
        textView.setTopBarInset(topInset)
        if context.coordinator.lastTextSize != textSize {
            context.coordinator.lastTextSize = textSize
            textView.font = Self.font(textSize: textSize)
            context.coordinator.refreshPartnerDrawing()
        }
    }

    private static func clampedSelection(_ selection: NSRange, in text: String) -> NSRange {
        let length = (text as NSString).length
        let location = min(max(0, selection.location), length)
        let span = min(max(0, selection.length), length - location)
        return NSRange(location: location, length: span)
    }

    /// Monospaced, 15 pt at the default text size, scaled for Dynamic Type.
    static func font(textSize: CGFloat) -> UIFont {
        let size = (15 * textSize / EditorTypography.defaultTextSize).rounded()
        return UIFontMetrics(forTextStyle: .body).scaledFont(for: .monospacedSystemFont(ofSize: size, weight: .regular))
    }

    /// Fill the space offered: a text view's own fitting size is its whole content height, which
    /// would stop it scrolling.
    func sizeThatFits(_ proposal: ProposedViewSize, uiView: EditorHostView<MarkdownEditingTextView>, context: Context) -> CGSize? {
        guard let width = proposal.width, let height = proposal.height else { return nil }
        return CGSize(width: width, height: height)
    }

    func makeCoordinator() -> Coordinator {
        if let existing = controller.retainedSourceCoordinator {
            existing.parent = self
            return existing
        }
        let coordinator = Coordinator(parent: self)
        controller.retainedSourceCoordinator = coordinator
        return coordinator
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: SourceTextView
        var lastTextSize: CGFloat = EditorTypography.defaultTextSize
        var lastBaseURL: URL?
        /// The writing partner (#109). In Source the text view's text is the raw Markdown.
        let writingPartner = WritingPartnerSession()
        private(set) var partnerHost: IOSWritingPartnerHost?

        init(parent: SourceTextView) {
            self.parent = parent
        }

        /// Nonisolated: an isolated deinit crashes on the iOS Simulator (GOTCHAS #103).
        nonisolated deinit {}

        func refreshPartnerDrawing() {
            guard let host = partnerHost, let overlay = host.existingOverlay else { return }
            if !writingPartner.suggestions.isEmpty { writingPartner.refreshSuggestions(in: host) }
            if !writingPartner.marks.isEmpty { writingPartner.refreshMarks(in: host) }
            overlay.renderPartner()
        }

        func installWritingPartner(in textView: MarkdownEditingTextView) {
            let host = IOSWritingPartnerHost(textView: textView, isStyled: false)
            host.rawText = { [weak textView] in textView?.text ?? "" }
            host.apply = { [weak textView] text, selection, actionName in
                textView?.applyMarkdownEdit(MarkdownEdit(text: text, selection: selection), actionName: actionName)
            }
            host.flavor = { [weak self] in self?.parent.flavor ?? .github }
            partnerHost = host
            textView.writingPartner = writingPartner
            textView.writingPartnerHost = host
        }

        func textViewDidChange(_ textView: UITextView) {
            parent.text = textView.text
            if let textView = textView as? MarkdownEditingTextView {
                parent.controller.noteUserEdit(in: textView)
            }
            if let host = partnerHost, !host.isApplyingPartnerEdit { writingPartner.didChange(in: host) }
            (textView as? MarkdownEditingTextView)?.refreshFormattingBarState()
        }

        func textViewDidChangeSelection(_ textView: UITextView) {
            if let textView = textView as? MarkdownEditingTextView, !textView.isApplyingEdit {
                parent.controller.recordSelection(from: textView)
                if let host = partnerHost {
                    writingPartner.selectionDidChange(in: host)
                }
            }
            (textView as? MarkdownEditingTextView)?.textViewDidChangeSelection()
        }

        func scrollViewDidScroll(_ scrollView: UIScrollView) {
            parent.controller.recordScroll(from: scrollView)
        }

        func textView(_ textView: UITextView, shouldChangeTextIn range: NSRange, replacementText replacement: String) -> Bool {
            if let textView = textView as? MarkdownEditingTextView, !textView.isApplyingEdit, textView.markedTextRange == nil,
               !textView.isWritingToolsActive, let host = partnerHost {
                writingPartner.willType(replacement, inRaw: range, host: host)
            }
            guard parent.formattingEnabled, let textView = textView as? MarkdownEditingTextView,
                  !textView.isApplyingEdit, textView.markedTextRange == nil else { return true }
            let current = textView.text ?? ""
            var edit: MarkdownEdit?
            var actionName = ""
            if replacement == "\n", range.length == 0 {
                edit = MarkdownEditingCommands.newline(text: current, selection: range)
                actionName = "Typing"
            } else if replacement.isEmpty, range.length == 1, textView.selectedRange.length == 0 {
                // Backspace at the start of a list item, heading or quote removes its marker
                edit = MarkdownEditingCommands.backspace(text: current, selection: NSRange(location: range.location + 1, length: 0))
                actionName = "Delete"
            }
            guard let edit = edit else { return true }
            textView.applyMarkdownEdit(edit, actionName: actionName)
            return false
        }

        func textView(_ textView: UITextView, editMenuForTextIn range: NSRange, suggestedActions: [UIMenuElement]) -> UIMenu? {
            (textView as? MarkdownEditingTextView)?.editMenu(for: range, suggestedActions: suggestedActions)
        }
    }
}
#endif

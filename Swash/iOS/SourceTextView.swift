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

    func makeUIView(context: Context) -> MarkdownEditingTextView {
        let textView = MarkdownEditingTextView(usingTextLayoutManager: false)
        textView.delegate = context.coordinator
        textView.text = text
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
        controller.attach(textView)
        textView.flavor = flavor
        textView.baseURL = baseURL
        textView.installFormattingBar(enabled: formattingEnabled)
        scrollSync?.register(textView)
        textView.setTopBarInset(topInset)
        context.coordinator.lastBaseURL = baseURL
        context.coordinator.installWritingPartner(in: textView)
        return textView
    }

    func updateUIView(_ textView: MarkdownEditingTextView, context: Context) {
        context.coordinator.parent = self
        controller.attach(textView)
        if context.coordinator.lastBaseURL != nil, context.coordinator.lastBaseURL != baseURL {
            context.coordinator.writingPartner.resetBandleaderSession()
        }
        context.coordinator.lastBaseURL = baseURL
        if textView.text != text {
            // External change (revert, another window)
            let selection = textView.selectedRange
            textView.text = text
            let length = (text as NSString).length
            textView.selectedRange = NSRange(location: min(selection.location, length), length: 0)
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

    /// Monospaced, 15 pt at the default text size, scaled for Dynamic Type.
    static func font(textSize: CGFloat) -> UIFont {
        let size = (15 * textSize / EditorTypography.defaultTextSize).rounded()
        return UIFontMetrics(forTextStyle: .body).scaledFont(for: .monospacedSystemFont(ofSize: size, weight: .regular))
    }

    /// Fill the space offered: a text view's own fitting size is its whole content height, which
    /// would stop it scrolling.
    func sizeThatFits(_ proposal: ProposedViewSize, uiView: MarkdownEditingTextView, context: Context) -> CGSize? {
        guard let width = proposal.width, let height = proposal.height else { return nil }
        return CGSize(width: width, height: height)
    }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

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
            if let host = partnerHost, !host.isApplyingPartnerEdit { writingPartner.didChange(in: host) }
            (textView as? MarkdownEditingTextView)?.refreshFormattingBarState()
        }

        func textViewDidChangeSelection(_ textView: UITextView) {
            if let textView = textView as? MarkdownEditingTextView, !textView.isApplyingEdit, let host = partnerHost {
                writingPartner.selectionDidChange(in: host)
            }
            (textView as? MarkdownEditingTextView)?.refreshFormattingBarState()
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

//
//  WritingPartnerMacHost.swift
//  Swash
//
//  The Mac editor as a `WritingPartnerHost` (#109): the session works in raw-Markdown offsets, and
//  this maps them to the NSTextView's storage through `SwashTextView.Coordinator`. The overlay is
//  the canvas. The session methods taking a text view and coordinator keep SwashTextView's call
//  sites as they were.
//

#if os(macOS)
import AppKit
import ObjectiveC
import PixerateCore
import PixerateMarkdown

final class MacWritingPartnerHost: WritingPartnerHost {
    weak var textView: NSTextView?
    weak var coordinator: SwashTextView.Coordinator?
    /// The text view's own autocorrect, saved while the partner has it off.
    private var savedAutocorrect: Bool?

    private init(textView: NSTextView, coordinator: SwashTextView.Coordinator) {
        self.textView = textView
        self.coordinator = coordinator
    }

    private static var key: UInt8 = 0

    /// The host for `textView`, kept on the text view so the session sees the same host each time.
    static func host(for textView: NSTextView, coordinator: SwashTextView.Coordinator? = nil) -> MacWritingPartnerHost? {
        if let existing = objc_getAssociatedObject(textView, &key) as? MacWritingPartnerHost {
            if let coordinator, existing.coordinator !== coordinator { existing.coordinator = coordinator }
            if existing.coordinator != nil { return existing }
        }
        guard let coordinator = coordinator ?? (textView.delegate as? SwashTextView.Coordinator) else { return nil }
        let host = MacWritingPartnerHost(textView: textView, coordinator: coordinator)
        objc_setAssociatedObject(textView, &key, host, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        return host
    }

    var partnerRawText: String {
        guard let textView, let coordinator else { return "" }
        return coordinator.rawText(of: textView)
    }

    var partnerRawSelection: NSRange {
        guard let textView, let coordinator else { return NSRange(location: 0, length: 0) }
        return coordinator.rawRange(forStorage: textView.selectedRange(), in: textView)
    }

    func storageRange(forRaw range: NSRange) -> NSRange {
        guard let textView, let coordinator else { return range }
        return coordinator.storageRange(forRaw: range, in: textView)
    }

    func setPartnerRawSelection(_ range: NSRange, scrollToVisible: Bool) {
        guard let textView else { return }
        let storage = storageRange(forRaw: range)
        textView.setSelectedRange(storage)
        if scrollToVisible { textView.scrollRangeToVisible(storage) }
    }

    var partnerFlavor: MarkdownFlavor { coordinator?.parent.flavor ?? .github }
    var partnerIsStyled: Bool { coordinator?.parent.isStyled ?? false }

    func partnerDocument(for text: String) -> MarkdownDocument {
        coordinator?.formatting(for: text).document ?? MarkdownDocument.parse(text, flavor: partnerFlavor)
    }

    var partnerCanEdit: Bool { textView.map { $0.window != nil && $0.isEditable } ?? false }
    var partnerIsOnScreen: Bool { textView?.window != nil }
    var partnerHasMarkedText: Bool { textView?.hasMarkedText() ?? false }
    var partnerUndoManager: UndoManager? { textView?.undoManager }

    func applyPartnerEdit(newRawText: String, rawSelection: NSRange, actionName: String) {
        guard let textView, let coordinator else { return }
        textView.breakUndoCoalescing()
        coordinator.applyEdit(in: textView, newRawText: newRawText, rawSelection: rawSelection, actionName: actionName)
        textView.breakUndoCoalescing()
    }

    func setSystemTextAssistsSuppressed(_ suppressed: Bool) {
        guard let textView else { return }
        let predictions: NSTextInputTraitType = suppressed ? .no : .default
        if textView.inlinePredictionType != predictions { textView.inlinePredictionType = predictions }
        if suppressed, savedAutocorrect == nil {
            savedAutocorrect = textView.isAutomaticSpellingCorrectionEnabled
            textView.isAutomaticSpellingCorrectionEnabled = false
        } else if !suppressed, let saved = savedAutocorrect {
            textView.isAutomaticSpellingCorrectionEnabled = saved
            savedAutocorrect = nil
        }
    }

    func partnerSpellingCorrection(forWordRange range: NSRange, in text: String) -> String? {
        guard let textView else { return nil }
        let checker = NSSpellChecker.shared
        return checker.correction(forWordRange: range, in: text, language: checker.language(),
                                  inSpellDocumentWithTag: textView.spellCheckerDocumentTag)
    }

    func partnerIgnoreSpelling(_ words: [String]) {
        guard let textView, !words.isEmpty else { return }
        let tag = textView.spellCheckerDocumentTag
        for word in words { NSSpellChecker.shared.ignoreWord(word, inSpellDocumentWithTag: tag) }
    }

    func partnerAnnounce(_ text: String) {
        guard let textView else { return }
        NSAccessibility.post(element: textView, notification: .announcementRequested,
                             userInfo: [.announcement: text, .priority: NSAccessibilityPriorityLevel.medium.rawValue])
    }

    var partnerCanvas: (any WritingPartnerCanvas)? {
        textView.map { WritingPartnerOverlay.overlay(for: $0) }
    }

    func partnerRects(forRaw range: NSRange) -> [CGRect] {
        guard let textView else { return [] }
        return WritingPartnerOverlay.rects(for: storageRange(forRaw: range), in: textView)
    }

    func partnerCaretRect(atRaw location: Int) -> CGRect? {
        guard let textView else { return nil }
        let storage = storageRange(forRaw: NSRange(location: location, length: 0))
        return WritingPartnerOverlay.caretRect(at: storage.location, in: textView)
            ?? NSRect(x: textView.textContainerOrigin.x, y: textView.textContainerOrigin.y, width: 2, height: 20)
    }

    var partnerReducesMotion: Bool { WritingPartnerOverlay.reduceMotion }
    var partnerUndoReminderText: String { PartnerUndoReminderView.messageText }
}

extension WritingPartnerOverlay: WritingPartnerCanvas {
    func renderPartner() { render() }

    func showUndoReminder(at rect: CGRect, text: String, onPause: @escaping () -> Void, onDismiss: @escaping () -> Void) {
        showUndoReminder(at: rect, onPause: onPause, onDismiss: onDismiss)
    }
}

/// The Mac editor's calls, in its text view's storage offsets.
extension WritingPartnerSession {
    private func host(_ textView: NSTextView?, _ coordinator: SwashTextView.Coordinator? = nil) -> MacWritingPartnerHost? {
        textView.flatMap { MacWritingPartnerHost.host(for: $0, coordinator: coordinator) }
    }

    func willType(_ string: String?, in range: NSRange, textView: NSTextView, coordinator: SwashTextView.Coordinator) {
        guard let host = host(textView, coordinator) else { return }
        willType(string, inRaw: coordinator.rawRange(forStorage: range, in: textView), host: host)
    }

    func didChange(in textView: NSTextView, coordinator: SwashTextView.Coordinator) {
        if let host = host(textView, coordinator) { didChange(in: host) }
    }

    func selectionDidChange(in textView: NSTextView, coordinator: SwashTextView.Coordinator) {
        if let host = host(textView, coordinator) { selectionDidChange(in: host) }
    }

    func refreshSuggestions(in textView: NSTextView, coordinator: SwashTextView.Coordinator) {
        if let host = host(textView, coordinator) { refreshSuggestions(in: host) }
    }

    func refreshMarks(in textView: NSTextView, coordinator: SwashTextView.Coordinator) {
        if let host = host(textView, coordinator) { refreshMarks(in: host) }
    }

    func chooseIntroductionMode(_ chosenMode: WritingPartnerMode, in textView: NSTextView?, coordinator: SwashTextView.Coordinator?) {
        chooseIntroductionMode(chosenMode, in: host(textView, coordinator))
    }

    @discardableResult
    func dismissIntroduction(in textView: NSTextView?) -> Bool {
        dismissIntroduction(in: host(textView))
    }

    @discardableResult
    func dismissUndoReminder(in textView: NSTextView?) -> Bool {
        dismissUndoReminder(in: host(textView))
    }

    func setPaused(_ paused: Bool, in textView: NSTextView?) {
        setPaused(paused, in: host(textView))
    }

    @discardableResult
    func togglePaused(in textView: NSTextView?) -> Bool {
        togglePaused(in: host(textView))
    }

    func clearSuggestions(in textView: NSTextView?) {
        clearSuggestions(in: host(textView))
    }

    func suggestion(at point: NSPoint, in textView: NSTextView, coordinator: SwashTextView.Coordinator) -> Suggestion? {
        host(textView, coordinator).flatMap { suggestion(at: point, in: $0) }
    }

    func suggestionsForCaret(in textView: NSTextView, coordinator: SwashTextView.Coordinator) -> [Suggestion] {
        host(textView, coordinator).map { suggestionsForCaret(in: $0) } ?? []
    }

    @discardableResult
    func acceptSuggestion(at point: NSPoint, in textView: NSTextView, coordinator: SwashTextView.Coordinator) -> Bool {
        host(textView, coordinator).map { acceptSuggestion(at: point, in: $0) } ?? false
    }

    @discardableResult
    func acceptSuggestionAtCaret(in textView: NSTextView, coordinator: SwashTextView.Coordinator) -> Bool {
        host(textView, coordinator).map { acceptSuggestionAtCaret(in: $0) } ?? false
    }

    @discardableResult
    func acceptSuggestion(in textView: NSTextView, coordinator: SwashTextView.Coordinator) -> Bool {
        host(textView, coordinator).map { acceptSuggestion(in: $0) } ?? false
    }

    @discardableResult
    func dismissSuggestion(in textView: NSTextView, coordinator: SwashTextView.Coordinator) -> Bool {
        host(textView, coordinator).map { dismissSuggestion(in: $0) } ?? false
    }

    @discardableResult
    func reviewMarks(in textView: NSTextView, coordinator: SwashTextView.Coordinator) -> Bool {
        host(textView, coordinator).map { reviewMarks(in: $0) } ?? false
    }

    @discardableResult
    func stepMarks(by offset: Int, in textView: NSTextView, coordinator: SwashTextView.Coordinator) -> Bool {
        host(textView, coordinator).map { stepMarks(by: offset, in: $0) } ?? false
    }

    @discardableResult
    func nextCandidate(in textView: NSTextView, coordinator: SwashTextView.Coordinator) -> Bool {
        host(textView, coordinator).map { nextCandidate(in: $0) } ?? false
    }

    @discardableResult
    func acceptMark(id: Int, candidate: Int, in textView: NSTextView, coordinator: SwashTextView.Coordinator) -> Bool {
        host(textView, coordinator).map { acceptMark(id: id, candidate: candidate, in: $0) } ?? false
    }

    func keep(markID id: Int, alreadyPenalized: Bool = false, in textView: NSTextView, coordinator: SwashTextView.Coordinator) {
        if let host = host(textView, coordinator) { keep(markID: id, alreadyPenalized: alreadyPenalized, in: host) }
    }

    func mark(at point: NSPoint, in textView: NSTextView, coordinator: SwashTextView.Coordinator) -> PartnerUncertainMark? {
        host(textView, coordinator).flatMap { mark(at: point, in: $0) }
    }

    @MainActor
    func triggerPauseCheckForTesting(in textView: NSTextView, coordinator: SwashTextView.Coordinator) {
        if let host = host(textView, coordinator) { triggerPauseCheckForTesting(in: host) }
    }
}
#endif

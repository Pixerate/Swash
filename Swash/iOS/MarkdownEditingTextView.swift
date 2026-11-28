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
    var flavor: MarkdownFlavor = .github {
        didSet {
            WritingPartnerActiveVoice.shared.documentFlavor = flavor
        }
    }

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

    /// The partner's edits this session, on their Copyedit and Ghostwrite layers (#229).
    func partnerLayerEdits() -> [LayeredEdit] {
        guard let partner = textView?.writingPartner, let host = textView?.writingPartnerHost else { return [] }
        return partner.currentLayers(in: host).edits
    }

    /// Reverts the partner's edits `ids` as one undo step, leaving the person's typing alone.
    @discardableResult
    func revertPartnerEdits(_ ids: Set<Int>) -> Int {
        guard let partner = textView?.writingPartner, let host = textView?.writingPartnerHost else { return 0 }
        return partner.revertEdits(ids, in: host)
    }

    var selection: NSRange {
        textView?.markdownSelection ?? NSRange(location: 0, length: 0)
    }

    func apply(_ edit: MarkdownEdit, actionName: String) {
        textView?.applyMarkdownEdit(edit, actionName: actionName)
    }

    func attach(_ textView: MarkdownEditingTextView) {
        let isNewEditor = self.textView !== textView
        self.textView = textView
        textView.controller = self
        if isNewEditor, let find = pendingFind {
            pendingFind = nil
            // Once the editor is in its window: the find bar attaches to it there
            DispatchQueue.main.async { [weak textView] in
                textView?.presentFind(showingReplace: find.showingReplace, query: find.query)
            }
        }
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

    // MARK: Find and replace (#271)

    /// Called when the find bar's search has matches it can't show (inside tables and images in
    /// Formatted) or Replace All skipped some; nil when there's nothing to say. Set by the hosting view.
    var onFindHintChange: ((EditorFindHint?) -> Void)?
    /// A search to start in the next editor that attaches ("Show in Source").
    private var pendingFind: (query: String, showingReplace: Bool)?

    /// Shows the find bar (with Replace when `showingReplace`) in the editor on screen.
    func presentFind(showingReplace: Bool) {
        textView?.presentFind(showingReplace: showingReplace)
    }

    /// Searches for `query` in the editor that attaches next, once it's on screen.
    func presentFindInNextEditor(query: String, showingReplace: Bool) {
        pendingFind = (query, showingReplace)
    }

    /// Editor coordinators (with their text views), one per editor kind, kept for as long as the
    /// document is open. SwiftUI rebuilds an editor whenever its container changes (the outline
    /// split view coming and going with the size class when an iPhone Duo opens or closes); the
    /// rebuilt editor takes the same text view back, with its caret, scroll offset, focus and
    /// undo stack (#65). The controller owns the coordinators, they own the text views, and the
    /// text views refer back weakly, so everything goes with the document.
    private var retainedEditors: [ObjectIdentifier: AnyObject] = [:]

    func retainedEditor<Coordinator: AnyObject>(_ type: Coordinator.Type) -> Coordinator? {
        retainedEditors[ObjectIdentifier(type)] as? Coordinator
    }

    func retainEditor<Coordinator: AnyObject>(_ coordinator: Coordinator) {
        retainedEditors[ObjectIdentifier(Coordinator.self)] = coordinator
    }

    /// Nonisolated: an isolated deinit crashes on the iOS Simulator (GOTCHAS #103).
    nonisolated deinit {}
}

/// Holds an editor's text view across SwiftUI rebuilding the editor (see
/// `IOSEditorController.retainedEditor`).
@MainActor
final class EditorViewRetainer<TextView: MarkdownEditingTextView> {
    private var textView: TextView?
    private var key: AnyHashable?
    /// When the text view was taken down while it had the keyboard.
    private var dismantledWhileFocused: Date?

    func keep(_ textView: TextView, key: AnyHashable?) {
        self.textView = textView
        self.key = key
        dismantledWhileFocused = nil
    }

    /// The kept text view, once it has one.
    var keptTextView: TextView? { textView }

    /// Whether the kept text view still shows `text` under the same `key`, so its editor can be
    /// taken back whole. One that has fallen behind the document (edited in the other editor
    /// meanwhile) isn't: replacing its text would leave undo actions pointing at text that's gone.
    func canReuse(showing text: String, key: AnyHashable?, current: (TextView) -> String) -> Bool {
        guard let textView else { return false }
        return self.key == key && current(textView) == text
    }

    func dismantled(_ textView: TextView) {
        if textView.isFirstResponder { dismantledWhileFocused = Date() }
    }

    /// Gives the keyboard back to a reused text view that had it when its old host went away (or
    /// still has it, if the new host was made first).
    func reattached(_ textView: TextView) {
        let hadFocus = textView.isFirstResponder
            || dismantledWhileFocused.map { Date().timeIntervalSince($0) < 1 } ?? false
        dismantledWhileFocused = nil
        guard hadFocus else { return }
        Self.restoreFocus(of: textView, until: Date().addingTimeInterval(1))
    }

    /// Keeps giving the keyboard back for a moment: the old host can take it away after the new
    /// one is built, and the text view may not be in the new window yet on the first try (a slow
    /// device or CI runner).
    private static func restoreFocus(of textView: TextView, until deadline: Date) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak textView] in
            guard let textView else { return }
            if textView.window != nil, !textView.isFirstResponder { textView.becomeFirstResponder() }
            if Date() < deadline { restoreFocus(of: textView, until: deadline) }
        }
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
    var flavor: MarkdownFlavor = .github {
        didSet {
            guard oldValue != flavor else { return }
            // The Insert button comes and goes with Slack mrkdwn, which has none of its blocks
            if (oldValue == .slack) != (flavor == .slack) { rebuildFormattingBarItems() }
            refreshFormattingBarState()
        }
    }
    /// The document's file URL, for resolving relative and `[[wiki]]` note links in its folder.
    var baseURL: URL?
    /// The writing partner and this editor as its host, set by the editor's coordinator (#109).
    weak var writingPartner: WritingPartnerSession?
    weak var writingPartnerHost: IOSWritingPartnerHost?
    /// Store for the recently used format commands shown in the keyboard bar.
    var recentFormats: RecentFormatCommands = .shared {
        didSet {
            observeRecentFormats()
            rebuildFormattingBarItems()
        }
    }
    private nonisolated(unsafe) var recentsObserver: NSObjectProtocol?

    override init(frame: CGRect, textContainer: NSTextContainer?) {
        super.init(frame: frame, textContainer: textContainer)
        observeRecentFormats()
        installFind()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        observeRecentFormats()
        installFind()
    }

    nonisolated deinit {
        if let recentsObserver {
            NotificationCenter.default.removeObserver(recentsObserver)
        }
        if let storageObserver {
            NotificationCenter.default.removeObserver(storageObserver)
        }
    }

    // MARK: Reading position across width and size-class changes (#65)

    /// The character at the top of the view and how far into its line the view is scrolled, so a
    /// width change (an iPhone Duo opening or closing, a window resizing) keeps the same text at
    /// the top instead of the same pixel offset, which shows other text once the lines rewrap.
    private var readingAnchor: (character: Int, intoLine: CGFloat)?
    /// The width and top inset `readingAnchor` was measured at; scrolls at another geometry
    /// (mid-resize, mid-move between hosts) aren't recorded.
    private var readingAnchorGeometry = ReadingGeometry(width: 0, insetTop: 0)
    private var isRestoringReadingPosition = false
    /// Set when the frame is about to change width, until the next layout at a real width restores
    /// the anchor. SwiftUI moving the view into a new host after a size-class change (an iPhone
    /// Duo opening or closing) sets its width to 0 and back, and UITextView then "restores" its
    /// own scroll position from estimated line heights, which lands on other text; those offsets
    /// mustn't be recorded as the anchor, and the anchor must be restored though the width ends
    /// where it started.
    private var isAwaitingReadingRestore = false

    private struct ReadingGeometry: Equatable {
        var width: CGFloat
        /// `adjustedContentInset.top`: the split view's detail column and the bare document screen
        /// have different bars, and UIKit keeps the pixel offset when the inset changes.
        var insetTop: CGFloat

        func matches(_ other: ReadingGeometry) -> Bool {
            abs(width - other.width) < 0.5 && abs(insetTop - other.insetTop) < 0.5
        }
    }

    private var readingGeometry: ReadingGeometry {
        ReadingGeometry(width: bounds.width, insetTop: adjustedContentInset.top)
    }

    override var contentOffset: CGPoint {
        didSet { recordReadingAnchor() }
    }

    override var frame: CGRect {
        willSet { noteWidthChange(to: newValue.width) }
    }

    override var bounds: CGRect {
        willSet { noteWidthChange(to: newValue.width) }
    }

    private func noteWidthChange(to width: CGFloat) {
        if abs(width - bounds.width) >= 0.5 { isAwaitingReadingRestore = true }
    }

    override func adjustedContentInsetDidChange() {
        super.adjustedContentInsetDidChange()
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        keepReadingPositionAcrossWidthChange()
    }

    /// Restores the reading position once the width or top inset has changed. Called after layout
    /// (subclasses that change insets after `super.layoutSubviews()` get a second pass on the next
    /// run loop).
    func keepReadingPositionAcrossWidthChange() {
        let geometry = readingGeometry
        guard geometry.width > 0, isAwaitingReadingRestore || !geometry.matches(readingAnchorGeometry) else { return }
        let isFirstLayout = readingAnchorGeometry.width == 0
        readingAnchorGeometry = geometry
        isAwaitingReadingRestore = false
        // While typing, UIKit scrolls the caret into view as the text reflows, which is what the
        // person wants to see
        guard !isFirstLayout, let anchor = readingAnchor, !isFirstResponder else {
            recordReadingAnchor()
            return
        }
        isRestoringReadingPosition = true
        scrollToReadingAnchor(anchor)
        // Insets, the readable column and restyling can still move the text this run loop
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if self.readingGeometry.matches(geometry) { self.scrollToReadingAnchor(anchor) }
            self.isRestoringReadingPosition = false
            self.recordReadingAnchor()
        }
    }

    private func recordReadingAnchor() {
        guard !isRestoringReadingPosition, !isAwaitingReadingRestore, bounds.width > 0,
              readingGeometry.matches(readingAnchorGeometry) else { return }
        let top = contentOffset.y + adjustedContentInset.top - textContainerInset.top
        guard top > 1, layoutManager.numberOfGlyphs > 0 else {
            // At the top: a width change keeps it at the top
            readingAnchor = nil
            return
        }
        let glyph = layoutManager.glyphIndex(for: CGPoint(x: 0, y: top), in: textContainer)
        let line = layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
        readingAnchor = (layoutManager.characterIndexForGlyph(at: glyph), max(0, top - line.minY))
    }

    private func scrollToReadingAnchor(_ anchor: (character: Int, intoLine: CGFloat)) {
        let length = textStorage.length
        guard length > 0 else { return }
        let glyph = layoutManager.glyphIndexForCharacter(at: min(anchor.character, length - 1))
        layoutManager.ensureLayout(forGlyphRange: NSRange(location: 0, length: glyph + 1))
        let line = layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
        let target = line.minY + min(anchor.intoLine, line.height) + textContainerInset.top - adjustedContentInset.top
        let maxY = max(-adjustedContentInset.top, contentSize.height - bounds.height + adjustedContentInset.bottom)
        let y = min(max(target, -adjustedContentInset.top), maxY)
        if abs(contentOffset.y - y) > 0.5 { contentOffset.y = y }
    }

    private func observeRecentFormats() {
        if let recentsObserver {
            NotificationCenter.default.removeObserver(recentsObserver)
        }
        let defaults = recentFormats.defaults
        recentsObserver = NotificationCenter.default.addObserver(
            forName: RecentFormatCommands.didChangeNotification,
            object: defaults,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.rebuildFormattingBarItems()
            }
        }
    }

    /// The selection in raw-Markdown offsets.
    var markdownSelection: NSRange { selectedRange }

    /// The document as raw Markdown.
    var markdownText: String { text ?? "" }

    /// Applies a whole-document rewrite as one undoable edit and selects `edit.selection`.
    func applyMarkdownEdit(_ edit: MarkdownEdit, actionName: String) {
        applyMinimalEdit(edit, actionName: actionName)
        delegate?.textViewDidChange?(self)
        refreshFormattingBarState()
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

    /// The replacement `replaceUndoably` is making, while it makes it.
    private var applyingReplacement: (range: NSRange, text: String)?

    /// Whether a change the delegate is asked about is allowed: anything, except while Swash makes
    /// its own replacement, when only that replacement is. Once a text field with smart punctuation
    /// has had the keyboard (the find bar's), UIKit follows `replace(_:withText:)` with its own
    /// changes through the delegate, whatever this view's `smartDashesType`: a table's `---` rule
    /// became `—` (GOTCHAS #125).
    func isOwnEditChange(_ range: NSRange, replacement: String) -> Bool {
        guard let applying = applyingReplacement else { return true }
        return applying.range == range && applying.text == replacement
    }

    /// Replaces a storage range through `UITextInput`, registering one undo step.
    func replaceUndoably(_ range: NSRange, with replacement: String, actionName: String) {
        guard let start = position(from: beginningOfDocument, offset: range.location),
              let end = position(from: start, offset: range.length),
              let textRange = textRange(from: start, to: end) else { return }
        isApplyingEdit = true
        applyingReplacement = (range, replacement)
        defer {
            isApplyingEdit = false
            applyingReplacement = nil
        }
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
        return commands + findKeyCommands
    }

    // MARK: Find and replace (#271)

    /// The find bar. Not UITextView's own (`isFindInteractionEnabled`): its `UITextSearching`
    /// methods are declared in a Swift extension, so a subclass can't override them, and replacing
    /// must go through the editor's edit path, skip hidden markers and be one undo step (GOTCHAS #125).
    private(set) var editorFindInteraction: UIFindInteraction?
    /// The find bar's searchable object and session delegate (the interaction holds it weakly).
    private(set) var textSearcher: EditorTextSearcher?
    private nonisolated(unsafe) var storageObserver: NSObjectProtocol?
    private var isFindRefreshScheduled = false

    /// UITextView's find actions (`find(_:)`, the system's Find menu items) present this one.
    override var findInteraction: UIFindInteraction? { editorFindInteraction }

    private func installFind() {
        let searcher = EditorTextSearcher(textView: self)
        let interaction = UIFindInteraction(sessionDelegate: searcher)
        addInteraction(interaction)
        textSearcher = searcher
        editorFindInteraction = interaction
        // Edits while the bar is up move or remove matches: search again once they've landed
        storageObserver = NotificationCenter.default.addObserver(
            forName: NSTextStorage.didProcessEditingNotification, object: textStorage, queue: .main
        ) { [weak self] notification in
            let characters = (notification.object as? NSTextStorage)?.editedMask.contains(.editedCharacters) ?? true
            MainActor.assumeIsolated {
                if characters { self?.scheduleFindRefresh() }
            }
        }
    }

    private func scheduleFindRefresh() {
        guard editorFindInteraction?.activeFindSession != nil, !isFindRefreshScheduled else { return }
        isFindRefreshScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.isFindRefreshScheduled = false
            self.editorFindInteraction?.activeFindSession?.invalidateFoundResults()
        }
    }

    /// ⌘F, ⌥⌘F, ⌘G and ⇧⌘G, as on the Mac. Not ⌘E (Use Selection for Find there): the format
    /// manifest gives it to Inline Code.
    private var findKeyCommands: [UIKeyCommand] {
        guard editorFindInteraction != nil else { return [] }
        let find = UIKeyCommand(title: "Find", action: #selector(showFindNavigator), input: "f", modifierFlags: .command)
        let replace = UIKeyCommand(title: "Find and Replace", action: #selector(showFindAndReplaceNavigator), input: "f", modifierFlags: [.command, .alternate])
        let next = UIKeyCommand(title: "Find Next", action: #selector(findNextMatch), input: "g", modifierFlags: .command)
        let previous = UIKeyCommand(title: "Find Previous", action: #selector(findPreviousMatch), input: "g", modifierFlags: [.command, .shift])
        for command in [find, replace, next, previous] { command.wantsPriorityOverSystemBehavior = true }
        return [find, replace, next, previous]
    }

    @objc private func showFindNavigator() { presentFind(showingReplace: false) }
    @objc private func showFindAndReplaceNavigator() { presentFind(showingReplace: true) }

    @objc private func findNextMatch() {
        guard let interaction = editorFindInteraction else { return }
        guard interaction.activeFindSession != nil else { return presentFind(showingReplace: false) }
        interaction.findNext()
    }

    @objc private func findPreviousMatch() {
        guard let interaction = editorFindInteraction else { return }
        guard interaction.activeFindSession != nil else { return presentFind(showingReplace: false) }
        interaction.findPrevious()
    }

    /// Shows the find bar, searching for `query` if given (otherwise the last search).
    func presentFind(showingReplace: Bool, query: String? = nil) {
        guard let interaction = editorFindInteraction else { return }
        if let query { interaction.searchText = query }
        interaction.presentFindNavigator(showingReplace: showingReplace)
    }

    /// What the find bar can't show for the current search; reported to the controller.
    var findHint: EditorFindHint? {
        didSet {
            if oldValue != findHint { controller?.onFindHintChange?(findHint) }
        }
    }

    /// Storage ranges of `query`, as the find bar's options ask.
    func findMatches(of query: String, options: UITextSearchOptions?) -> [NSRange] {
        EditorFind.matches(of: query, in: textStorage.string as NSString,
                           options: options?.stringCompareOptions ?? [.caseInsensitive],
                           wordMatch: options.map { EditorFindWordMatch($0.wordMatchMethod) } ?? .contains)
    }

    /// Whether a storage range may be replaced: not across a hidden marker or an attachment.
    func canReplaceFoundRange(_ range: NSRange) -> Bool {
        !EditorFind.crossesHiddenMarker(range, in: textStorage)
    }

    /// Replaces storage `ranges` with `replacement` as one undo step, leaving the caret after the
    /// last one, then tells the editor (`didReplaceFoundText`), which updates the binding and, in
    /// Formatted, restyles the blocks touched. Ranges that would cross a hidden marker are left
    /// alone; returns how many were.
    ///
    /// Each match is its own small replacement, not one edit from the first to the last: that span
    /// would expand the tables and images between them into their source, and the restyle that
    /// collapses them again changes the storage under the undo step, so undoing it went out of
    /// bounds (GOTCHAS #125).
    @discardableResult
    func replaceFoundRanges(_ ranges: [NSRange], with replacement: String, actionName: String) -> Int {
        let replaceable = ranges.filter(canReplaceFoundRange).sorted { $0.location < $1.location }
        let skipped = ranges.count - replaceable.count
        guard !replaceable.isEmpty else { return skipped }
        undoManager?.beginUndoGrouping()
        for range in replaceable.reversed() {
            replaceUndoably(range, with: replacement, actionName: actionName)
        }
        undoManager?.setActionName(actionName)
        undoManager?.endUndoGrouping()
        let added = (replacement as NSString).length
        let shift = replaceable.dropLast().reduce(0) { $0 + added - $1.length }
        let caret = min(replaceable[replaceable.count - 1].location + shift + added, textStorage.length)
        selectedRange = NSRange(location: caret, length: 0)
        didReplaceFoundText()
        return skipped
    }

    /// Find's replacements landed in the storage: the document follows them.
    func didReplaceFoundText() {
        delegate?.textViewDidChange?(self)
        refreshFormattingBarState()
    }

    /// The find bar's search ran: note what it can't show (matches inside tables and images).
    func noteSearch(_ query: String, options: UITextSearchOptions) {
        let inAttachments = EditorFind.attachmentMatches(of: query, in: textStorage,
                                                         options: options.stringCompareOptions, wordMatch: EditorFindWordMatch(options.wordMatchMethod))
        var hint = EditorFindHint(query: query, tables: inAttachments.tables, images: inAttachments.images)
        // A Replace All's skipped count stands until the search changes
        if let old = findHint, old.query == query { hint.skipped = old.skipped }
        findHint = hint.isEmpty ? nil : hint
    }

    /// Replace All ran, leaving `skipped` matches that cross hidden formatting.
    func noteReplaceAll(_ query: String, skipped: Int) {
        var hint = findHint ?? EditorFindHint(query: query)
        hint.query = query
        hint.skipped = skipped
        findHint = hint.isEmpty ? nil : hint
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
        let currentFlavor = controller?.flavor ?? flavor
        let formatting = MarkdownFormatting(text: markdownText, flavor: currentFlavor)
        let entries = FormatManifest.entries(for: .bubble).filter {
            $0.command.isAvailableOnIOS && formatting.isEnabled($0.command, selection: selection)
        }
        guard !entries.isEmpty else { return nil }
        let active = FormatManifestLayout.activeFormats(formatting: formatting, text: markdownText, selection: selection, flavor: currentFlavor)
        var formatElements: [UIMenuElement] = []
        let inline = entries.filter(\.command.isInlineFormat)
        if !inline.isEmpty {
            formatElements.append(UIMenu(options: [.displayInline, .displayAsPalette], children: inline.map { action($0, active: active) }))
        }
        let blocks = entries.filter { !$0.command.isInlineFormat }
        if !blocks.isEmpty {
            let sections = FormatManifestLayout.groups(blocks).map { group in
                UIMenu(options: .displayInline, children: menuElements(for: group, active: active))
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

    /// Whether the insert panel is showing in place of the keyboard.
    var isShowingInsertPanel: Bool { inputView is InsertPanelInputView }

    /// Whether the document's flavour has the Insert panel's blocks (Slack mrkdwn has none of them).
    var offersInsertPanel: Bool { flavor != .slack }

    /// Swaps the keyboard for the format panel (Aa), or back, as Notes does.
    func toggleFormatPanel() {
        if isShowingInsertPanel {
            dismissInsertPanel()
        }
        if isShowingFormatPanel {
            inputView = nil
        } else {
            inputView = FormatPanelInputView(
                entries: FormatManifestLayout.formatPanelEntries,
                activeFormats: activeFormats,
                apply: { [weak self] command in self?.invokeFormatCommand(command) },
                close: { [weak self] in self?.toggleFormatPanel() })
        }
        formatPanelButton?.isSelected = isShowingFormatPanel
        insertButton?.isSelected = isShowingInsertPanel
        if !isFirstResponder { becomeFirstResponder() }
        reloadInputViews()
    }

    /// Targeted location for block insertion (e.g. from the empty-line affordance).
    var targetedInsertLocation: Int?

    /// Presents the insert panel targeting the given markdown location (or the current selection location).
    func presentInsertPanel(targeting location: Int? = nil) {
        if isShowingFormatPanel {
            inputView = nil
            formatPanelButton?.isSelected = false
        }

        targetedInsertLocation = location ?? markdownSelection.location

        inputView = InsertPanelInputView(
            onSelect: { [weak self] kind in
                self?.handleInsertBlock(kind)
            },
            close: { [weak self] in
                self?.dismissInsertPanel()
            }
        )
        insertButton?.isSelected = true
        if !isFirstResponder { becomeFirstResponder() }
        reloadInputViews()
    }

    /// Toggles the insert panel, which replaces the keyboard on iPhone and iPad alike.
    func toggleInsertPanel() {
        if isShowingFormatPanel {
            inputView = nil
            formatPanelButton?.isSelected = false
        }

        if isShowingInsertPanel {
            dismissInsertPanel()
        } else {
            presentInsertPanel(targeting: markdownSelection.location)
        }
    }

    /// Closes the insert panel if open.
    func dismissInsertPanel() {
        targetedInsertLocation = nil
        if inputView is InsertPanelInputView {
            inputView = nil
            reloadInputViews()
        }
        insertButton?.isSelected = false
    }

    /// Handles block insertion selection from the Insert panel.
    func handleInsertBlock(_ kind: BlockInsertKind) {
        let location = targetedInsertLocation ?? markdownSelection.location
        dismissInsertPanel()
        let edit = MarkdownEditingCommands.insertBlock(kind, text: markdownText, at: location)
        applyMarkdownEdit(edit, actionName: "Insert \(kind.title)")
    }

    /// The keyboard comes back the next time editing starts.
    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned {
            if isShowingFormatPanel {
                inputView = nil
                formatPanelButton?.isSelected = false
            }
            if isShowingInsertPanel {
                dismissInsertPanel()
            }
        }
        return resigned
    }

    private weak var formatPanelButton: UIButton?
    private weak var insertButton: UIButton?
    private weak var formattingBar: GlassAccessoryBar?
    /// The recent format buttons currently shown in the keyboard bar, in order.
    private(set) var recentFormatButtons: [UIButton] = []
    private var recentBarEntries: [(entry: FormatMenuEntry, button: UIButton)] = []
    private var recentButtonsByCommand: [FormatCommand: UIButton] = [:]
    private var displayedCommandByButton: [ObjectIdentifier: FormatCommand] = [:]
    private var displayedSymbolByButton: [ObjectIdentifier: String] = [:]
    /// The active list type or heading level each list/heading button's long-press menu was
    /// built for (`.some(nil)` when none was active), so the menu is rebuilt only when it changes.
    private var variantMenuStateByButton: [ObjectIdentifier: FormatCommand?] = [:]

    /// The keyboard bar button for a recent command, if it is currently in the bar.
    func recentButton(for command: FormatCommand) -> UIButton? {
        recentButtonsByCommand[command]
    }

    /// The format command currently displayed by `button` in the keyboard bar.
    func displayedCommand(for button: UIButton) -> FormatCommand? {
        displayedCommandByButton[ObjectIdentifier(button)]
    }

    /// The SF Symbol name currently displayed by `button` in the keyboard bar.
    func displayedSymbolName(for button: UIButton) -> String? {
        displayedSymbolByButton[ObjectIdentifier(button)]
    }

    /// The last parse behind `activeFormats`: the bar refreshes on every edit and selection
    /// change, and re-parsing the whole document each time lags on long documents.
    private var cachedFormatting: (text: String, flavor: MarkdownFlavor, formatting: MarkdownFormatting)?

    /// Formats currently active at `markdownSelection`.
    var activeFormats: Set<FormatCommand> {
        let text = markdownText
        let flavor = controller?.flavor ?? flavor
        let formatting: MarkdownFormatting
        if let cached = cachedFormatting, cached.flavor == flavor, cached.text == text {
            formatting = cached.formatting
        } else {
            formatting = MarkdownFormatting(text: text, flavor: flavor)
            cachedFormatting = (text, flavor, formatting)
        }
        return FormatManifestLayout.activeFormats(formatting: formatting, text: text, selection: markdownSelection, flavor: flavor)
    }

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

    /// Records `command` as the most recently used format and forwards it to the controller.
    func invokeFormatCommand(_ command: FormatCommand) {
        recentFormats.record(command)
        controller?.onFormatCommand?(command)
        refreshFormattingBarState()
    }

    private func action(_ entry: FormatMenuEntry, active: Set<FormatCommand> = []) -> UIAction {
        let action = UIAction(
            title: entry.label,
            image: UIImage(systemName: entry.command.symbolName),
            state: active.contains(entry.command) ? .on : .off
        ) { [weak self] _ in
            self?.invokeFormatCommand(entry.command)
        }
        if let shortcut = entry.shortcut {
            action.discoverabilityTitle = "\(entry.label) (\(shortcut.displayString))"
        }
        return action
    }

    /// A group's menu items: a command's variants become a submenu named after the command
    /// (Heading › Heading 1–3); other commands are plain actions.
    private func menuElements(for group: [FormatMenuEntry], active: Set<FormatCommand> = []) -> [UIMenuElement] {
        FormatManifestLayout.commandRuns(group).map { run -> UIMenuElement in
            guard run.count > 1 else { return action(run[0], active: active) }
            let title = run[0].command.definition?.label ?? run[0].label
            return UIMenu(title: title, image: UIImage(systemName: run[0].command.variantsSymbolName), children: run.map { action($0, active: active) })
        }
    }

    /// Long-press menu for a list or heading button on the keyboard bar, with the active item checked.
    private func variantMenu(for command: FormatCommand, active: Set<FormatCommand>) -> UIMenu? {
        if command.isListFormat {
            let entries = FormatManifestLayout.formatPanelEntries.filter(\.command.isListFormat)
            guard !entries.isEmpty else { return nil }
            return UIMenu(title: "List", children: entries.map { action($0, active: active) })
        }
        if command.isHeadingFormat {
            let entries = FormatManifestLayout.formatPanelEntries.filter(\.command.isHeadingFormat)
            guard !entries.isEmpty else { return nil }
            return UIMenu(title: "Heading", children: entries.map { action($0, active: active) })
        }
        return nil
    }

    /// Updates the selected state and active list/heading icon of the recent format buttons and the open format panel.
    func refreshFormattingBarState() {
        guard formattingBarEnabled == true else { return }
        let active = activeFormats
        applyActiveFormatsToBarButtons(active)
        (inputView as? FormatPanelInputView)?.update(activeFormats: active)
    }

    private func applyActiveFormatsToBarButtons(_ active: Set<FormatCommand>) {
        let activeList = [FormatCommand.bulletList, .numberedList, .taskList].first { active.contains($0) }
        let activeHeading = active.first { $0.isHeadingFormat }
        let hasExplicitActiveList = activeList.map { target in recentBarEntries.contains { $0.entry.command == target } } ?? false
        let hasExplicitActiveHeading = activeHeading.map { target in recentBarEntries.contains { $0.entry.command == target } } ?? false

        var adaptedList = false
        var adaptedHeading = false
        recentButtonsByCommand.removeAll(keepingCapacity: true)

        for (entry, button) in recentBarEntries {
            var displayedCommand = entry.command
            if entry.command.isListFormat, !hasExplicitActiveList, !adaptedList, let activeList {
                displayedCommand = activeList
                adaptedList = true
            } else if entry.command.isHeadingFormat, !hasExplicitActiveHeading, !adaptedHeading, let activeHeading {
                displayedCommand = activeHeading
                adaptedHeading = true
            }

            let id = ObjectIdentifier(button)
            displayedCommandByButton[id] = displayedCommand
            recentButtonsByCommand[entry.command] = button
            recentButtonsByCommand[displayedCommand] = button

            let symbol = displayedCommand.symbolName
            let isSelected = active.contains(displayedCommand)
            if displayedSymbolByButton[id] != symbol || button.isSelected != isSelected {
                displayedSymbolByButton[id] = symbol
                button.isSelected = isSelected
                var configuration = button.configuration
                configuration?.image = UIImage(systemName: symbol)
                configuration?.baseForegroundColor = isSelected ? .tintColor : .label
                button.configuration = configuration
            }

            // Rebuild the long-press menu only when the active list type or heading level changes
            if entry.command.isListFormat || entry.command.isHeadingFormat {
                let menuState: FormatCommand? = entry.command.isListFormat ? activeList : activeHeading
                if variantMenuStateByButton[id] != .some(menuState),
                   let menu = variantMenu(for: entry.command, active: active) {
                    button.menu = menu
                    variantMenuStateByButton[id] = .some(menuState)
                }
            }
        }
    }

    /// Rebuilds the formatting bar's items when recents change, without animating while typing.
    func rebuildFormattingBarItems() {
        guard let bar = formattingBar else { return }
        UIView.performWithoutAnimation {
            bar.setItems(makeFormattingBarItems())
            bar.layoutIfNeeded()
        }
    }

    private func makeFormattingBarItems() -> [UIView] {
        var items: [UIView] = []
        let panel = GlassAccessoryBar.iconButton(symbol: "textformat", label: "Format",
                                                 action: UIAction(title: "Format") { [weak self] _ in self?.toggleFormatPanel() })
        panel.isSelected = isShowingFormatPanel
        formatPanelButton = panel
        items.append(panel)

        if offersInsertPanel {
            let insert = GlassAccessoryBar.iconButton(symbol: "plus", label: "Insert",
                                                      action: UIAction(title: "Insert") { [weak self] _ in self?.toggleInsertPanel() })
            insert.isSelected = isShowingInsertPanel
            insertButton = insert
            items.append(insert)
        }

        recentFormatButtons.removeAll()
        recentBarEntries.removeAll()
        recentButtonsByCommand.removeAll()
        displayedCommandByButton.removeAll()
        displayedSymbolByButton.removeAll()
        variantMenuStateByButton.removeAll()
        let active = activeFormats
        var formatButtons: [UIView] = []
        for entry in FormatManifestLayout.keyboardBarEntries(from: recentFormats) {
            let label = entry.label.replacingOccurrences(of: "…", with: "")
            let baseCommand = entry.command
            // Weak: the button owns this action, so a strong capture would leak every bar button
            weak var buttonRef: UIButton?
            let primaryAction = UIAction(title: entry.label) { [weak self] _ in
                guard let self else { return }
                let command = buttonRef.flatMap { self.displayedCommandByButton[ObjectIdentifier($0)] } ?? baseCommand
                self.invokeFormatCommand(command)
            }
            if let shortcut = entry.shortcut {
                primaryAction.discoverabilityTitle = "\(entry.label) (\(shortcut.displayString))"
            }
            let button = GlassAccessoryBar.iconButton(
                symbol: entry.command.symbolName,
                label: label,
                action: primaryAction
            )
            buttonRef = button
            displayedCommandByButton[ObjectIdentifier(button)] = entry.command
            displayedSymbolByButton[ObjectIdentifier(button)] = entry.command.symbolName
            recentFormatButtons.append(button)
            recentBarEntries.append((entry, button))
            recentButtonsByCommand[entry.command] = button
            formatButtons.append(button)
        }
        applyActiveFormatsToBarButtons(active)

        // In Source mode, character buttons come first; in Formatted mode, format commands (#191)
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
        return items
    }

    /// Aa opens the format panel; next to it sit the most recently used format commands as icon
    /// buttons (a command with variants shows the variant used, such as "Heading 2") and the
    /// Markdown character buttons (#191), followed by Hide Keyboard at the trailing edge. The
    /// items scroll in a glass capsule (`GlassAccessoryBar`).
    private func makeFormattingBar() -> UIView {
        let items = makeFormattingBarItems()
        let dismiss = GlassAccessoryBar.trailingButton(symbol: "keyboard.chevron.compact.down", label: "Hide Keyboard",
                                                       action: UIAction(title: "Hide Keyboard") { [weak self] _ in
            _ = self?.resignFirstResponder()
        })
        let bar = GlassAccessoryBar(items: items, trailing: dismiss, groupedInCapsule: true)
        formattingBar = bar
        return bar
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

/// Ordered store of the most recently used `FormatCommand`s on iOS, persisted in `UserDefaults`.
/// Capped at `maxCount` (6) with no duplicates, most recent first, and seeded with sensible
/// defaults so the keyboard bar is never empty on first launch.
struct RecentFormatCommands {
    static let maxCount = 6
    static let defaultsKey = "swash.recentFormatCommands"
    static let didChangeNotification = Notification.Name("SwashRecentFormatCommandsDidChange")

    /// Initial commands shown before the user has applied any formatting.
    static let defaultCommands: [FormatCommand] = [
        .bold, .italic, .link, .bulletList, .heading(1)
    ]

    static let shared = RecentFormatCommands()

    let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// The recent commands, most recent first, capped at `maxCount` with no duplicates.
    var commands: [FormatCommand] {
        let rawValues: [String]?
        if let array = defaults.stringArray(forKey: Self.defaultsKey) {
            rawValues = array
        } else if let string = defaults.string(forKey: Self.defaultsKey) {
            rawValues = string.split(separator: ",").map(String.init)
        } else {
            rawValues = nil
        }
        guard let rawValues else { return Self.defaultCommands }
        var result: [FormatCommand] = []
        for raw in rawValues {
            guard let command = FormatCommand(rawValue: raw), command.isAvailableOnIOS,
                  !result.contains(command) else { continue }
            result.append(command)
            if result.count == Self.maxCount { break }
        }
        return result.isEmpty ? Self.defaultCommands : result
    }

    /// Records `command` at the front of the recent commands list, removing any earlier duplicate
    /// and trimming to `maxCount`.
    func record(_ command: FormatCommand) {
        guard command.isAvailableOnIOS else { return }
        var updated = commands
        updated.removeAll { $0 == command }
        updated.insert(command, at: 0)
        if updated.count > Self.maxCount {
            updated = Array(updated.prefix(Self.maxCount))
        }
        let rawValues = updated.map(\.rawValue)
        guard defaults.stringArray(forKey: Self.defaultsKey) != rawValues else { return }
        defaults.set(rawValues, forKey: Self.defaultsKey)
        NotificationCenter.default.post(name: Self.didChangeNotification, object: defaults)
    }

    /// Clears persisted recents, restoring `defaultCommands`.
    func reset() {
        defaults.removeObject(forKey: Self.defaultsKey)
        NotificationCenter.default.post(name: Self.didChangeNotification, object: defaults)
    }
}

/// How the iOS surfaces lay out the generated format manifest (`FormatManifest`, from
/// PixerateMarkdown): which commands they offer and how they group them. Labels, order, groups
/// and shortcuts come from the manifest; only the icons are Swash's.
enum FormatManifestLayout {
    /// Every format command available on iOS, for the Aa format panel: the manifest's Format menu
    /// commands plus any additional iOS-available manifest commands (such as insert commands), in
    /// manifest order.
    static var formatPanelEntries: [FormatMenuEntry] {
        let menu = FormatManifest.entries(for: .menu).filter(\.command.isAvailableOnIOS)
        let extra = FormatManifest.commands.flatMap { definition -> [FormatMenuEntry] in
            guard !definition.surfaces.contains(.menu) else { return [] }
            var result = definition.variants.compactMap { variant -> FormatMenuEntry? in
                FormatCommand(manifestID: definition.id, params: variant.params).map {
                    FormatMenuEntry(command: $0, label: variant.label, group: definition.group, shortcut: variant.shortcut)
                }
            }
            if let command = FormatCommand(manifestID: definition.id) {
                result.append(FormatMenuEntry(command: command, label: definition.label, group: definition.group, shortcut: definition.shortcut))
            }
            return result
        }.filter { entry in
            entry.command.isAvailableOnIOS && !menu.contains { $0.command == entry.command }
        }
        return menu + extra
    }

    /// The manifest entry for a single `FormatCommand`.
    static func entry(for command: FormatCommand) -> FormatMenuEntry {
        if let existing = formatPanelEntries.first(where: { $0.command == command }) {
            return existing
        }
        return FormatMenuEntry(
            command: command,
            label: command.label ?? "Format",
            group: command.definition?.group ?? "Format",
            shortcut: command.shortcut
        )
    }

    /// The formatting bar's commands from `recents`, in most-recently-used order.
    static func keyboardBarEntries(from recents: RecentFormatCommands = .shared) -> [FormatMenuEntry] {
        recents.commands.map { entry(for: $0) }
    }

    /// The formatting bar's commands from the shared `RecentFormatCommands` store.
    static var keyboardBarEntries: [FormatMenuEntry] {
        keyboardBarEntries(from: .shared)
    }

    /// Formats active at `selection` (raw-Markdown UTF-16 offsets) in `text`.
    static func activeFormats(text: String, selection: NSRange, flavor: MarkdownFlavor = .github) -> Set<FormatCommand> {
        FormatCommandEdits.activeFormats(text: text, selection: selection, flavor: flavor)
    }

    /// `activeFormats` with an existing parse of `text`.
    static func activeFormats(formatting: MarkdownFormatting, text: String, selection: NSRange, flavor: MarkdownFlavor = .github) -> Set<FormatCommand> {
        FormatCommandEdits.activeFormats(formatting: formatting, selection: selection, flavor: flavor)
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

    /// List formats (bulleted, numbered, to-do).
    var isListFormat: Bool {
        switch self {
        case .bulletList, .numberedList, .taskList: return true
        default: return false
        }
    }

    /// Heading formats (levels 1–6).
    var isHeadingFormat: Bool {
        if case .heading = self { return true }
        return false
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

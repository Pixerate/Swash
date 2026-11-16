//
//  WritingPartnerSession.swift
//  Swash
//
//  Connects the writing partner's Punctuate voice (WritingPartner.swift, #61) to the Mac editor.
//  When the person types a space, punctuation or a blank line, the session asks the voice for
//  fixes to what they just finished. The partner's cursor plays each fix out through the editor
//  package's `AgentTextDirector` (#878): it selects the word, types the new one, and the edit lands
//  as its own undo step ("Undo Punctuation"). Undoing a step straight away counts against the rules
//  it applied; typing on keeps it.
//

#if os(macOS)
import AppKit
import Observation
import PixerateCore
import PixerateMarkdown

/// Tracks the most recently active document's flavour so Settings › Writing can show which voice
/// is playing even when the Settings window is key (#105).
@MainActor
@Observable
final class WritingPartnerActiveVoice {
    static let shared = WritingPartnerActiveVoice()

    var documentFlavor: MarkdownFlavor?

    func currentFlavor(default defaultFlavor: MarkdownFlavor) -> MarkdownFlavor {
        documentFlavor ?? defaultFlavor
    }
}

/// The editor as the partner's director sees it: the raw Markdown, with the word the partner is
/// typing shown in place of the word it replaces. The frames of typing are never written into the
/// text view (that would leave the person's own typing with undo ranges that no longer fit, and
/// publish half-typed words): `ghost` holds them and `WritingPartnerOverlay` draws them. Only the
/// commit edits the text, as one undoable `applyEdit`.
@MainActor
final class WritingPartnerTarget: AgentTextTarget {
    weak var textView: NSTextView?
    weak var coordinator: SwashTextView.Coordinator?
    /// What the partner is typing: `range` of the raw text shows as `text`.
    private(set) var ghost: (range: NSRange, text: String)?
    /// Called when `ghost` changes, to redraw it.
    var onGhostChange: (() -> Void)?
    /// Called after a commit: the raw range replaced, its new text, and where the person's caret was.
    var onCommit: ((NSRange, String, Int) -> Void)?
    /// Set when a commit couldn't be made (the person is composing with an input method).
    private(set) var commitSkipped = false

    init(textView: NSTextView, coordinator: SwashTextView.Coordinator) {
        self.textView = textView
        self.coordinator = coordinator
    }

    /// The raw Markdown as it is in the text view.
    var realText: String {
        guard let textView, let coordinator else { return "" }
        return coordinator.rawText(of: textView)
    }

    var agentText: String {
        let real = realText as NSString
        guard let ghost, NSMaxRange(ghost.range) <= real.length else { return real as String }
        return real.replacingCharacters(in: ghost.range, with: ghost.text)
    }

    var agentReadOnlyReason: String? {
        guard let textView, coordinator != nil else { return "The editor was closed." }
        return textView.isEditable ? nil : "The document can't be edited."
    }

    func previewAgentTyping(in range: NSRange, with text: String) {
        let real = realRange(forAgent: range)
        let current = realText as NSString
        guard NSMaxRange(real) <= current.length else { clearGhost(); return }
        ghost = current.substring(with: real) == text ? nil : (real, text)
        onGhostChange?()
    }

    func commitAgentEdit(in range: NSRange, with text: String, actionName: String) {
        let real = realRange(forAgent: range)
        clearGhost()
        commitSkipped = false
        guard let textView, let coordinator, !textView.hasMarkedText() else { commitSkipped = true; return }
        let current = realText as NSString
        guard NSMaxRange(real) <= current.length else { commitSkipped = true; return }
        let selection = coordinator.rawRange(forStorage: textView.selectedRange(), in: textView)
        let length = (text as NSString).length
        let caret: Int
        if selection.location >= NSMaxRange(real) {
            caret = selection.location + length - real.length
        } else if NSMaxRange(selection) > real.location {
            caret = real.location + length
        } else {
            caret = selection.location
        }
        textView.breakUndoCoalescing()
        coordinator.applyEdit(in: textView, newRawText: current.replacingCharacters(in: real, with: text),
                              rawSelection: NSRange(location: caret, length: 0), actionName: actionName)
        textView.breakUndoCoalescing()
        onCommit?(real, text, selection.location)
    }

    func clearGhost() {
        guard ghost != nil else { return }
        ghost = nil
        onGhostChange?()
    }

    /// A raw offset for an offset in `agentText`. One inside the word being typed goes to its start.
    func realPosition(forAgent position: Int) -> Int {
        guard let ghost else { return position }
        let typedEnd = ghost.range.location + (ghost.text as NSString).length
        if position <= ghost.range.location { return position }
        if position >= typedEnd { return position - typedEnd + NSMaxRange(ghost.range) }
        return ghost.range.location
    }

    func realRange(forAgent range: NSRange) -> NSRange {
        let start = realPosition(forAgent: range.location)
        return NSRange(location: start, length: max(0, realPosition(forAgent: NSMaxRange(range)) - start))
    }

    /// The person is about to replace `range` (raw) with `replacement`: moves the word being typed
    /// with it and returns the same change in `agentText`'s offsets. A change to the word itself
    /// takes the ghost away (the director then stops: the text changed where it was typing).
    func personWillEdit(_ range: NSRange, replacement: String) -> NSRange {
        guard let ghost else { return range }
        let typed = (ghost.text as NSString).length
        let shift = typed - ghost.range.length
        if NSMaxRange(range) <= ghost.range.location {
            self.ghost?.range.location += (replacement as NSString).length - range.length
            return range
        }
        if range.location >= NSMaxRange(ghost.range) {
            return NSRange(location: range.location + shift, length: range.length)
        }
        let start = min(range.location, ghost.range.location)
        let end = NSMaxRange(range) > NSMaxRange(ghost.range) ? NSMaxRange(range) + shift : ghost.range.location + typed
        clearGhost()
        return NSRange(location: start, length: end - start)
    }
}

/// Not isolated itself (the swiftc runners compile the editor in Swift 5 mode, where the coordinator
/// isn't on the main actor); everything that touches the director runs on the main actor.
final class WritingPartnerSession {
    /// Who the partner is, for its cursor.
    static let agent = AgentCaretInfo(id: "writing-partner", name: "Writing partner", color: "#AF52DE")

    /// Word boundaries the person typed (raw-Markdown offsets) that haven't been looked at yet. More
    /// than one when they type faster than the run loop turns, or while the partner is busy.
    /// `enterEndedLine` records whether an Enter was at the end of its line when it was pressed:
    /// by the time it's looked at, the person may have typed the next line.
    private var pendingBoundaries: [(location: Int, enterEndedLine: Bool?)] = []
    private var isScheduled = false
    /// The partner's undo steps since the person last typed, oldest first: typing keeps them all,
    /// undo takes back the newest.
    private var applied: [Step] = []
    /// The text view's own autocorrect, saved while the partner has it off.
    private var savedAutocorrect: Bool?
    private weak var textView: NSTextView?
    private weak var coordinator: SwashTextView.Coordinator?
    private var undoObserver: NSObjectProtocol?
    private weak var observedUndoManager: UndoManager?
    private let defaults: UserDefaults

    /// The director playing fixes in `target`, made for the text view it's in.
    private var director: AgentTextDirector?
    private var target: WritingPartnerTarget?
    /// The fix being played, and the task playing it.
    private var fixInFlight: Fix?
    private var player: Task<Void, Never>?

    /// A fix offered in Suggest mode (#103), waiting for the person to accept or dismiss it.
    struct Suggestion: Equatable {
        var edit: PartnerEdit
        /// Raw-Markdown offset just after the boundary that offered this fix.
        var triggerEnd: Int
    }

    /// How far (UTF-16 units) the person can type past a suggestion before ignoring it counts as dismissing it.
    static let suggestionReach = 40

    /// Active suggestions in Suggest mode, in document order.
    private(set) var suggestions: [Suggestion] = []
    /// Most recent VoiceOver announcement for a suggestion.
    private(set) var lastAnnouncement: String?

    // MARK: - Bandleader & Pause Tier (#101, #120)
    private var testingBandleader: (any WritingBandleader)?
    private var activeBandleader: (any WritingBandleader)?
    private var pauseDetector: WritingPauseDetector = WritingPauseDetector()
    private let sessionMemory: BandleaderSessionMemory = BandleaderSessionMemory()
    private var paragraphVoiceSettings: ParagraphVoiceSettings?
    private var pauseTask: Task<Void, Never>?
    private var leadTask: Task<Void, Never>?
    private var pendingFeedbackCount = 0
    private(set) var activeSuggestion: (suggestion: JazzTextSuggestion, paragraph: String, paragraphRange: NSRange)?
    private var lastKnownParagraphRange: NSRange?
    private var lastKnownParagraphText: String?

    private var hasPauseProvider: Bool {
        testingBandleader != nil
            || MainActor.assumeIsolated { WritingBandleaderFactory.overrideBandleader != nil }
            || WritingPartnerDefaults.provider(defaults) != .none
    }

    private struct Step {
        var voice: WritingPartnerVoice
        var rules: [PunctuationRule]
        var spellingWords: [String]
        /// Where the person's caret was (raw) before it, to put it back if it's undone.
        var caretBefore: Int
        var rangeAfter: NSRange? = nil
        var original: String = ""
        var replacement: String = ""
        var bandleaderSuggestionId: String? = nil
        var bandleaderSuggestionKind: JazzTextSuggestionKind? = nil
        var bandleaderCheckId: String? = nil
    }

    /// A fix the partner's cursor is playing, one word at a time.
    private struct Fix {
        /// The edits still to play, in raw offsets as the text is now, left to right.
        var remaining: [PartnerEdit]
        /// The boundaries it was worked out for, to work it out again if the text changed under it.
        var boundaries: [(location: Int, enterEndedLine: Bool?)]
        var isRetry: Bool
        /// Stopped by undo, redo or the partner being turned off: don't work it out again.
        var isCancelled = false
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    deinit {
        if let undoObserver { NotificationCenter.default.removeObserver(undoObserver) }
    }

    /// True while the partner has nothing to do (for tests).
    var isIdle: Bool {
        fixInFlight == nil
            && pendingBoundaries.isEmpty
            && !isScheduled
            && pauseTask == nil
            && leadTask == nil
            && pendingFeedbackCount == 0
    }

    /// Whether an inline structural suggestion prompt is currently active.
    var hasActiveSuggestion: Bool { activeSuggestion != nil }

    /// The active suggestion item, if any.
    var activeSuggestionItem: JazzTextSuggestion? { activeSuggestion?.suggestion }

    /// Accepts the active structural suggestion, applying it as one undo step through the partner's cursor.
    func acceptActiveSuggestion() {
        guard let active = activeSuggestion, let textView, let coordinator else { return }
        let (suggestion, _, paragraphRange) = active
        activeSuggestion = nil
        let overlay = WritingPartnerOverlay.overlay(for: textView)
        overlay.hideSuggestionPrompt()

        let rawStart = paragraphRange.location + suggestion.range.start
        let rawEnd = paragraphRange.location + suggestion.range.end
        let rawLength = max(0, rawEnd - rawStart)
        let rawRange = NSRange(location: rawStart, length: rawLength)
        let rawText = coordinator.rawText(of: textView) as NSString
        guard NSMaxRange(rawRange) <= rawText.length else { return }
        let original = rawText.substring(with: rawRange)

        let edit = PartnerEdit(
            range: rawRange,
            original: original,
            replacement: suggestion.replacement,
            rules: [],
            spellingWords: [],
            actionName: WritingPartnerDefaults.suggestionActionName,
            bandleaderSuggestionId: suggestion.effectiveId,
            bandleaderSuggestionKind: suggestion.kind,
            bandleaderCheckId: suggestion.checkId
        )
        play(Fix(remaining: [edit], boundaries: [], isRetry: false), in: textView, coordinator: coordinator)
    }

    /// Dismisses the active structural suggestion and teaches the bandleader for the session.
    func dismissActiveSuggestion() {
        guard let active = activeSuggestion else { return }
        let (suggestion, paragraph, _) = active
        activeSuggestion = nil
        sessionMemory.dismiss(suggestion: suggestion, in: paragraph)
        let ns = paragraph as NSString
        let range = suggestion.range.nsRange
        let original = (range.location >= 0 && NSMaxRange(range) <= ns.length) ? ns.substring(with: range) : nil
        reportBandleaderFeedback(JazzTextFeedbackItem(
            suggestionId: suggestion.effectiveId,
            kind: suggestion.kind,
            outcome: .dismissed,
            original: original,
            replacement: suggestion.replacement,
            checkId: suggestion.checkId
        ))
        if let textView {
            let overlay = WritingPartnerOverlay.overlay(for: textView)
            overlay.hideSuggestionPrompt()
        }
    }

    /// The person is about to type `string` over `range` (storage offsets). Call only for their own
    /// typing: not for Swash's edits, restyling, SwiftUI updates or Writing Tools.
    func willType(_ string: String?, in range: NSRange, textView: NSTextView, coordinator: SwashTextView.Coordinator) {
        if hasActiveSuggestion {
            let overlay = WritingPartnerOverlay.overlay(for: textView)
            overlay.hideSuggestionPrompt()
            activeSuggestion = nil
        }
        if let undoManager = textView.undoManager, undoManager.isUndoing || undoManager.isRedoing {
            pendingBoundaries = []
            cancelFix()
            clearSuggestions(in: textView)
            return
        }
        let raw = coordinator.rawRange(forStorage: range, in: textView)
        let replacement = string ?? ""
        if fixInFlight != nil { MainActor.assumeIsolated { personWillEdit(raw, replacement: replacement) } }
        if !suggestions.isEmpty {
            let delta = (replacement as NSString).length - raw.length
            suggestions = suggestions.compactMap { suggestion in
                var suggestion = suggestion
                if NSMaxRange(raw) <= suggestion.edit.range.location {
                    suggestion.edit.range.location += delta
                    suggestion.triggerEnd += delta
                    return suggestion
                }
                if raw.location >= NSMaxRange(suggestion.edit.range) {
                    // Typing on after a suggestion keeps it on offer. Finishing the line, or typing
                    // well past it, without accepting it dismisses it and counts against its rules
                    if replacement.contains("\n") || raw.location - suggestion.triggerEnd > Self.suggestionReach {
                        penalize(suggestion.edit, in: textView)
                        return nil
                    }
                    return suggestion
                }
                // Editing the suggested word itself removes the suggestion without penalty
                // and reports an "edited" outcome when it came from the bandleader (#120).
                if let suggestionId = suggestion.edit.bandleaderSuggestionId,
                   let kind = suggestion.edit.bandleaderSuggestionKind {
                    reportBandleaderFeedback(JazzTextFeedbackItem(
                        suggestionId: suggestionId,
                        kind: kind,
                        outcome: .edited,
                        original: suggestion.edit.original,
                        replacement: suggestion.edit.replacement,
                        finalText: replacement,
                        checkId: suggestion.edit.bandleaderCheckId
                    ))
                }
                return nil
            }
            refreshSuggestions(in: textView, coordinator: coordinator)
        }
        if !applied.isEmpty {
            // Typing on after a fix keeps it in the voice that made it; editing over an applied
            // bandleader replacement reports an "edited" outcome (#120).
            for step in applied {
                if let stepRange = step.rangeAfter,
                   let suggestionId = step.bandleaderSuggestionId,
                   let kind = step.bandleaderSuggestionKind,
                   (NSIntersectionRange(raw, stepRange).length > 0 || (raw.length == 0 && raw.location > stepRange.location && raw.location < NSMaxRange(stepRange))) {
                    reportBandleaderFeedback(JazzTextFeedbackItem(
                        suggestionId: suggestionId,
                        kind: kind,
                        outcome: .edited,
                        original: step.original,
                        replacement: step.replacement,
                        finalText: replacement,
                        checkId: step.bandleaderCheckId
                    ))
                    continue
                }
                var stats = WritingPartnerStats.load(defaults, voice: step.voice)
                for rule in step.rules where rule != .spelling { stats.kept(rule) }
                stats.save(defaults, voice: step.voice)
            }
            applied = []
        }
        let mode = WritingPartnerDefaults.mode(defaults)
        let isOn = mode != .off
        if !isOn {
            cancelFix()
            clearSuggestions(in: textView)
        } else if mode != .suggest, !suggestions.isEmpty {
            // In Automatic mode, keep lower-confidence bandleader suggestions that were offered
            // as underlined suggestions (#120) until accepted, edited, or dismissed.
            suggestions.removeAll { $0.edit.bandleaderSuggestionId == nil }
            refreshSuggestions(in: textView, coordinator: coordinator)
        }
        // macOS's inline predictions and autocorrect also write at the caret, and the two together
        // lose or corrupt fixes: while the partner is on it does the autocorrecting itself
        let predictions: NSTextInputTraitType = isOn ? .no : .default
        if textView.inlinePredictionType != predictions { textView.inlinePredictionType = predictions }
        if isOn, savedAutocorrect == nil {
            savedAutocorrect = textView.isAutomaticSpellingCorrectionEnabled
            textView.isAutomaticSpellingCorrectionEnabled = false
        } else if !isOn, let saved = savedAutocorrect {
            textView.isAutomaticSpellingCorrectionEnabled = saved
            savedAutocorrect = nil
        }

        let charCode: unichar = (replacement as NSString).length > 0 ? (replacement as NSString).character(at: 0) : 0
        var enterEndedLine: Bool?
        if charCode == 0x0A {
            let text = coordinator.rawText(of: textView) as NSString
            enterEndedLine = raw.location >= text.length || text.character(at: raw.location) == 0x0A
        }

        // Pause detection: record typing and back off while editing continues
        if isOn, hasPauseProvider {
            let rawText = coordinator.rawText(of: textView)
            if let extracted = BandleaderContextExtractor.extract(from: rawText, caret: raw.location, flavor: coordinator.parent.flavor) {
                lastKnownParagraphRange = extracted.range
                lastKnownParagraphText = extracted.paragraph
                pauseDetector.noteTyping(
                    character: charCode,
                    paragraph: extracted.paragraph,
                    range: extracted.range,
                    caret: raw.location,
                    enterEndedSentence: enterEndedLine ?? false
                )
                schedulePauseCheck(in: textView, coordinator: coordinator)
            }
        }

        guard isOn, let string, (string as NSString).length == 1, range.length == 0,
              textView.selectedRange().length == 0, !textView.hasMarkedText() else {
            // Anything else (a paste, a deletion, macOS's text replacement) moves the text under the
            // pending offsets: move them with it, and drop any it replaced
            pendingBoundaries = Self.move(pendingBoundaries, through: raw, replacement: replacement)
            return
        }
        let c = (string as NSString).character(at: 0)
        guard PunctuateVoice.isWordBoundary(c) || c == 0x0A else { return }
        pendingBoundaries.append((raw.location, enterEndedLine))
    }

    /// The person's change landed. Fixes run on the next turn of the run loop, after the editor has
    /// published and styled the change, and one at a time: while the partner's cursor is playing a
    /// fix, new boundaries wait for it.
    func didChange(in textView: NSTextView, coordinator: SwashTextView.Coordinator) {
        if WritingPartnerDefaults.mode(defaults) != .off && hasPauseProvider {
            let rawText = coordinator.rawText(of: textView)
            let rawSelection = coordinator.rawRange(forStorage: textView.selectedRange(), in: textView)
            if let current = BandleaderContextExtractor.extract(from: rawText, caret: rawSelection.location, flavor: coordinator.parent.flavor) {
                if let lastRange = lastKnownParagraphRange,
                   let lastText = lastKnownParagraphText,
                   lastRange.location != current.range.location,
                   NSIntersectionRange(lastRange, current.range).length == 0 {
                    pauseDetector.noteLeftParagraph(oldParagraph: lastText, oldRange: lastRange)
                    triggerImmediatePause(in: textView, coordinator: coordinator)
                } else {
                    pauseDetector.updatePendingParagraph(current.paragraph, range: current.range, caret: rawSelection.location)
                }
                lastKnownParagraphRange = current.range
                lastKnownParagraphText = current.paragraph
            }
        }
        guard !pendingBoundaries.isEmpty, !isScheduled, fixInFlight == nil else { return }
        isScheduled = true
        DispatchQueue.main.async { [weak self, weak textView, weak coordinator] in
            guard let self else { return }
            self.isScheduled = false
            guard let textView, let coordinator else { self.pendingBoundaries = []; return }
            self.punctuate(in: textView, coordinator: coordinator)
        }
    }

    private func punctuate(in textView: NSTextView, coordinator: SwashTextView.Coordinator, isRetry: Bool = false) {
        let boundaries = pendingBoundaries
        pendingBoundaries = []
        let mode = WritingPartnerDefaults.mode(defaults)
        guard mode != .off, !textView.hasMarkedText(),
              textView.window != nil, textView.isEditable else { return }
        let raw = coordinator.rawText(of: textView)
        let selection = coordinator.rawRange(forStorage: textView.selectedRange(), in: textView)
        guard selection.length == 0 else { return }
        let flavor = coordinator.parent.flavor
        let voice = WritingPartnerVoice(flavor: flavor)
        let stats = WritingPartnerStats.load(defaults, voice: voice)
        let spellingOn = WritingPartnerDefaults.spelling(defaults)
        /// The rule's switch and what the partner has learned; the pause tier may hold rules back per paragraph below.
        let ruleIsOn: (PunctuationRule) -> Bool = { rule in
            if rule == .spelling { return spellingOn }
            return WritingPartnerDefaults.isRuleEnabled(rule, self.defaults) && stats.isActive(rule)
        }
        let checker = NSSpellChecker.shared
        let tag = textView.spellCheckerDocumentTag
        let spellingCorrection: (String, NSRange, String) -> String? = { [weak self] word, range, text in
            if self?.sessionMemory.isKnownWord(word) == true { return nil }
            return checker.correction(forWordRange: range, in: text, language: checker.language(), inSpellDocumentWithTag: tag)
        }
        let overlay = WritingPartnerOverlay.overlay(for: textView)

        // Each boundary in order, on the text as the earlier ones left it
        var working = raw as NSString
        var caret = selection.location
        var shift = 0
        var marks: [PartnerMark] = []
        var checked: [NSRange] = []
        for pending in boundaries.sorted(by: { $0.location < $1.location }) {
            let boundary = pending.location + shift
            guard boundary >= 0, boundary < working.length, boundary < caret else { continue }
            let c = working.character(at: boundary)
            guard PunctuateVoice.isWordBoundary(c) || c == 0x0A else { continue }

            // Voice settings per paragraph: disable punctuation for genre (e.g. poem)
            if let settings = paragraphVoiceSettings,
               boundary >= settings.paragraphRange.location && boundary <= NSMaxRange(settings.paragraphRange),
               settings.isPunctuateDisabled {
                continue
            }

            let text = working as String
            let document = working == raw as NSString ? coordinator.formatting(for: text).document : MarkdownDocument.parse(text, flavor: flavor)
            if shift == 0, let range = PunctuateVoice.checkedRange(text: text, boundary: boundary, document: document) {
                checked.append(range)
            }
            let isActive: (PunctuationRule) -> Bool = { [weak self] rule in
                if let settings = self?.paragraphVoiceSettings,
                   boundary >= settings.paragraphRange.location && boundary <= NSMaxRange(settings.paragraphRange),
                   settings.disabledRules.contains(rule) {
                    return false
                }
                return ruleIsOn(rule)
            }
            let edits = PunctuateVoice.edits(text: text, boundary: boundary, document: document, flavor: flavor,
                                             enterEndedLine: pending.enterEndedLine, isActive: isActive,
                                             spellingCorrection: spellingCorrection)
            for edit in edits.sorted(by: { $0.range.location > $1.range.location }) {
                let spellingWord = edit.rules.contains(.spelling) ? working.substring(with: edit.range) : nil
                working = working.replacingCharacters(in: edit.range, with: edit.replacement) as NSString
                let length = (edit.replacement as NSString).length
                let delta = length - edit.range.length
                marks = marks.map { mark in
                    var mark = mark
                    if mark.range.location >= NSMaxRange(edit.range) { mark.range.location += delta }
                    return mark
                }
                marks.append(PartnerMark(range: NSRange(location: edit.range.location, length: length), rules: edit.rules,
                                         spellingWord: spellingWord))
                if edit.range.location < caret { caret += delta }
                if edit.range.location <= boundary { shift += delta }
            }
        }
        let edits = PunctuateVoice.partnerEdits(from: raw as NSString, to: working, marks: marks)
        guard !edits.isEmpty else {
            // The sweep is for what it looked at and left alone. A word it is about to fix goes
            // straight to the selection: a sweep and then a selection over the same word reads as
            // the same thing drawn twice (#100).
            overlay.sweep(checked.flatMap { WritingPartnerOverlay.rects(for: coordinator.storageRange(forRaw: $0, in: textView), in: textView) })
            return
        }
        if mode == .suggest {
            offer(edits, triggerEnd: selection.location, in: textView, coordinator: coordinator)
        } else {
            play(Fix(remaining: edits, boundaries: boundaries, isRetry: isRetry), in: textView, coordinator: coordinator)
        }
    }

    // MARK: Suggestions (#103)

    private func offer(_ edits: [PartnerEdit], triggerEnd: Int, in textView: NSTextView, coordinator: SwashTextView.Coordinator) {
        self.textView = textView
        self.coordinator = coordinator
        for edit in edits {
            suggestions.removeAll { NSIntersectionRange($0.edit.range, edit.range).length > 0 }
            suggestions.append(Suggestion(edit: edit, triggerEnd: max(NSMaxRange(edit.range), triggerEnd)))
        }
        suggestions.sort { $0.edit.range.location < $1.edit.range.location }
        refreshSuggestions(in: textView, coordinator: coordinator)
        DispatchQueue.main.async { [weak self, weak textView, weak coordinator] in
            guard let self, let textView, let coordinator else { return }
            self.refreshSuggestions(in: textView, coordinator: coordinator)
        }
        let summary = edits.map { "\($0.replacement) for \($0.original)" }.joined(separator: ", ")
        let announcement = "Suggestion: \(summary)"
        lastAnnouncement = announcement
        NSAccessibility.post(
            element: textView,
            notification: .announcementRequested,
            userInfo: [
                .announcement: announcement,
                .priority: NSAccessibilityPriorityLevel.medium.rawValue,
            ]
        )
    }

    /// Redraws active suggestion underlines in `WritingPartnerOverlay`.
    func refreshSuggestions(in textView: NSTextView, coordinator: SwashTextView.Coordinator) {
        let overlay = WritingPartnerOverlay.overlay(for: textView)
        let rects = suggestions.flatMap {
            WritingPartnerOverlay.rects(for: coordinator.storageRange(forRaw: $0.edit.range, in: textView), in: textView)
        }
        overlay.showSuggestions(rects)
    }

    /// Removes all active suggestions without counting them against their rules.
    func clearSuggestions(in textView: NSTextView?) {
        guard !suggestions.isEmpty else { return }
        suggestions = []
        if let textView = textView ?? self.textView {
            WritingPartnerOverlay.overlay(for: textView).showSuggestions([])
        }
    }

    /// The suggestion drawn under `point` (text view coordinates), if any.
    func suggestion(at point: NSPoint, in textView: NSTextView, coordinator: SwashTextView.Coordinator) -> Suggestion? {
        suggestions.first { suggestion in
            let storage = coordinator.storageRange(forRaw: suggestion.edit.range, in: textView)
            return WritingPartnerOverlay.rects(for: storage, in: textView).contains { $0.insetBy(dx: -2, dy: -2).contains(point) }
        }
    }

    /// Suggestions that the current selection or caret is on or just after.
    func suggestionsForCaret(in textView: NSTextView, coordinator: SwashTextView.Coordinator) -> [Suggestion] {
        guard !suggestions.isEmpty else { return [] }
        let selection = coordinator.rawRange(forStorage: textView.selectedRange(), in: textView)
        if selection.length > 0 {
            return suggestions.filter { NSIntersectionRange(selection, $0.edit.range).length > 0 }
        }
        let caret = selection.location
        let onWord = suggestions.filter { caret >= $0.edit.range.location && caret <= NSMaxRange($0.edit.range) + 1 }
        if !onWord.isEmpty { return onWord }
        return suggestions.filter { caret >= $0.edit.range.location && caret <= $0.triggerEnd }
    }

    /// Accepts the suggestion under `point` (pointer click).
    @discardableResult
    func acceptSuggestion(at point: NSPoint, in textView: NSTextView, coordinator: SwashTextView.Coordinator) -> Bool {
        guard let chosen = suggestion(at: point, in: textView, coordinator: coordinator) else { return false }
        return accept([chosen], in: textView, coordinator: coordinator)
    }

    /// Accepts the suggestion(s) at or just before the caret (Tab or ⌥⏎).
    @discardableResult
    func acceptSuggestionAtCaret(in textView: NSTextView, coordinator: SwashTextView.Coordinator) -> Bool {
        let matching = suggestionsForCaret(in: textView, coordinator: coordinator)
        guard !matching.isEmpty else { return false }
        return accept(matching, in: textView, coordinator: coordinator)
    }

    /// Accepts the suggestion at the caret/selection, or the latest active suggestion (Edit menu / VoiceOver).
    @discardableResult
    func acceptSuggestion(in textView: NSTextView, coordinator: SwashTextView.Coordinator) -> Bool {
        let matching = suggestionsForCaret(in: textView, coordinator: coordinator)
        let chosen = matching.isEmpty ? (suggestions.last.map { [$0] } ?? []) : matching
        guard !chosen.isEmpty else { return false }
        return accept(chosen, in: textView, coordinator: coordinator)
    }

    private func accept(_ chosen: [Suggestion], in textView: NSTextView, coordinator: SwashTextView.Coordinator) -> Bool {
        guard !chosen.isEmpty, fixInFlight == nil else { return false }
        suggestions.removeAll { chosen.contains($0) }
        refreshSuggestions(in: textView, coordinator: coordinator)
        play(Fix(remaining: chosen.map(\.edit), boundaries: [], isRetry: false), in: textView, coordinator: coordinator)
        return true
    }

    /// Dismisses the suggestion at the caret (or all active suggestions) and counts it against its rules.
    @discardableResult
    func dismissSuggestion(in textView: NSTextView, coordinator: SwashTextView.Coordinator) -> Bool {
        guard !suggestions.isEmpty else { return false }
        let matching = suggestionsForCaret(in: textView, coordinator: coordinator)
        let toDismiss = matching.isEmpty ? suggestions : matching
        suggestions.removeAll { toDismiss.contains($0) }
        for item in toDismiss { penalize(item.edit, in: textView) }
        refreshSuggestions(in: textView, coordinator: coordinator)
        return true
    }

    // MARK: Playing a fix

    /// The director for `textView`, made on first use and again if the editor changed.
    @MainActor
    private func director(for textView: NSTextView, coordinator: SwashTextView.Coordinator) -> (AgentTextDirector, WritingPartnerTarget) {
        if let director, let target, target.textView === textView, target.coordinator === coordinator { return (director, target) }
        let target = WritingPartnerTarget(textView: textView, coordinator: coordinator)
        let director = AgentTextDirector(target: target, linger: 300)
        let overlay = WritingPartnerOverlay.overlay(for: textView)
        overlay.attach(carets: director.carets, target: target)
        target.onGhostChange = { [weak overlay] in overlay?.render() }
        target.onCommit = { [weak self] range, text, caret in self?.committed(range, text: text, caretBefore: caret) }
        self.director = director
        self.target = target
        return (director, target)
    }

    private func play(_ fix: Fix, in textView: NSTextView, coordinator: SwashTextView.Coordinator) {
        MainActor.assumeIsolated {
            let (director, target) = director(for: textView, coordinator: coordinator)
            fixInFlight = fix
            self.textView = textView
            self.coordinator = coordinator
            player = Task { @MainActor [weak self] in
                await self?.run(director: director, target: target)
            }
        }
    }

    @MainActor
    private func run(director: AgentTextDirector, target: WritingPartnerTarget) async {
        while var fix = fixInFlight, !fix.isCancelled, let edit = fix.remaining.first {
            fix.remaining.removeFirst()
            fixInFlight = fix
            // The word it replaces is still where it was: the person may have changed it meanwhile
            let text = target.realText as NSString
            guard WritingPartnerDefaults.mode(defaults) != .off, let textView = target.textView,
                  !textView.hasMarkedText(), NSMaxRange(edit.range) <= text.length,
                  text.substring(with: edit.range) == edit.original else {
                retry(fix)
                return
            }
            pendingStep = edit
            let animate = !WritingPartnerOverlay.reduceMotion && textView.window != nil
            let actionName = edit.actionName ?? WritingPartnerDefaults.actionName
            do {
                try await director.perform(AgentTextEdit(from: edit.range.location, to: NSMaxRange(edit.range), text: edit.replacement),
                                           by: Self.agent, actionName: actionName,
                                           options: AgentTypingOptions(selectMs: WritingPartnerOverlay.selectMs, animate: animate))
            } catch {
                pendingStep = nil
                target.clearGhost()
                if let fix = fixInFlight { retry(fix) }
                return
            }
            pendingStep = nil
            if target.commitSkipped, let fix = fixInFlight {
                retry(fix)
                return
            }
        }
        finish()
    }

    /// The edit being played, for `committed` to record.
    private var pendingStep: PartnerEdit?

    /// The director committed an edit: it's an undo step of the partner's, and what comes after it moved.
    private func committed(_ range: NSRange, text: String, caretBefore: Int) {
        let delta = (text as NSString).length - range.length
        let rangeAfter = NSRange(location: range.location, length: (text as NSString).length)
        if let edit = pendingStep {
            let voice = coordinator.map { WritingPartnerVoice(flavor: $0.parent.flavor) } ?? .punctuate
            applied.append(Step(
                voice: voice,
                rules: edit.rules,
                spellingWords: edit.spellingWords,
                caretBefore: caretBefore,
                rangeAfter: rangeAfter,
                original: edit.original,
                replacement: edit.replacement,
                bandleaderSuggestionId: edit.bandleaderSuggestionId,
                bandleaderSuggestionKind: edit.bandleaderSuggestionKind,
                bandleaderCheckId: edit.bandleaderCheckId
            ))
            if let suggestionId = edit.bandleaderSuggestionId,
               let kind = edit.bandleaderSuggestionKind {
                reportBandleaderFeedback(JazzTextFeedbackItem(
                    suggestionId: suggestionId,
                    kind: kind,
                    outcome: .accepted,
                    original: edit.original,
                    replacement: edit.replacement,
                    finalText: text,
                    checkId: edit.bandleaderCheckId
                ))
            }
        }
        let move = { (location: Int) -> Int in location >= NSMaxRange(range) ? location + delta : location }
        pendingBoundaries = pendingBoundaries.map { (move($0.location), $0.enterEndedLine) }
        if var fix = fixInFlight {
            fix.boundaries = fix.boundaries.map { (move($0.location), $0.enterEndedLine) }
            fix.remaining = fix.remaining.map { var edit = $0; edit.range.location = move(edit.range.location); return edit }
            fixInFlight = fix
        }
        if !suggestions.isEmpty {
            suggestions = suggestions.compactMap { suggestion in
                var suggestion = suggestion
                if suggestion.edit.range.location >= NSMaxRange(range) {
                    suggestion.edit.range.location += delta
                    suggestion.triggerEnd += delta
                    return suggestion
                }
                return NSMaxRange(suggestion.edit.range) <= range.location ? suggestion : nil
            }
            if let textView, let coordinator { refreshSuggestions(in: textView, coordinator: coordinator) }
        }
        if let textView, let coordinator, hasPauseProvider {
            let rawText = coordinator.rawText(of: textView)
            let rawSelection = coordinator.rawRange(forStorage: textView.selectedRange(), in: textView)
            if let current = BandleaderContextExtractor.extract(from: rawText, caret: rawSelection.location, flavor: coordinator.parent.flavor) {
                lastKnownParagraphRange = current.range
                lastKnownParagraphText = current.paragraph
                pauseDetector.updatePendingParagraph(current.paragraph, range: current.range, caret: rawSelection.location)
            }
        }
        observeUndo(textView?.undoManager)
    }

    /// The person is about to change the text while a fix plays: move the fix with it.
    @MainActor
    private func personWillEdit(_ range: NSRange, replacement: String) {
        if let target, let director {
            director.noteEdit(in: target.personWillEdit(range, replacement: replacement), replacement: replacement)
        }
        guard var fix = fixInFlight else { return }
        let delta = (replacement as NSString).length - range.length
        fix.boundaries = Self.move(fix.boundaries, through: range, replacement: replacement)
        // An edit whose word the person changed is dropped (the fix is worked out again when it's reached)
        fix.remaining = fix.remaining.compactMap { edit in
            var edit = edit
            if NSMaxRange(range) <= edit.range.location {
                edit.range.location += delta
                return edit
            }
            return range.location >= NSMaxRange(edit.range) ? edit : nil
        }
        fixInFlight = fix
    }

    /// The text changed under the fix (macOS's text replacement turns "teh" into "the" while the
    /// cursor is on its way): work it out again, once, on the text as it is now.
    private func retry(_ fix: Fix) {
        fixInFlight = nil
        guard !fix.isCancelled, !fix.isRetry, !fix.boundaries.isEmpty,
              WritingPartnerDefaults.mode(defaults) == .automatic,
              let textView, let coordinator, !textView.hasMarkedText() else {
            finish()
            return
        }
        pendingBoundaries = fix.boundaries + pendingBoundaries
        punctuate(in: textView, coordinator: coordinator, isRetry: true)
        if fixInFlight == nil { finish() }
    }

    /// The fix is done: boundaries typed while it played get their turn.
    private func finish() {
        fixInFlight = nil
        player = nil
        if let textView, let coordinator, !pendingBoundaries.isEmpty { didChange(in: textView, coordinator: coordinator) }
    }

    /// Stops the fix being played (undo, redo, the partner turned off); nothing partial is left.
    private func cancelFix() {
        pauseTask?.cancel()
        pauseTask = nil
        leadTask?.cancel()
        leadTask = nil
        guard fixInFlight != nil else { return }
        fixInFlight?.isCancelled = true
        MainActor.assumeIsolated { target?.clearGhost() }
        player?.cancel()
    }

    private static func move(_ boundaries: [(location: Int, enterEndedLine: Bool?)], through range: NSRange,
                             replacement: String) -> [(location: Int, enterEndedLine: Bool?)] {
        let delta = (replacement as NSString).length - range.length
        return boundaries.compactMap { pending in
            if pending.location >= NSMaxRange(range) { return (pending.location + delta, pending.enterEndedLine) }
            return pending.location < range.location ? pending : nil
        }
    }

    // MARK: Undo & Learning

    /// Counts an undone or dismissed fix against its rules, tells the spell checker and session
    /// memory to leave any spelling words in it alone, and reports bandleader feedback (#120).
    private func penalize(_ edit: PartnerEdit, in textView: NSTextView?) {
        penalize(rules: edit.rules, spellingWords: edit.spellingWords, in: textView)
        if let suggestionId = edit.bandleaderSuggestionId,
           let kind = edit.bandleaderSuggestionKind {
            sessionMemory.dismissWord(edit.original, replacement: edit.replacement, suggestionId: suggestionId)
            reportBandleaderFeedback(JazzTextFeedbackItem(
                suggestionId: suggestionId,
                kind: kind,
                outcome: .dismissed,
                original: edit.original,
                replacement: edit.replacement,
                checkId: edit.bandleaderCheckId
            ))
        }
    }

    private func penalize(rules: [PunctuationRule], spellingWords: [String], in textView: NSTextView?) {
        var stats = WritingPartnerStats.load(defaults)
        for rule in rules where rule != .spelling { stats.undone(rule) }
        stats.save(defaults)
        sessionMemory.learnWords(spellingWords)
        if let textView {
            let tag = textView.spellCheckerDocumentTag
            for word in spellingWords { NSSpellChecker.shared.ignoreWord(word, inSpellDocumentWithTag: tag) }
        }
    }

    private func reportBandleaderFeedback(_ item: JazzTextFeedbackItem) {
        sessionMemory.recordFeedback(item)
        let leader = activeBandleader
            ?? testingBandleader
            ?? MainActor.assumeIsolated {
                WritingBandleaderFactory.overrideBandleader
                    ?? WritingBandleaderFactory.makeBandleader(WritingPartnerDefaults.provider(defaults))
            }
        let request = JazzTextFeedbackRequest(items: [item])
        pendingFeedbackCount += 1
        Task { @MainActor [weak self] in
            defer { self?.pendingFeedbackCount -= 1 }
            await leader.reportFeedback(request)
        }
    }

    // MARK: - Pause Scheduling & Bandleader Evaluation

    private func schedulePauseCheck(in textView: NSTextView, coordinator: SwashTextView.Coordinator) {
        pauseTask?.cancel()
        let delay = pauseDetector.pauseDelay
        pauseTask = Task { @MainActor [weak self, weak textView, weak coordinator] in
            do {
                try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            } catch {
                return
            }
            guard let self, let textView, let coordinator else { return }
            self.evaluatePause(in: textView, coordinator: coordinator)
        }
    }

    private func triggerImmediatePause(in textView: NSTextView, coordinator: SwashTextView.Coordinator) {
        pauseTask?.cancel()
        pauseTask = Task { @MainActor [weak self, weak textView, weak coordinator] in
            guard let self, let textView, let coordinator else { return }
            self.evaluatePause(in: textView, coordinator: coordinator)
        }
    }

    @MainActor
    private func evaluatePause(in textView: NSTextView, coordinator: SwashTextView.Coordinator) {
        pauseTask = nil
        guard WritingPartnerDefaults.mode(defaults) != .off else { return }
        let provider = WritingPartnerDefaults.provider(defaults)
        let override = testingBandleader ?? WritingBandleaderFactory.overrideBandleader
        guard override != nil || provider != .none else { return }

        guard let pause = pauseDetector.checkPause() else { return }
        let rawText = coordinator.rawText(of: textView)
        guard let extracted = BandleaderContextExtractor.extract(from: rawText, caret: pause.caret, flavor: coordinator.parent.flavor) else { return }

        let stats = WritingPartnerStats.load(defaults)
        let spellingOn = WritingPartnerDefaults.spelling(defaults)
        let voices = [stats.toVoiceState(spellingOn: spellingOn)]
        let recentFeedback = sessionMemory.recordedFeedback.isEmpty ? nil : sessionMemory.recordedFeedback
        let request = JazzTextLeadRequest(
            paragraph: extracted.paragraph,
            before: extracted.before,
            after: extracted.after,
            flavor: coordinator.parent.flavor.jazzTextFlavor,
            voices: voices,
            feedback: recentFeedback
        )

        leadTask?.cancel()
        leadTask = Task { @MainActor [weak self, weak textView, weak coordinator] in
            defer { self?.leadTask = nil }
            guard let self, let textView, let coordinator else { return }
            guard let result = await WritingBandleaderFactory.leadWithFallback(
                request: request,
                provider: provider,
                override: override
            ) else {
                return
            }
            self.activeBandleader = result.bandleader
            self.applyBandleaderResponse(
                result.response,
                for: extracted.paragraph,
                paragraphRange: extracted.range,
                in: textView,
                coordinator: coordinator
            )
        }
    }

    private func applyBandleaderResponse(
        _ response: JazzTextLeadResponse,
        for paragraph: String,
        paragraphRange: NSRange,
        in textView: NSTextView,
        coordinator: SwashTextView.Coordinator
    ) {
        let mode = WritingPartnerDefaults.mode(defaults)
        guard mode != .off else { return }
        let spellingOn = WritingPartnerDefaults.spelling(defaults)
        let rawText = coordinator.rawText(of: textView)

        let plan = BandleaderSuggestionPlanner.plan(
            response: response,
            paragraph: paragraph,
            paragraphRange: paragraphRange,
            documentText: rawText,
            flavor: coordinator.parent.flavor,
            mode: mode,
            spellingEnabled: spellingOn,
            memory: sessionMemory
        )

        self.paragraphVoiceSettings = plan.voiceSettings

        // Register personal and team vocabulary words with NSSpellChecker so they are neither
        // flagged with red underlines nor "corrected" away in this document (#120).
        if !plan.vocabulary.isEmpty {
            let tag = textView.spellCheckerDocumentTag
            for word in plan.vocabulary {
                NSSpellChecker.shared.ignoreWord(word, inSpellDocumentWithTag: tag)
            }
        }

        // Offer uncertain / Suggest-mode inline suggestions as underlines (#103, #120).
        if !plan.offeredEdits.isEmpty {
            let selection = coordinator.rawRange(forStorage: textView.selectedRange(), in: textView)
            offer(plan.offeredEdits, triggerEnd: selection.location, in: textView, coordinator: coordinator)
        }

        // Apply high-confidence inline suggestions at once through the partner's cursor (#120).
        if !plan.automaticEdits.isEmpty {
            if var inFlight = fixInFlight, !inFlight.isCancelled {
                inFlight.remaining.append(contentsOf: plan.automaticEdits)
                fixInFlight = inFlight
            } else {
                play(Fix(remaining: plan.automaticEdits, boundaries: [], isRetry: false), in: textView, coordinator: coordinator)
            }
        }

        // Show a structural block suggestion prompt if present and no inline cursor edit is running.
        guard let suggestion = plan.structuralSuggestion else { return }

        self.activeSuggestion = (suggestion: suggestion, paragraph: paragraph, paragraphRange: paragraphRange)

        let overlay = WritingPartnerOverlay.overlay(for: textView)
        let rawStart = paragraphRange.location + suggestion.range.start
        let rawEnd = paragraphRange.location + suggestion.range.end
        let storageRange = coordinator.storageRange(forRaw: NSRange(location: rawStart, length: max(0, rawEnd - rawStart)), in: textView)
        let rects = WritingPartnerOverlay.rects(for: storageRange, in: textView)
        let targetRect = rects.last ?? WritingPartnerOverlay.caretRect(at: storageRange.location, in: textView) ?? NSRect(x: 20, y: 20, width: 100, height: 20)

        overlay.showSuggestionPrompt(
            suggestion: suggestion,
            at: targetRect,
            onAccept: { [weak self] in self?.acceptActiveSuggestion() },
            onDismiss: { [weak self] in self?.dismissActiveSuggestion() }
        )
    }

    // MARK: - Testing Helpers

    func setBandleaderForTesting(_ bandleader: (any WritingBandleader)?) {
        self.testingBandleader = bandleader
        self.activeBandleader = bandleader
    }

    func setPauseDetectorForTesting(_ detector: WritingPauseDetector) {
        self.pauseDetector = detector
    }

    var sessionMemoryForTesting: BandleaderSessionMemory {
        sessionMemory
    }

    var paragraphVoiceSettingsForTesting: ParagraphVoiceSettings? {
        paragraphVoiceSettings
    }

    @MainActor
    func triggerPauseCheckForTesting(in textView: NSTextView, coordinator: SwashTextView.Coordinator) {
        evaluatePause(in: textView, coordinator: coordinator)
    }

    // MARK: Undo

    /// Undoing the partner's step straight away counts against its rules.
    private func observeUndo(_ undoManager: UndoManager?) {
        guard let undoManager, undoManager !== observedUndoManager else { return }
        if let undoObserver { NotificationCenter.default.removeObserver(undoObserver) }
        observedUndoManager = undoManager
        undoObserver = NotificationCenter.default.addObserver(
            forName: .NSUndoManagerDidUndoChange, object: undoManager, queue: .main
        ) { [weak self] notification in
            let redoName = (notification.object as? UndoManager)?.redoActionName
            let isPartnerStep = redoName == WritingPartnerDefaults.actionName || redoName == WritingPartnerDefaults.suggestionActionName
            self?.didUndo(isPartnerStep: isPartnerStep)
        }
    }

    private func didUndo(isPartnerStep: Bool) {
        guard isPartnerStep, let step = applied.popLast() else { return }
        // Undoing a spelling fix says the word is right: the spell checker leaves it alone in this
        // document. Other rules learn to fix less, in the voice that made the fix.
        var stats = WritingPartnerStats.load(defaults, voice: step.voice)
        for rule in step.rules where rule != .spelling { stats.undone(rule) }
        stats.save(defaults, voice: step.voice)
        sessionMemory.learnWords(step.spellingWords)
        if let textView {
            let tag = textView.spellCheckerDocumentTag
            for word in step.spellingWords { NSSpellChecker.shared.ignoreWord(word, inSpellDocumentWithTag: tag) }
        }
        if let suggestionId = step.bandleaderSuggestionId,
           let kind = step.bandleaderSuggestionKind {
            sessionMemory.dismissWord(step.original, replacement: step.replacement, suggestionId: suggestionId)
            reportBandleaderFeedback(JazzTextFeedbackItem(
                suggestionId: suggestionId,
                kind: kind,
                outcome: .undone,
                original: step.original,
                replacement: step.replacement,
                finalText: step.original,
                checkId: step.bandleaderCheckId
            ))
        }
        // Undo selects the restored word; put the caret back where the person was typing, after
        // the editor has restyled the change
        let caret = step.caretBefore
        DispatchQueue.main.async { [weak self] in
            guard let self, let textView = self.textView, let coordinator = self.coordinator else { return }
            let length = (coordinator.rawText(of: textView) as NSString).length
            let raw = NSRange(location: min(caret, length), length: 0)
            textView.setSelectedRange(coordinator.storageRange(forRaw: raw, in: textView))
        }
    }
}
#endif

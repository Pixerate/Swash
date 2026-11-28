//
//  WritingPartnerSession.swift
//  Swash
//
//  Connects the writing partner's Punctuate voice (WritingPartner.swift, #61) to an editor: the Mac's
//  NSTextView or the iOS editors, through `WritingPartnerHost` (WritingPartnerHost.swift, #109).
//  When the person types a space, punctuation or a blank line, the session asks the voice for
//  fixes to what they just finished. The partner's cursor plays each fix out through the editor
//  package's `AgentTextDirector` (#878): it selects the word, types the new one, and the edit lands
//  as its own undo step ("Undo Punctuation"). Undoing a step straight away counts against the rules
//  it applied; typing on keeps it.
//

import Foundation
import CoreGraphics
import NaturalLanguage
import Observation
import PixerateCore
import PixerateMarkdown

/// Tracks the most recently active document's flavour and language so Settings › Writing can show
/// which voice is playing and any language reason even when the Settings window is key (#105, #111).
@MainActor
@Observable
final class WritingPartnerActiveVoice {
    static let shared = WritingPartnerActiveVoice()

    var documentFlavor: MarkdownFlavor?
    var documentLanguage: NLLanguage = .english

    func currentFlavor(default defaultFlavor: MarkdownFlavor) -> MarkdownFlavor {
        documentFlavor ?? defaultFlavor
    }

    func updateLanguage(for text: String) {
        documentLanguage = GrammarLanguageSupport.detectLanguage(in: text)
    }

    func unsupportedLanguageReason(for provider: WritingPartnerProvider) -> String? {
        GrammarLanguageSupport.unsupportedReason(for: documentLanguage, provider: provider)
    }
}

/// The editor as the partner's director sees it: the raw Markdown, with the word the partner is
/// typing shown in place of the word it replaces. The frames of typing are never written into the
/// editor (that would leave the person's own typing with undo ranges that no longer fit, and
/// publish half-typed words): `ghost` holds them and the host's canvas draws them. Only the
/// commit edits the text, as one undoable `applyPartnerEdit`.
@MainActor
final class WritingPartnerTarget: AgentTextTarget {
    weak var host: (any WritingPartnerHost)?
    /// What the partner is typing: `range` of the raw text shows as `text`.
    private(set) var ghost: (range: NSRange, text: String)?
    /// Called when `ghost` changes, to redraw it.
    var onGhostChange: (() -> Void)?
    /// Called after a commit: the raw range replaced, its new text, and where the person's caret was.
    var onCommit: ((NSRange, String, Int) -> Void)?
    /// Set when a commit couldn't be made (the person is composing with an input method).
    private(set) var commitSkipped = false

    init(host: any WritingPartnerHost) {
        self.host = host
    }

    /// Nonisolated: an isolated deinit crashes on the iOS Simulator (GOTCHAS #103).
    nonisolated deinit {}

    /// The raw Markdown as it is in the editor.
    var realText: String {
        host?.partnerRawText ?? ""
    }

    var agentText: String {
        let real = realText as NSString
        guard let ghost, NSMaxRange(ghost.range) <= real.length else { return real as String }
        return real.replacingCharacters(in: ghost.range, with: ghost.text)
    }

    var agentReadOnlyReason: String? {
        guard let host else { return "The editor was closed." }
        return host.partnerCanEdit ? nil : "The document can't be edited."
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
        guard let host, !host.partnerHasMarkedText else { commitSkipped = true; return }
        let current = realText as NSString
        guard NSMaxRange(real) <= current.length else { commitSkipped = true; return }
        let selection = host.partnerRawSelection
        let length = (text as NSString).length
        let caret: Int
        if selection.location >= NSMaxRange(real) {
            caret = selection.location + length - real.length
        } else if NSMaxRange(selection) > real.location {
            caret = real.location + length
        } else {
            caret = selection.location
        }
        host.applyPartnerEdit(newRawText: current.replacingCharacters(in: real, with: text),
                              rawSelection: NSRange(location: caret, length: 0), actionName: actionName)
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

/// Not isolated itself (the swiftc runners compile the editor in Swift 5 mode, where the Mac's
/// coordinator isn't on the main actor); everything that touches the director runs on the main actor.
final class WritingPartnerSession {
    /// Who the partner is, for its cursor.
    static let agent = AgentCaretInfo(id: "writing-partner", name: "Writing partner", color: "#AF52DE")
    /// How long the partner's cursor takes to select a word before typing over it.
    static let selectMs: Double = 180

    /// Word boundaries the person typed (raw-Markdown offsets) that haven't been looked at yet. More
    /// than one when they type faster than the run loop turns, or while the partner is busy.
    /// `enterEndedLine` records whether an Enter was at the end of its line when it was pressed:
    /// by the time it's looked at, the person may have typed the next line.
    private var pendingBoundaries: [(location: Int, enterEndedLine: Bool?)] = []
    private var isScheduled = false
    /// What the person changed (raw offsets) that the Formatting voice (#113) hasn't tidied yet:
    /// it tidies a block once the caret has left it, and never touches text nobody edited.
    private(set) var formattingDirty: [NSRange] = []
    private var isTidyScheduled = false
    /// The partner's undo steps since the person last typed, oldest first: typing keeps them all,
    /// undo takes back the newest.
    private var applied: [Step] = []
    /// The editor the partner last worked in.
    private weak var currentHost: (any WritingPartnerHost)?
    /// Read by the nonisolated deinit (GOTCHAS #103); set and cleared on the main thread only.
    nonisolated(unsafe) private var undoObserver: NSObjectProtocol?
    private weak var observedUndoManager: UndoManager?
    private let defaults: UserDefaults

    /// The director playing fixes in `target`, made for the text view it's in.
    private var director: AgentTextDirector?
    private var target: WritingPartnerTarget?
    /// The fix being played, and the task playing it.
    private var fixInFlight: Fix?
    private var player: Task<Void, Never>?

    /// A fix offered as an underline (#103; since #229 only a mark being settled), waiting for the person to accept or dismiss it.
    struct Suggestion: Equatable {
        var edit: PartnerEdit
        /// Raw-Markdown offset just after the boundary that offered this fix.
        var triggerEnd: Int
        /// The mark this shows a candidate for (#128): settled, not dismissed, and never by typing past.
        var markID: Int? = nil
    }

    /// How far (UTF-16 units) the person can type past a suggestion before ignoring it counts as dismissing it.
    static let suggestionReach = 40

    /// Active suggestions, in document order.
    private(set) var suggestions: [Suggestion] = []
    /// Most recent VoiceOver announcement for a suggestion.
    private(set) var lastAnnouncement: String?
    /// Whether the first-run introduction note is currently visible (#112).
    private(set) var hasActiveIntroduction = false
    /// Whether the quiet reminder on the first undone fix is currently visible (#112).
    private(set) var hasActiveUndoReminder = false
    /// Whether the writing partner is paused for this document (#112).
    private(set) var isPaused = false
    /// Called when `isPaused` changes so the document window can update its status bar and menu item.
    var onPauseChange: ((Bool) -> Void)?

    // MARK: - Marks (#128)
    /// What the partner isn't sure about, in document order. Never written into the Markdown.
    private(set) var marks: [PartnerUncertainMark] = []
    private var nextMarkID = 1
    /// Words and phrases the person kept as written: not marked again in this document.
    private var keptMarks: Set<String> = []
    /// The mark whose candidate is shown in place (review, or the caret in it), and which candidate.
    private(set) var activeMarkID: Int?
    private var activeCandidate = 0
    /// Whether the person is stepping through the marks.
    private(set) var isReviewing = false
    /// Called with the number of marks, for the status bar.
    var onMarksChange: ((Int) -> Void)?

    // MARK: - Edit Layers (#229)

    /// The partner's edits this session, on their Copyedit and Ghostwrite layers. Never saved.
    private(set) var layers = EditLayerStack()
    /// Called when the layers may have changed, for the edit layers list.
    var onLayersChange: (() -> Void)?

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

    var partner: any WritingPartner

    init(partner: any WritingPartner = PunctuateVoice(), defaults: UserDefaults = .standard) {
        self.partner = partner
        self.defaults = defaults
    }

    /// Nonisolated: an isolated deinit crashes on the iOS Simulator (GOTCHAS #103).
    nonisolated deinit {
        if let undoObserver { NotificationCenter.default.removeObserver(undoObserver) }
    }

    /// True while the partner has nothing to do (for tests).
    var isIdle: Bool {
        fixInFlight == nil
            && pendingBoundaries.isEmpty
            && !isScheduled
            && !isTidyScheduled
            && pauseTask == nil
            && leadTask == nil
            && pendingFeedbackCount == 0
    }

    /// Whether an inline structural suggestion prompt is currently active.
    var hasActiveSuggestion: Bool { activeSuggestion != nil }

    /// The active suggestion item, if any.
    var activeSuggestionItem: JazzTextSuggestion? { activeSuggestion?.suggestion }

    // MARK: - First-Run Introduction, Undo Reminder & Per-Document Pause (#112)

    /// Chooses a level (Copyedit or Ghostwrite) from the first-run introduction and hides it.
    func chooseIntroductionMode(_ chosenMode: WritingPartnerMode, in host: (any WritingPartnerHost)? = nil) {
        WritingPartnerDefaults.setIntroShown(true, defaults)
        defaults.set(chosenMode.rawValue, forKey: WritingPartnerDefaults.mode)
        hideIntroduction(in: host)
    }

    /// Dismisses the first-run introduction ("Not now" / Escape), remembering `.off` in `UserDefaults`.
    @discardableResult
    func dismissIntroduction(in host: (any WritingPartnerHost)? = nil) -> Bool {
        guard hasActiveIntroduction else { return false }
        WritingPartnerDefaults.setIntroShown(true, defaults)
        defaults.set(WritingPartnerMode.off.rawValue, forKey: WritingPartnerDefaults.mode)
        pendingBoundaries = []
        cancelFix()
        clearSuggestions(in: host)
        hideIntroduction(in: host)
        (host ?? currentHost)?.setSystemTextAssistsSuppressed(false)
        return true
    }

    private func hideIntroduction(in host: (any WritingPartnerHost)? = nil) {
        guard hasActiveIntroduction else { return }
        hasActiveIntroduction = false
        (host ?? currentHost)?.partnerCanvas?.hideIntroduction()
    }

    /// Dismisses the quiet reminder shown after the first undone fix.
    @discardableResult
    func dismissUndoReminder(in host: (any WritingPartnerHost)? = nil) -> Bool {
        guard hasActiveUndoReminder else { return false }
        hasActiveUndoReminder = false
        (host ?? currentHost)?.partnerCanvas?.hideUndoReminder()
        return true
    }

    /// Pauses or resumes the writing partner for this document only, without changing `UserDefaults`.
    func setPaused(_ paused: Bool, in host: (any WritingPartnerHost)? = nil) {
        guard paused != isPaused else { return }
        isPaused = paused
        if paused {
            pendingBoundaries = []
            cancelFix()
            resetBandleaderSession()
            clearSuggestions(in: host)
            if hasActiveSuggestion {
                activeSuggestion = nil
                (host ?? currentHost)?.partnerCanvas?.hideSuggestionPrompt()
            }
            hideIntroduction(in: host)
            dismissUndoReminder(in: host)
            (host ?? currentHost)?.setSystemTextAssistsSuppressed(false)
        }
        onPauseChange?(paused)
    }

    /// Toggles the per-document pause state and returns the new `isPaused` value.
    @discardableResult
    func togglePaused(in host: (any WritingPartnerHost)? = nil) -> Bool {
        setPaused(!isPaused, in: host)
        return isPaused
    }

    /// Accepts the active structural suggestion, applying it as one undo step through the partner's cursor.
    func acceptActiveSuggestion(layer: PartnerEditLayer = .copyedit) {
        guard let active = activeSuggestion, let host = currentHost else { return }
        let (suggestion, _, paragraphRange) = active
        activeSuggestion = nil
        host.partnerCanvas?.hideSuggestionPrompt()

        let rawStart = paragraphRange.location + suggestion.range.start
        let rawEnd = paragraphRange.location + suggestion.range.end
        let rawLength = max(0, rawEnd - rawStart)
        let rawRange = NSRange(location: rawStart, length: rawLength)
        let rawText = host.partnerRawText as NSString
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
            bandleaderCheckId: suggestion.checkId,
            layer: layer
        )
        play(Fix(remaining: [edit], boundaries: [], isRetry: false), in: host)
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
        currentHost?.partnerCanvas?.hideSuggestionPrompt()
    }

    /// The person is about to type `string` over `raw` (raw-Markdown offsets). Call only for their own
    /// typing: not for Swash's edits, restyling, SwiftUI updates or Writing Tools.
    func willType(_ string: String?, inRaw raw: NSRange, host: any WritingPartnerHost) {
        currentHost = host
        // The person's typing (and undo) moves the partner's layers; what it rewrites becomes theirs (#229)
        if !layers.isEmpty {
            layers.move(through: raw, replacement: string ?? "")
            onLayersChange?()
        }
        if !marks.isEmpty {
            let isUndo = host.partnerUndoManager.map { $0.isUndoing || $0.isRedoing } ?? false
            moveMarks(through: raw, replacement: string ?? "", byPerson: !isUndo, in: host)
        }
        if hasActiveUndoReminder {
            dismissUndoReminder(in: host)
        }
        if hasActiveSuggestion {
            host.partnerCanvas?.hideSuggestionPrompt()
            activeSuggestion = nil
        }
        if let undoManager = host.partnerUndoManager, undoManager.isUndoing || undoManager.isRedoing {
            pendingBoundaries = []
            formattingDirty = []
            cancelFix()
            clearSuggestions(in: host)
            return
        }
        // First run (#112): the first time a document is edited, introduce the partner in place and
        // play a sample fix before touching the person's words. It counts as shown only once they
        // answer it (Automatically, Suggest or Not now): until then the partner does nothing, so
        // closing the window without answering never leaves it on unchosen. Someone whose partner is
        // Off (an explicit choice, or an upgrade that kept it off) isn't asked again.
        if hasActiveIntroduction {
            return
        }
        if !isPaused, !WritingPartnerDefaults.introShown(defaults), WritingPartnerDefaults.mode(defaults) != .off {
            hasActiveIntroduction = true
            let privacy = WritingPartnerCopy.privacy(signedIn: WritingPartnerDefaults.provider(defaults) == .pixerate)
            let announcement = "\(WritingPartnerCopy.introduction). \(privacy)"
            lastAnnouncement = announcement
            let targetRect = host.partnerCaretRect(atRaw: raw.location) ?? CGRect(x: 0, y: 0, width: 2, height: 20)
            host.partnerCanvas?.showIntroduction(
                at: targetRect,
                onChooseMode: { [weak self, weak host] chosenMode in
                    self?.chooseIntroductionMode(chosenMode, in: host)
                },
                onDismiss: { [weak self, weak host] in
                    self?.dismissIntroduction(in: host)
                }
            )
            host.partnerAnnounce(announcement)
            return
        }
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
                if suggestion.markID != nil {
                    // A mark's candidate stays shown only while the caret is in the mark or a review
                    // is on; typing elsewhere hides it and leaves the mark (#128)
                    return nil
                }
                if raw.location >= NSMaxRange(suggestion.edit.range) {
                    // Typing on after a suggestion keeps it on offer. Finishing the line, or typing
                    // well past it, without accepting it dismisses it and counts against its rules
                    // A tidy offered for a block the person has left waits for them: typing elsewhere is
                    // what they're meant to be doing (#113)
                    if suggestion.edit.rules.allSatisfy(\.isFormatting) { return suggestion }
                    if replacement.contains("\n") || raw.location - suggestion.triggerEnd > Self.suggestionReach {
                        penalize(suggestion.edit, in: host)
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
            if activeMarkID != nil, !suggestions.contains(where: { $0.markID != nil }) {
                activeMarkID = nil
                isReviewing = false
            }
            refreshSuggestions(in: host)
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
        let isOn = mode != .off && !isPaused && !hasActiveIntroduction
        if !isOn {
            cancelFix()
            clearSuggestions(in: host)
        } else if !suggestions.isEmpty {
            // Keep lower-confidence bandleader suggestions that were offered as underlined
            // suggestions (#120) until accepted, edited, or dismissed.
            suggestions.removeAll { $0.edit.bandleaderSuggestionId == nil && $0.markID == nil }
            refreshSuggestions(in: host)
        }
        // The system's inline predictions and autocorrect also write at the caret, and the two
        // together lose or corrupt fixes: while the partner is on it does the autocorrecting itself
        host.setSystemTextAssistsSuppressed(isOn)

        if isOn {
            formattingDirty = Self.move(ranges: formattingDirty, through: raw, replacement: replacement)
            formattingDirty.append(NSRange(location: raw.location, length: (replacement as NSString).length))
        } else {
            formattingDirty = []
        }

        let charCode: unichar = (replacement as NSString).length > 0 ? (replacement as NSString).character(at: 0) : 0
        var enterEndedLine: Bool?
        if charCode == 0x0A {
            let text = host.partnerRawText as NSString
            enterEndedLine = raw.location >= text.length || text.character(at: raw.location) == 0x0A
        }

        // Pause detection: record typing and back off while editing continues
        if isOn, hasPauseProvider {
            let rawText = host.partnerRawText
            MainActor.assumeIsolated { WritingPartnerActiveVoice.shared.updateLanguage(for: rawText) }
            if let extracted = BandleaderContextExtractor.extract(from: rawText, caret: raw.location, flavor: host.partnerFlavor) {
                lastKnownParagraphRange = extracted.range
                lastKnownParagraphText = extracted.paragraph
                pauseDetector.noteTyping(
                    character: charCode,
                    paragraph: extracted.paragraph,
                    range: extracted.range,
                    caret: raw.location,
                    enterEndedSentence: enterEndedLine ?? false
                )
                schedulePauseCheck(in: host)
            }
        }

        guard isOn, let string, (string as NSString).length == 1, raw.length == 0,
              host.partnerRawSelection.length == 0, !host.partnerHasMarkedText else {
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
    func didChange(in host: any WritingPartnerHost) {
        if WritingPartnerDefaults.mode(defaults) != .off && !isPaused && !hasActiveIntroduction && hasPauseProvider {
            let rawText = host.partnerRawText
            let rawSelection = host.partnerRawSelection
            if let current = BandleaderContextExtractor.extract(from: rawText, caret: rawSelection.location, flavor: host.partnerFlavor) {
                if let lastRange = lastKnownParagraphRange,
                   let lastText = lastKnownParagraphText,
                   lastRange.location != current.range.location,
                   NSIntersectionRange(lastRange, current.range).length == 0 {
                    pauseDetector.noteLeftParagraph(oldParagraph: lastText, oldRange: lastRange)
                    triggerImmediatePause(in: host)
                } else {
                    pauseDetector.updatePendingParagraph(current.paragraph, range: current.range, caret: rawSelection.location)
                }
                lastKnownParagraphRange = current.range
                lastKnownParagraphText = current.paragraph
            }
        }
        guard !pendingBoundaries.isEmpty, !isScheduled, fixInFlight == nil else {
            scheduleTidy(in: host)
            return
        }
        isScheduled = true
        DispatchQueue.main.async { [weak self, weak host] in
            guard let self else { return }
            self.isScheduled = false
            guard let host else { self.pendingBoundaries = []; return }
            self.punctuate(in: host)
        }
    }

    private func punctuate(in host: any WritingPartnerHost, isRetry: Bool = false) {
        let boundaries = pendingBoundaries
        pendingBoundaries = []
        let mode = WritingPartnerDefaults.mode(defaults)
        guard mode != .off, !isPaused, !hasActiveIntroduction, !host.partnerHasMarkedText,
              host.partnerCanEdit else { return }
        let raw = host.partnerRawText
        let selection = host.partnerRawSelection
        guard selection.length == 0 else { return }
        let flavor = host.partnerFlavor
        let voice = WritingPartnerVoice(flavor: flavor)
        let stats = WritingPartnerStats.load(defaults, voice: voice)
        let spellingOn = WritingPartnerDefaults.spelling(defaults)
        /// The rule's switch and what the partner has learned; the pause tier may hold rules back per paragraph below.
        let ruleIsOn: (PunctuationRule) -> Bool = { rule in
            if rule == .spelling { return spellingOn }
            return WritingPartnerDefaults.isRuleEnabled(rule, self.defaults) && stats.isActive(rule)
        }
        let spellingCorrection: (String, NSRange, String) -> String? = { [weak self, weak host] word, range, text in
            if self?.sessionMemory.isKnownWord(word) == true { return nil }
            return host?.partnerSpellingCorrection(forWordRange: range, in: text)
        }
        let overlay = host.partnerCanvas

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
            let document = working == raw as NSString ? host.partnerDocument(for: text) : MarkdownDocument.parse(text, flavor: flavor)
            if shift == 0, let range = partner.checkedRange(text: text, boundary: boundary, document: document) {
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
            let edits = partner.edits(text: text, boundary: boundary, document: document, flavor: flavor,
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
            overlay?.sweep(checked.flatMap { host.partnerRects(forRaw: $0) })
            scheduleTidy(in: host)
            return
        }
        play(Fix(remaining: edits, boundaries: boundaries, isRetry: isRetry), in: host)
    }

    // MARK: Formatting (#113)

    /// The caret moved: a block it left may be ready to tidy.
    func selectionDidChange(in host: any WritingPartnerHost) {
        // A caret in one of the partner's marks shows its candidate (#128)
        caretMovedForMarks(in: host)
        guard !formattingDirty.isEmpty else { return }
        scheduleTidy(in: host)
    }

    /// Tidies on the next turn of the run loop, after punctuation has had its turn.
    private func scheduleTidy(in host: any WritingPartnerHost) {
        guard !formattingDirty.isEmpty, !isTidyScheduled else { return }
        isTidyScheduled = true
        DispatchQueue.main.async { [weak self, weak host] in
            guard let self else { return }
            self.isTidyScheduled = false
            guard let host else { return }
            self.tidy(in: host)
        }
    }

    /// Whether the Formatting voice plays in this editor: not for Slack (the Chat voice's). Since
    /// #229 it tidies in Source view too, like the Formatted view.
    private func isFormattingOn(_ host: any WritingPartnerHost) -> Bool {
        host.partnerFlavor != .slack
    }

    /// Tidies the blocks the person changed and has since left. The block the caret is in waits.
    private func tidy(in host: any WritingPartnerHost) {
        let mode = WritingPartnerDefaults.mode(defaults)
        guard !formattingDirty.isEmpty, fixInFlight == nil, pendingBoundaries.isEmpty, !isScheduled,
              mode != .off, !isPaused, !hasActiveIntroduction, !host.partnerHasMarkedText,
              host.partnerCanEdit else { return }
        guard isFormattingOn(host) else { formattingDirty = []; return }
        let raw = host.partnerRawText
        let selection = host.partnerRawSelection
        guard selection.length == 0 else { return }
        let document = host.partnerDocument(for: raw)
        // What touches the caret's block waits; the rest is tidied now
        let caretSpan = FormattingVoice.caretSpan(text: raw, document: document, caret: selection.location)
        let waiting = formattingDirty.filter { dirty in
            guard let caretSpan else { return false }
            return dirty.location <= NSMaxRange(caretSpan) && NSMaxRange(dirty) >= caretSpan.location
        }
        let ready = formattingDirty.filter { dirty in !waiting.contains { NSEqualRanges($0, dirty) } }
        formattingDirty = waiting
        guard !ready.isEmpty else { return }
        let stats = WritingPartnerStats.load(defaults, voice: .punctuate)
        let isActive: (PunctuationRule) -> Bool = { rule in
            WritingPartnerDefaults.isRuleEnabled(rule, self.defaults) && stats.isActive(rule)
        }
        let fixes = FormattingVoice.edits(text: raw, document: document, flavor: host.partnerFlavor,
                                          regions: ready, caret: selection.location, isActive: isActive)
        guard !fixes.isEmpty else { return }
        let ns = raw as NSString
        let edits = fixes.map { fix -> PartnerEdit in
            let original = ns.substring(with: fix.range)
            return PartnerEdit(range: fix.range, original: original, replacement: fix.replacement, rules: fix.rules,
                               spellingWords: [], actionName: WritingPartnerDefaults.formattingActionName,
                               playsInstantly: original.contains("\n") || fix.replacement.contains("\n") || fix.replacement.isEmpty)
        }
        play(Fix(remaining: edits, boundaries: [], isRetry: false), in: host)
    }

    // MARK: Marks (#128)

    /// Marks `edits` (fixes the partner isn't sure of) instead of making or offering them.
    private func addMarks(_ edits: [PartnerEdit], in host: any WritingPartnerHost) {
        let text = host.partnerRawText as NSString
        let new = edits.map { edit -> PartnerUncertainMark in
            defer { nextMarkID += 1 }
            return PartnerUncertainMark(id: nextMarkID, edit: edit, candidates: [edit.replacement] + edit.alternatives)
        }
        let before = marks.count
        marks = PartnerMarks.adding(new, to: marks, kept: keptMarks, in: text)
        refreshMarks(in: host)
        if marks.count > before, WritingPartnerDefaults.announceMarks(defaults) {
            announce("\(marks.count) to check", in: host)
        }
    }

    /// Moves the marks through an edit. A mark the person edits is settled their way: it goes, and
    /// isn't made again here. One the partner's own edit replaced (an accepted candidate) just goes.
    private func moveMarks(through range: NSRange, replacement: String, byPerson: Bool,
                           in host: any WritingPartnerHost) {
        let (moved, edited) = PartnerMarks.moved(marks, through: range, replacement: replacement)
        marks = moved
        if byPerson { for mark in edited { keptMarks.insert(PartnerMarks.key(mark.original)) } }
        if let active = activeMarkID, edited.contains(where: { $0.id == active }) {
            activeMarkID = nil
            suggestions.removeAll { $0.markID == active }
        }
        // A shown candidate moves with its mark
        suggestions = suggestions.compactMap { suggestion in
            guard let id = suggestion.markID else { return suggestion }
            guard let mark = marks.first(where: { $0.id == id }) else { return nil }
            var moved = suggestion
            moved.edit.range = mark.range
            moved.triggerEnd = NSMaxRange(mark.range)
            return moved
        }
        if marks.isEmpty { isReviewing = false }
        DispatchQueue.main.async { [weak self, weak host] in
            guard let self, let host else { return }
            self.refreshMarks(in: host)
        }
    }

    /// Redraws the marks (not the one shown as a candidate) and reports their number.
    func refreshMarks(in host: any WritingPartnerHost) {
        let overlay = host.partnerCanvas
        let rects = marks.filter { $0.id != activeMarkID }.flatMap {
            host.partnerRects(forRaw: $0.range)
        }
        overlay?.showMarks(rects)
        onMarksChange?(marks.count)
    }

    /// Shows the mark at `index` with its candidate in place, as an underlined suggestion, and puts
    /// the caret just after it, so Tab or ⌥⏎ accepts and Esc keeps the text as written.
    private func showMark(at index: Int?, candidate: Int = 0, moveCaret: Bool = true,
                          in host: any WritingPartnerHost) {
        suggestions.removeAll { $0.markID != nil }
        guard let index, marks.indices.contains(index) else {
            activeMarkID = nil
            if isReviewing { announce("Nothing left to check", in: host) }
            isReviewing = false
            refreshSuggestions(in: host)
            refreshMarks(in: host)
            return
        }
        let mark = marks[index]
        activeMarkID = mark.id
        activeCandidate = min(candidate, mark.candidates.count - 1)
        suggestions.append(Suggestion(edit: mark.edit(choosing: activeCandidate), triggerEnd: NSMaxRange(mark.range), markID: mark.id))
        suggestions.sort { $0.edit.range.location < $1.edit.range.location }
        if moveCaret {
            isMovingCaretToMark = true
            host.setPartnerRawSelection(NSRange(location: NSMaxRange(mark.range), length: 0), scrollToVisible: true)
            isMovingCaretToMark = false
        }
        refreshSuggestions(in: host)
        refreshMarks(in: host)
        let position = isReviewing ? "\(index + 1) of \(marks.count): " : ""
        let choice = mark.candidates.count > 1 ? " Showing “\(mark.candidates[activeCandidate])”." : ""
        announce("To check \(position)\(mark.label).\(choice) Tab to accept, Escape to keep as written.", in: host)
    }

    private var isMovingCaretToMark = false

    /// Starts stepping through the marks from the first, in document order.
    @discardableResult
    func reviewMarks(in host: any WritingPartnerHost) -> Bool {
        guard !marks.isEmpty, fixInFlight == nil else { return false }
        isReviewing = true
        showMark(at: 0, in: host)
        return true
    }

    /// Moves the review to the next (or previous) mark.
    @discardableResult
    func stepMarks(by offset: Int, in host: any WritingPartnerHost) -> Bool {
        guard !marks.isEmpty, fixInFlight == nil else { return false }
        isReviewing = true
        let current = activeMarkID.flatMap { id in marks.firstIndex { $0.id == id } }
        showMark(at: PartnerMarks.step(from: current, by: offset, count: marks.count), in: host)
        return true
    }

    /// Shows the shown mark's next candidate.
    @discardableResult
    func nextCandidate(in host: any WritingPartnerHost) -> Bool {
        guard let id = activeMarkID, let index = marks.firstIndex(where: { $0.id == id }), marks[index].candidates.count > 1 else { return false }
        showMark(at: index, candidate: (activeCandidate + 1) % marks[index].candidates.count, moveCaret: false,
                 in: host)
        return true
    }

    /// Accepts `candidate` for the mark with `id` (from the context menu).
    @discardableResult
    func acceptMark(id: Int, candidate: Int, in host: any WritingPartnerHost) -> Bool {
        guard let index = marks.firstIndex(where: { $0.id == id }), fixInFlight == nil else { return false }
        showMark(at: index, candidate: candidate, moveCaret: false, in: host)
        guard let shown = suggestions.first(where: { $0.markID == id }) else { return false }
        suggestions.removeAll { $0.markID == id }
        refreshSuggestions(in: host)
        activeMarkID = nil
        play(Fix(remaining: [shown.edit], boundaries: [], isRetry: false), in: host)
        return true
    }

    /// Keeps the text as written for the mark with `id`: it goes, the same word or phrase isn't
    /// marked again in this document, and the rule that made it is less eager (as an undo is).
    func keep(markID id: Int, alreadyPenalized: Bool = false, in host: any WritingPartnerHost) {
        guard let mark = marks.first(where: { $0.id == id }) else { return }
        suggestions.removeAll { $0.markID == id }
        if !alreadyPenalized { penalize(mark.edit, in: host) }
        keptMarks.insert(PartnerMarks.key(mark.original))
        marks.removeAll { $0.id == id }
        let wasActive = activeMarkID == id
        if wasActive { activeMarkID = nil }
        if isReviewing, wasActive {
            let next = marks.firstIndex { $0.range.location >= mark.range.location }
            showMark(at: next ?? (marks.isEmpty ? nil : 0), in: host)
        } else {
            refreshSuggestions(in: host)
            refreshMarks(in: host)
        }
    }

    /// The mark under `point` (text view coordinates).
    func mark(at point: CGPoint, in host: any WritingPartnerHost) -> PartnerUncertainMark? {
        marks.first { mark in
            host.partnerRects(forRaw: mark.range)
                .contains { $0.insetBy(dx: -2, dy: -3).contains(point) }
        }
    }

    /// The caret moved: in a mark, its candidate is shown to settle on its own; out of it, hidden.
    private func caretMovedForMarks(in host: any WritingPartnerHost) {
        guard !marks.isEmpty, !isMovingCaretToMark, fixInFlight == nil else { return }
        let selection = host.partnerRawSelection
        let inside = selection.length == 0 ? PartnerMarks.index(at: selection.location, in: marks) : nil
        if let inside {
            if marks[inside].id != activeMarkID { showMark(at: inside, moveCaret: false, in: host) }
        } else if activeMarkID != nil {
            activeMarkID = nil
            isReviewing = false
            suggestions.removeAll { $0.markID != nil }
            refreshSuggestions(in: host)
            refreshMarks(in: host)
        }
    }

    private func announce(_ text: String, in host: any WritingPartnerHost) {
        lastAnnouncement = text
        host.partnerAnnounce(text)
    }

    // MARK: Suggestions (#103)

    /// Redraws active suggestion underlines on the host's canvas.
    func refreshSuggestions(in host: any WritingPartnerHost) {
        let overlay = host.partnerCanvas
        let rects = suggestions.flatMap {
            host.partnerRects(forRaw: $0.edit.range)
        }
        overlay?.showSuggestions(rects)
    }

    /// Removes all active suggestions without counting them against their rules.
    func clearSuggestions(in host: (any WritingPartnerHost)?) {
        guard !suggestions.isEmpty else { return }
        suggestions = []
        (host ?? currentHost)?.partnerCanvas?.showSuggestions([])
    }

    /// The suggestion drawn under `point` (text view coordinates), if any.
    func suggestion(at point: CGPoint, in host: any WritingPartnerHost) -> Suggestion? {
        suggestions.first { suggestion in
            return host.partnerRects(forRaw: suggestion.edit.range).contains { $0.insetBy(dx: -2, dy: -2).contains(point) }
        }
    }

    /// Suggestions that the current selection or caret is on or just after.
    func suggestionsForCaret(in host: any WritingPartnerHost) -> [Suggestion] {
        guard !suggestions.isEmpty else { return [] }
        let selection = host.partnerRawSelection
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
    func acceptSuggestion(at point: CGPoint, in host: any WritingPartnerHost) -> Bool {
        guard let chosen = suggestion(at: point, in: host) else { return false }
        return accept([chosen], in: host)
    }

    /// Accepts the suggestion(s) at or just before the caret (Tab or ⌥⏎).
    @discardableResult
    func acceptSuggestionAtCaret(in host: any WritingPartnerHost) -> Bool {
        let matching = suggestionsForCaret(in: host)
        guard !matching.isEmpty else { return false }
        return accept(matching, in: host)
    }

    /// Accepts the suggestion at the caret/selection, or the latest active suggestion (Edit menu / VoiceOver).
    @discardableResult
    func acceptSuggestion(in host: any WritingPartnerHost) -> Bool {
        let matching = suggestionsForCaret(in: host)
        let chosen = matching.isEmpty ? (suggestions.last.map { [$0] } ?? []) : matching
        guard !chosen.isEmpty else { return false }
        return accept(chosen, in: host)
    }

    private func accept(_ chosen: [Suggestion], in host: any WritingPartnerHost) -> Bool {
        guard !chosen.isEmpty, fixInFlight == nil else { return false }
        suggestions.removeAll { chosen.contains($0) }
        if let active = activeMarkID, chosen.contains(where: { $0.markID == active }) { activeMarkID = nil }
        refreshSuggestions(in: host)
        play(Fix(remaining: chosen.map(\.edit), boundaries: [], isRetry: false), in: host)
        return true
    }

    /// Dismisses the suggestion at the caret (or all active suggestions) and counts it against its rules.
    @discardableResult
    func dismissSuggestion(in host: any WritingPartnerHost) -> Bool {
        guard !suggestions.isEmpty else { return false }
        let matching = suggestionsForCaret(in: host)
        let toDismiss = matching.isEmpty ? suggestions : matching
        suggestions.removeAll { toDismiss.contains($0) }
        for item in toDismiss { penalize(item.edit, in: host) }
        refreshSuggestions(in: host)
        // Keeping a mark's text as written settles it, teaches the partner, and moves the review on
        for item in toDismiss { if let id = item.markID { keep(markID: id, alreadyPenalized: true, in: host) } }
        return true
    }

    // MARK: Playing a fix

    /// The director for `host`, made on first use and again if the editor changed.
    @MainActor
    private func director(for host: any WritingPartnerHost) -> (AgentTextDirector, WritingPartnerTarget) {
        if let director, let target, target.host === host { return (director, target) }
        let target = WritingPartnerTarget(host: host)
        let director = AgentTextDirector(target: target, linger: 300)
        let overlay = host.partnerCanvas
        overlay?.attach(carets: director.carets, target: target)
        target.onGhostChange = { [weak overlay] in overlay?.renderPartner() }
        target.onCommit = { [weak self] range, text, caret in self?.committed(range, text: text, caretBefore: caret) }
        self.director = director
        self.target = target
        return (director, target)
    }

    private func play(_ fix: Fix, in host: any WritingPartnerHost) {
        MainActor.assumeIsolated {
            let (director, target) = director(for: host)
            fixInFlight = fix
            currentHost = host
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
            guard WritingPartnerDefaults.mode(defaults) != .off, !isPaused, let host = target.host,
                  !host.partnerHasMarkedText, NSMaxRange(edit.range) <= text.length,
                  text.substring(with: edit.range) == edit.original else {
                retry(fix)
                return
            }
            pendingStep = edit
            let animate = !host.partnerReducesMotion && host.partnerIsOnScreen && !edit.playsInstantly
            let actionName = edit.actionName ?? WritingPartnerDefaults.actionName
            do {
                try await director.perform(AgentTextEdit(from: edit.range.location, to: NSMaxRange(edit.range), text: edit.replacement),
                                           by: Self.agent, actionName: actionName,
                                           options: AgentTypingOptions(selectMs: Self.selectMs, animate: animate))
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
        let closedSentence = pendingStep?.rules.contains(.terminalPunctuation) == true
        let rangeAfter = NSRange(location: range.location, length: (text as NSString).length)
        if let edit = pendingStep {
            let voice = currentHost.map { WritingPartnerVoice(flavor: $0.partnerFlavor) } ?? .punctuate
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
        if !marks.isEmpty, let host = currentHost {
            moveMarks(through: range, replacement: text, byPerson: false, in: host)
        }
        let move = { (location: Int) -> Int in location >= NSMaxRange(range) ? location + delta : location }
        pendingBoundaries = pendingBoundaries.map { (move($0.location), $0.enterEndedLine) }
        formattingDirty = Self.move(ranges: formattingDirty, through: range, replacement: text)
        // The edit goes on its layer (#229); the others move with it
        let layerCount = layers.edits.count
        if let edit = pendingStep {
            layers.recordPartnerEdit(replacing: range, original: edit.original, replacement: text,
                                     layer: edit.layer, rules: edit.rules)
        } else {
            layers.move(through: range, replacement: text)
        }
        if layers.edits.count != layerCount || pendingStep != nil { onLayersChange?() }
        if var fix = fixInFlight {
            fix.boundaries = fix.boundaries.map { (move($0.location), $0.enterEndedLine) }
            fix.remaining = fix.remaining.map { var edit = $0; edit.range.location = move(edit.range.location); return edit }
            fixInFlight = fix
        }
        // When the partner itself just closed a sentence, check any finished word immediately after it
        // so its first word gets a capital (#111).
        if closedSentence, let host = currentHost {
            let current = host.partnerRawText as NSString
            let selection = host.partnerRawSelection
            var scan = range.location + (text as NSString).length
            while scan < current.length, scan < selection.location {
                let c = current.character(at: scan)
                if c == 0x20 || c == 0x0A || c == 0x09 { scan += 1 } else { break }
            }
            if scan < current.length, scan < selection.location, PunctuateVoice.isWordCharacter(current.character(at: scan)) {
                var wordEnd = scan
                while wordEnd < current.length, PunctuateVoice.isWordCharacter(current.character(at: wordEnd)) {
                    wordEnd += 1
                }
                if wordEnd < current.length, wordEnd < selection.location,
                   (PunctuateVoice.isWordBoundary(current.character(at: wordEnd)) || current.character(at: wordEnd) == 0x0A),
                   !pendingBoundaries.contains(where: { $0.location == wordEnd }) {
                    pendingBoundaries.append((wordEnd, nil))
                }
            }
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
            if let host = currentHost { refreshSuggestions(in: host) }
        }
        if let host = currentHost, hasPauseProvider {
            let rawText = host.partnerRawText
            let rawSelection = host.partnerRawSelection
            if let current = BandleaderContextExtractor.extract(from: rawText, caret: rawSelection.location, flavor: host.partnerFlavor) {
                lastKnownParagraphRange = current.range
                lastKnownParagraphText = current.paragraph
                pauseDetector.updatePendingParagraph(current.paragraph, range: current.range, caret: rawSelection.location)
            }
        }
        observeUndo(currentHost?.partnerUndoManager)
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
              WritingPartnerDefaults.mode(defaults).isOn, !isPaused,
              let host = currentHost, !host.partnerHasMarkedText else {
            finish()
            return
        }
        pendingBoundaries = fix.boundaries + pendingBoundaries
        punctuate(in: host, isRetry: true)
        if fixInFlight == nil { finish() }
    }

    /// The fix is done: boundaries typed while it played get their turn.
    private func finish() {
        fixInFlight = nil
        player = nil
        if isReviewing, activeMarkID == nil, let host = currentHost {
            showMark(at: PartnerMarks.step(from: nil, by: 1, count: marks.count), in: host)
        }
        if let host = currentHost {
            if !pendingBoundaries.isEmpty {
                didChange(in: host)
            } else {
                scheduleTidy(in: host)
            }
        }
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

    /// `ranges` after `range` was replaced by `replacement`: later ones move, overlapping ones grow
    /// to cover what replaced them.
    static func move(ranges: [NSRange], through range: NSRange, replacement: String) -> [NSRange] {
        let length = (replacement as NSString).length
        let delta = length - range.length
        return ranges.map { r in
            if r.location >= NSMaxRange(range), range.length > 0 || r.location > range.location {
                return NSRange(location: r.location + delta, length: r.length)
            }
            if NSMaxRange(r) < range.location { return r }
            let start = min(r.location, range.location)
            let end = max(NSMaxRange(r) >= NSMaxRange(range) ? NSMaxRange(r) + delta : 0, range.location + length)
            return NSRange(location: start, length: max(0, end - start))
        }
    }

    // MARK: Undo & Learning

    /// Counts an undone or dismissed fix against its rules, tells the spell checker and session
    /// memory to leave any spelling words in it alone, and reports bandleader feedback (#120).
    private func penalize(_ edit: PartnerEdit, in host: (any WritingPartnerHost)?) {
        penalize(rules: edit.rules, spellingWords: edit.spellingWords, in: host)
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

    private func penalize(rules: [PunctuationRule], spellingWords: [String], in host: (any WritingPartnerHost)?) {
        var stats = WritingPartnerStats.load(defaults)
        for rule in rules where rule != .spelling { stats.undone(rule) }
        stats.save(defaults)
        sessionMemory.learnWords(spellingWords)
        (host ?? currentHost)?.partnerIgnoreSpelling(spellingWords)
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

    private func schedulePauseCheck(in host: any WritingPartnerHost) {
        pauseTask?.cancel()
        let delay = pauseDetector.pauseDelay
        pauseTask = Task { @MainActor [weak self, weak host] in
            do {
                try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            } catch {
                return
            }
            guard let self, let host else { return }
            self.evaluatePause(in: host)
        }
    }

    private func triggerImmediatePause(in host: any WritingPartnerHost) {
        pauseTask?.cancel()
        pauseTask = Task { @MainActor [weak self, weak host] in
            guard let self, let host else { return }
            self.evaluatePause(in: host)
        }
    }

    @MainActor
    private func evaluatePause(in host: any WritingPartnerHost) {
        pauseTask = nil
        guard WritingPartnerDefaults.mode(defaults) != .off, !isPaused, !hasActiveIntroduction else { return }
        let provider = WritingPartnerDefaults.provider(defaults)
        let override = testingBandleader ?? WritingBandleaderFactory.overrideBandleader
        guard override != nil || provider != .none else { return }

        guard let pause = pauseDetector.checkPause() else { return }
        let rawText = host.partnerRawText
        let detectedLanguage = GrammarLanguageSupport.detectLanguage(in: rawText)
        WritingPartnerActiveVoice.shared.documentLanguage = detectedLanguage
        guard let extracted = BandleaderContextExtractor.extract(from: rawText, caret: pause.caret, flavor: host.partnerFlavor) else { return }

        let stats = WritingPartnerStats.load(defaults)
        let spellingOn = WritingPartnerDefaults.spelling(defaults)
        let voices = [stats.toVoiceState(spellingOn: spellingOn)]
        let recentFeedback = sessionMemory.recordedFeedback.isEmpty ? nil : sessionMemory.recordedFeedback
        let request = JazzTextLeadRequest(
            paragraph: extracted.paragraph,
            before: extracted.before,
            after: extracted.after,
            flavor: host.partnerFlavor.jazzTextFlavor,
            voices: voices,
            language: detectedLanguage == .english ? nil : detectedLanguage.rawValue,
            feedback: recentFeedback,
            engagementMode: WritingPartnerDefaults.mode(defaults).engagementMode
        )

        leadTask?.cancel()
        leadTask = Task { @MainActor [weak self, weak host] in
            defer { self?.leadTask = nil }
            guard let self, let host else { return }
            guard let result = await WritingBandleaderFactory.leadWithFallback(
                request: request,
                provider: provider,
                override: override,
                existing: self.activeBandleader
            ) else {
                return
            }
            self.activeBandleader = result.bandleader
            self.applyBandleaderResponse(
                result.response,
                for: extracted.paragraph,
                paragraphRange: extracted.range,
                in: host
            )
        }
    }

    @MainActor
    private func applyBandleaderResponse(
        _ response: JazzTextLeadResponse,
        for paragraph: String,
        paragraphRange: NSRange,
        in host: any WritingPartnerHost
    ) {
        let mode = WritingPartnerDefaults.mode(defaults)
        guard mode != .off, !isPaused, !hasActiveIntroduction else { return }
        let spellingOn = WritingPartnerDefaults.spelling(defaults)
        let rawText = host.partnerRawText

        let plan = BandleaderSuggestionPlanner.plan(
            response: response,
            paragraph: paragraph,
            paragraphRange: paragraphRange,
            documentText: rawText,
            flavor: host.partnerFlavor,
            mode: mode,
            spellingEnabled: spellingOn,
            memory: sessionMemory
        )

        self.paragraphVoiceSettings = plan.voiceSettings

        // Register personal and team vocabulary words with the system spell checker so they are
        // neither flagged with red underlines nor "corrected" away in this document (#120).
        if !plan.vocabulary.isEmpty {
            host.partnerIgnoreSpelling(plan.vocabulary)
        }

        // Pause-tier grammar corrections (#111): above the threshold they play through the partner's
        // cursor, below it they're offered. A correction that overlaps one of the plan's is dropped.
        let selection = host.partnerRawSelection
        var grammarAutomatic: [PartnerEdit] = []
        var grammarOffered: [PartnerEdit] = []
        if !response.grammar.isEmpty {
            let flavor = host.partnerFlavor
            let stats = WritingPartnerStats.load(defaults, voice: WritingPartnerVoice(flavor: flavor))
            let isActive: (PunctuationRule) -> Bool = { [defaults = self.defaults] rule in
                WritingPartnerDefaults.isRuleEnabled(rule, defaults) && stats.isActive(rule)
            }
            let grammar = GrammarVoice.pauseEdits(
                from: response,
                paragraph: paragraph,
                paragraphRange: paragraphRange,
                documentText: rawText,
                caret: selection.location,
                flavor: flavor,
                provider: WritingPartnerDefaults.provider(defaults),
                mode: mode,
                languageOverride: WritingPartnerActiveVoice.shared.documentLanguage,
                isActive: isActive
            )
            let planned = plan.automaticEdits.map(\.range) + plan.offeredEdits.map(\.range)
            let isFree = { (edit: PartnerEdit) in planned.allSatisfy { NSIntersectionRange($0, edit.range).length == 0 } }
            grammarAutomatic = grammar.automatic.filter(isFree)
            grammarOffered = grammar.suggestions.filter(isFree)
        }
        let offeredEdits = (plan.offeredEdits + grammarOffered).sorted { $0.range.location < $1.range.location }
        let automaticEdits = (plan.automaticEdits + grammarAutomatic).sorted { $0.range.location < $1.range.location }

        // With Suggestions on, what the partner isn't sure about is marked, to settle later (#128,
        // #229); with it off, it's left alone.
        let marking = WritingPartnerDefaults.suggestions(defaults)
        if !automaticEdits.isEmpty, !marks.isEmpty {
            // The partner became sure: its fix replaces the mark
            marks.removeAll { mark in automaticEdits.contains { NSIntersectionRange($0.range, mark.range).length > 0 } }
            refreshMarks(in: host)
        }
        if !offeredEdits.isEmpty, marking {
            addMarks(offeredEdits, in: host)
        }

        // Apply high-confidence inline suggestions at once through the partner's cursor (#120).
        if !automaticEdits.isEmpty {
            if var inFlight = fixInFlight, !inFlight.isCancelled {
                inFlight.remaining.append(contentsOf: automaticEdits)
                fixInFlight = inFlight
            } else {
                play(Fix(remaining: automaticEdits, boundaries: [], isRetry: false), in: host)
            }
        }

        // Show a structural block suggestion prompt if present and no inline cursor edit is running.
        guard let suggestion = plan.structuralSuggestion else { return }

        // A structure change it isn't sure of is marked rather than prompted for (#128), or left
        // alone with Suggestions off (#229)
        if let confidence = suggestion.confidence, confidence < GrammarVoice.autoConfidenceThreshold {
            guard marking else { return }
            let local = NSRange(location: suggestion.range.start, length: max(0, suggestion.range.end - suggestion.range.start))
            let paragraphNS = paragraph as NSString
            if NSMaxRange(local) <= paragraphNS.length {
                let raw = NSRange(location: paragraphRange.location + local.location, length: local.length)
                let edit = PartnerEdit(range: raw, original: paragraphNS.substring(with: local), replacement: suggestion.replacement,
                                       rules: [], spellingWords: [], actionName: WritingPartnerDefaults.suggestionActionName,
                                       bandleaderSuggestionId: suggestion.effectiveId, bandleaderSuggestionKind: suggestion.kind,
                                       bandleaderCheckId: suggestion.checkId, confidence: confidence)
                addMarks([edit], in: host)
            }
            return
        }

        self.activeSuggestion = (suggestion: suggestion, paragraph: paragraph, paragraphRange: paragraphRange)

        // Ghostwrite (#229) rewrites in place: a change it is sure of is made, on its own layer
        if mode == .ghostwrite, suggestion.alternatives?.isEmpty ?? true {
            acceptActiveSuggestion(layer: .ghostwrite)
            return
        }
        // Copyedit makes no unsolicited rewrites: the change is only offered, with Suggestions on
        guard marking else {
            activeSuggestion = nil
            return
        }

        let rawStart = paragraphRange.location + suggestion.range.start
        let rawEnd = paragraphRange.location + suggestion.range.end
        let rects = host.partnerRects(forRaw: NSRange(location: rawStart, length: max(0, rawEnd - rawStart)))
        let targetRect = rects.last ?? host.partnerCaretRect(atRaw: rawStart) ?? CGRect(x: 20, y: 20, width: 100, height: 20)

        host.partnerCanvas?.showSuggestionPrompt(
            suggestion: suggestion,
            at: targetRect,
            onAccept: { [weak self] in self?.acceptActiveSuggestion() },
            onDismiss: { [weak self] in self?.dismissActiveSuggestion() }
        )
    }

    // MARK: - Edit Layers (#229)

    /// The layers as they stand in `host`'s text now: edits whose text changed out of sight leave.
    func currentLayers(in host: any WritingPartnerHost) -> EditLayerStack {
        layers.validate(against: host.partnerRawText as NSString)
        return layers
    }

    /// Reverts every intact edit on `layer`, as one undo step, leaving the person's typing alone.
    @discardableResult
    func revertLayer(_ layer: PartnerEditLayer, in host: any WritingPartnerHost) -> Int {
        revertEdits(layers.ids(on: layer), in: host)
    }

    /// Reverts the partner's edits `ids` (as one undo step), putting back what was there before
    /// each, and counts it against their rules like an undo. Returns how many were reverted.
    @discardableResult
    func revertEdits(_ ids: Set<Int>, in host: any WritingPartnerHost) -> Int {
        let text = host.partnerRawText as NSString
        layers.validate(against: text)
        let changes = layers.reverts(for: ids, in: text)
        guard !changes.isEmpty, host.partnerCanEdit, !host.partnerHasMarkedText else {
            onLayersChange?()
            return 0
        }
        cancelFix()
        let reverted = layers.edits.filter { ids.contains($0.id) }
        let selection = host.partnerRawSelection
        let result = EditLayerStack.apply(changes, to: text, caret: selection.location)
        layers.remove(ids)
        for change in changes {
            layers.move(through: change.range, replacement: change.replacement)
            if !marks.isEmpty { moveMarks(through: change.range, replacement: change.replacement, byPerson: false, in: host) }
            formattingDirty = Self.move(ranges: formattingDirty, through: change.range, replacement: change.replacement)
        }
        let rules = reverted.flatMap(\.rules)
        if !rules.isEmpty {
            let voice = WritingPartnerVoice(flavor: host.partnerFlavor)
            var stats = WritingPartnerStats.load(defaults, voice: voice)
            for rule in rules where rule != .spelling { stats.undone(rule) }
            stats.save(defaults, voice: voice)
        }
        let layersReverted = Set(reverted.map(\.layer))
        let actionName = layersReverted.count == 1 ? layersReverted.first!.revertActionName : "Revert Partner Edits"
        host.applyPartnerEdit(newRawText: result.text, rawSelection: NSRange(location: result.caret, length: 0),
                              actionName: actionName)
        onLayersChange?()
        let count = changes.count
        host.partnerAnnounce(count == 1 ? "Reverted 1 edit" : "Reverted \(count) edits")
        return count
    }

    /// A different document in this editor: the layers and the bandleader session belong to the old one.
    func documentDidChange() {
        resetBandleaderSession()
        layers.removeAll()
        onLayersChange?()
    }

    // MARK: - Testing Helpers

    /// Resets the current active bandleader's session and clears the active bandleader reference.
    func resetBandleaderSession() {
        activeBandleader?.resetSession()
        activeBandleader = nil
    }

    var activeBandleaderForTesting: (any WritingBandleader)? {
        activeBandleader
    }

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
    func triggerPauseCheckForTesting(in host: any WritingPartnerHost) {
        evaluatePause(in: host)
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
                || redoName == WritingPartnerDefaults.formattingActionName
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
        currentHost?.partnerIgnoreSpelling(step.spellingWords)
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
        // First time a fix is undone (#112): show a quiet reminder explaining how to pause for this
        // document or turn the partner off in Settings › Writing.
        if !WritingPartnerDefaults.undoReminderShown(defaults) {
            WritingPartnerDefaults.setUndoReminderShown(true, defaults)
            hasActiveUndoReminder = true
            if let host = currentHost {
                let announcement = host.partnerUndoReminderText
                lastAnnouncement = announcement
                let rawLength = (host.partnerRawText as NSString).length
                let targetRect = host.partnerCaretRect(atRaw: min(step.caretBefore, rawLength))
                    ?? CGRect(x: 0, y: 0, width: 2, height: 20)
                host.partnerCanvas?.showUndoReminder(
                    at: targetRect,
                    text: announcement,
                    onPause: { [weak self, weak host] in
                        guard let self else { return }
                        self.dismissUndoReminder(in: host)
                        self.setPaused(true, in: host)
                    },
                    onDismiss: { [weak self, weak host] in
                        self?.dismissUndoReminder(in: host)
                    }
                )
                host.partnerAnnounce(announcement)
            }
        }
        // Undo selects the restored word; put the caret back where the person was typing, after
        // the editor has restyled the change
        let caret = step.caretBefore
        DispatchQueue.main.async { [weak self] in
            guard let self, let host = self.currentHost else { return }
            let length = (host.partnerRawText as NSString).length
            host.setPartnerRawSelection(NSRange(location: min(caret, length), length: 0), scrollToVisible: false)
        }
    }
}

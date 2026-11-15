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
import PixerateCore
import PixerateMarkdown

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
        } else if selection.location > real.location {
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

    private struct Step {
        var rules: [PunctuationRule]
        var spellingWords: [String]
        /// Where the person's caret was (raw) before it, to put it back if it's undone.
        var caretBefore: Int
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
    var isIdle: Bool { fixInFlight == nil && pendingBoundaries.isEmpty && !isScheduled }

    /// The person is about to type `string` over `range` (storage offsets). Call only for their own
    /// typing: not for Swash's edits, restyling, SwiftUI updates or Writing Tools.
    func willType(_ string: String?, in range: NSRange, textView: NSTextView, coordinator: SwashTextView.Coordinator) {
        if let undoManager = textView.undoManager, undoManager.isUndoing || undoManager.isRedoing {
            pendingBoundaries = []
            cancelFix()
            return
        }
        let raw = coordinator.rawRange(forStorage: range, in: textView)
        let replacement = string ?? ""
        if fixInFlight != nil { MainActor.assumeIsolated { personWillEdit(raw, replacement: replacement) } }
        if !applied.isEmpty {
            // Typing on after a fix keeps it
            var stats = WritingPartnerStats.load(defaults)
            for step in applied { for rule in step.rules { stats.kept(rule) } }
            stats.save(defaults)
            applied = []
        }
        let isOn = WritingPartnerDefaults.mode(defaults) == .automatic
        if !isOn { cancelFix() }
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
        guard isOn, let string, (string as NSString).length == 1, range.length == 0,
              textView.selectedRange().length == 0, !textView.hasMarkedText() else {
            // Anything else (a paste, a deletion, macOS's text replacement) moves the text under the
            // pending offsets: move them with it, and drop any it replaced
            pendingBoundaries = Self.move(pendingBoundaries, through: raw, replacement: replacement)
            return
        }
        let c = (string as NSString).character(at: 0)
        guard PunctuateVoice.isWordBoundary(c) || c == 0x0A else { return }
        var enterEndedLine: Bool?
        if c == 0x0A {
            let text = coordinator.rawText(of: textView) as NSString
            enterEndedLine = raw.location >= text.length || text.character(at: raw.location) == 0x0A
        }
        pendingBoundaries.append((raw.location, enterEndedLine))
    }

    /// The person's change landed. Fixes run on the next turn of the run loop, after the editor has
    /// published and styled the change, and one at a time: while the partner's cursor is playing a
    /// fix, new boundaries wait for it.
    func didChange(in textView: NSTextView, coordinator: SwashTextView.Coordinator) {
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
        guard WritingPartnerDefaults.mode(defaults) == .automatic, !textView.hasMarkedText(),
              textView.window != nil, textView.isEditable else { return }
        let raw = coordinator.rawText(of: textView)
        let selection = coordinator.rawRange(forStorage: textView.selectedRange(), in: textView)
        guard selection.length == 0 else { return }
        let stats = WritingPartnerStats.load(defaults)
        let spellingOn = WritingPartnerDefaults.spelling(defaults)
        let isActive: (PunctuationRule) -> Bool = { $0 == .spelling ? spellingOn : stats.isActive($0) }
        let checker = NSSpellChecker.shared
        let tag = textView.spellCheckerDocumentTag
        let spellingCorrection: (String, NSRange, String) -> String? = { _, range, text in
            checker.correction(forWordRange: range, in: text, language: checker.language(), inSpellDocumentWithTag: tag)
        }
        let flavor = coordinator.parent.flavor
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
            let text = working as String
            let document = working == raw as NSString ? coordinator.formatting(for: text).document : MarkdownDocument.parse(text, flavor: flavor)
            if shift == 0, let range = PunctuateVoice.checkedRange(text: text, boundary: boundary, document: document) {
                checked.append(range)
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
        overlay.sweep(checked.flatMap { WritingPartnerOverlay.rects(for: coordinator.storageRange(forRaw: $0, in: textView), in: textView) })
        let edits = PunctuateVoice.partnerEdits(from: raw as NSString, to: working, marks: marks)
        guard !edits.isEmpty else { return }
        play(Fix(remaining: edits, boundaries: boundaries, isRetry: isRetry), in: textView, coordinator: coordinator)
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
            guard WritingPartnerDefaults.mode(defaults) == .automatic, let textView = target.textView,
                  !textView.hasMarkedText(), NSMaxRange(edit.range) <= text.length,
                  text.substring(with: edit.range) == edit.original else {
                retry(fix)
                return
            }
            pendingStep = edit
            let animate = !WritingPartnerOverlay.reduceMotion && textView.window != nil
            do {
                try await director.perform(AgentTextEdit(from: edit.range.location, to: NSMaxRange(edit.range), text: edit.replacement),
                                           by: Self.agent, actionName: WritingPartnerDefaults.actionName,
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
        if let edit = pendingStep {
            applied.append(Step(rules: edit.rules, spellingWords: edit.spellingWords, caretBefore: caretBefore))
        }
        let move = { (location: Int) -> Int in location >= NSMaxRange(range) ? location + delta : location }
        pendingBoundaries = pendingBoundaries.map { (move($0.location), $0.enterEndedLine) }
        if var fix = fixInFlight {
            fix.boundaries = fix.boundaries.map { (move($0.location), $0.enterEndedLine) }
            fix.remaining = fix.remaining.map { var edit = $0; edit.range.location = move(edit.range.location); return edit }
            fixInFlight = fix
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
        guard !fix.isCancelled, !fix.isRetry, WritingPartnerDefaults.mode(defaults) == .automatic,
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

    // MARK: Undo

    /// Undoing the partner's step straight away counts against its rules.
    private func observeUndo(_ undoManager: UndoManager?) {
        guard let undoManager, undoManager !== observedUndoManager else { return }
        if let undoObserver { NotificationCenter.default.removeObserver(undoObserver) }
        observedUndoManager = undoManager
        undoObserver = NotificationCenter.default.addObserver(
            forName: .NSUndoManagerDidUndoChange, object: undoManager, queue: .main
        ) { [weak self] notification in
            let isPartnerStep = (notification.object as? UndoManager)?.redoActionName == WritingPartnerDefaults.actionName
            self?.didUndo(isPartnerStep: isPartnerStep)
        }
    }

    private func didUndo(isPartnerStep: Bool) {
        guard isPartnerStep, let step = applied.popLast() else { return }
        // Undoing a spelling fix says the word is right: the spell checker leaves it alone in this
        // document. Other rules learn to fix less.
        var stats = WritingPartnerStats.load(defaults)
        for rule in step.rules where rule != .spelling { stats.undone(rule) }
        stats.save(defaults)
        if let textView {
            let tag = textView.spellCheckerDocumentTag
            for word in step.spellingWords { NSSpellChecker.shared.ignoreWord(word, inSpellDocumentWithTag: tag) }
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

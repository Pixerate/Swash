//
//  WritingPartnerSession.swift
//  Swash
//
//  Connects the writing partner's Punctuate voice (WritingPartner.swift, #61) to the Mac editor.
//  When the person types a space, punctuation or a blank line, the session asks the voice for
//  fixes to what they just finished and applies them as their own undo step ("Undo Punctuation").
//  Undoing that step straight away counts against the rules it applied; typing on keeps it.
//

#if os(macOS)
import AppKit
import PixerateMarkdown

final class WritingPartnerSession {
    /// Word boundaries the person typed (raw-Markdown offsets) that haven't been looked at yet. More
    /// than one when they type faster than the run loop turns.
    /// `enterEndedLine` records whether an Enter was at the end of its line when it was pressed:
    /// by the time it's looked at, the person may have typed the next line.
    private var pendingBoundaries: [(location: Int, enterEndedLine: Bool?)] = []
    private var isScheduled = false
    /// The rules of the last fix, until the person types on (kept) or undoes it (undone).
    private var lastApplied: [PunctuationRule] = []
    /// The misspellings the last fix corrected: undoing it tells the spell checker they're words.
    private var lastSpellingWords: [String] = []
    /// The text view's own autocorrect, saved while the partner has it off.
    private var savedAutocorrect: Bool?
    /// Where the caret was (raw offset) before the last fix, to put it back if the fix is undone.
    private var caretBeforeFix: Int?
    private weak var textView: NSTextView?
    private weak var coordinator: SwashTextView.Coordinator?
    private var undoObserver: NSObjectProtocol?
    private weak var observedUndoManager: UndoManager?
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    deinit {
        if let undoObserver { NotificationCenter.default.removeObserver(undoObserver) }
    }

    /// The person is about to type `string` over `range` (storage offsets). Call only for their own
    /// typing: not for Swash's edits, restyling, SwiftUI updates or Writing Tools.
    func willType(_ string: String?, in range: NSRange, textView: NSTextView, coordinator: SwashTextView.Coordinator) {
        if let undoManager = textView.undoManager, undoManager.isUndoing || undoManager.isRedoing {
            pendingBoundaries = []
            return
        }
        if !lastApplied.isEmpty {
            // Typing on after a fix keeps it
            var stats = WritingPartnerStats.load(defaults)
            for rule in lastApplied { stats.kept(rule) }
            stats.save(defaults)
            lastApplied = []
            lastSpellingWords = []
        }
        let isOn = WritingPartnerDefaults.mode(defaults) == .automatic
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
            let raw = coordinator.rawRange(forStorage: range, in: textView)
            let delta = ((string ?? "") as NSString).length - raw.length
            let move = { (location: Int) -> Int? in
                if location >= NSMaxRange(raw) { return location + delta }
                return location < raw.location ? location : nil
            }
            pendingBoundaries = pendingBoundaries.compactMap { pending in move(pending.location).map { ($0, pending.enterEndedLine) } }
            if fixInFlight != nil { changesSinceFix.append((raw, delta)) }
            return
        }
        let c = (string as NSString).character(at: 0)
        guard PunctuateVoice.isWordBoundary(c) || c == 0x0A else { return }
        let location = coordinator.rawRange(forStorage: range, in: textView).location
        var enterEndedLine: Bool?
        if c == 0x0A {
            let raw = coordinator.rawText(of: textView) as NSString
            enterEndedLine = location >= raw.length || raw.character(at: location) == 0x0A
        }
        pendingBoundaries.append((location, enterEndedLine))
    }

    /// The person's change landed. Fixes run on the next turn of the run loop, after the editor has
    /// published and styled the change, and one at a time: while the partner's cursor is on its way
    /// to a fix, new boundaries wait for it.
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

    /// A fix the partner's cursor is selecting, applied when it gets there.
    private struct Fix {
        /// The raw Markdown and caret it was worked out on.
        var raw: String
        var caret: Int
        /// The fixed text, and where the fixes are in the raw text (before) and the fixed text (after).
        var fixed: String
        var before: [NSRange]
        var after: [NSRange]
        var rules: [PunctuationRule]
        var spellingWords: [String]
        /// The boundaries it was worked out for, to work it out again if macOS changed the text first.
        var boundaries: [(location: Int, enterEndedLine: Bool?)]
        var isRetry: Bool
    }

    private var fixInFlight: Fix?
    /// Changes that weren't the person's typing (macOS's text replacement, say) while a fix was on
    /// its way: (raw range replaced, change in length).
    private var changesSinceFix: [(range: NSRange, delta: Int)] = []

    private func punctuate(in textView: NSTextView, coordinator: SwashTextView.Coordinator, isRetry: Bool = false) {
        let boundaries = pendingBoundaries
        pendingBoundaries = []
        guard WritingPartnerDefaults.mode(defaults) == .automatic, !textView.hasMarkedText(),
              textView.window != nil, textView.isEditable else { return }
        let raw = coordinator.rawText(of: textView)
        let selection = coordinator.rawRange(forStorage: textView.selectedRange(), in: textView)
        guard selection.length == 0 else { return }
        let stats = WritingPartnerStats.load(defaults)
        let spellingOn = WritingPartnerDefaults.spelling(defaults, systemDefault: NSSpellChecker.isAutomaticSpellingCorrectionEnabled)
        let isActive: (PunctuationRule) -> Bool = { $0 == .spelling ? spellingOn : stats.isActive($0) }
        let checker = NSSpellChecker.shared
        let tag = textView.spellCheckerDocumentTag
        let spellingCorrection: (String, NSRange, String) -> String? = { _, range, text in
            checker.correction(forWordRange: range, in: text, language: checker.language(), inSpellDocumentWithTag: tag)
        }
        let flavor = coordinator.parent.flavor
        let overlay = WritingPartnerOverlay.overlay(for: textView)
        var spellingWords: [String] = []

        // Each boundary in order, on the text as the earlier ones left it
        var working = raw as NSString
        var caret = selection.location
        var shift = 0
        var rules: [PunctuationRule] = []
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
                if edit.rules.contains(.spelling) { spellingWords.append(working.substring(with: edit.range)) }
                working = working.replacingCharacters(in: edit.range, with: edit.replacement) as NSString
                let delta = (edit.replacement as NSString).length - edit.range.length
                if edit.range.location < caret { caret += delta }
                if edit.range.location <= boundary { shift += delta }
                rules += edit.rules
            }
        }
        overlay.sweep(checked.flatMap { WritingPartnerOverlay.rects(for: coordinator.storageRange(forRaw: $0, in: textView), in: textView) })
        guard !rules.isEmpty else { return }

        let (changedBefore, changedAfter) = Self.changedRanges(from: raw as NSString, to: working)
        // The partner selects whole words, as a person would before retyping one
        let before = changedBefore.map { Self.word(around: $0, in: raw as NSString) }
        let after = changedAfter.map { Self.word(around: $0, in: working) }
        let fix = Fix(raw: raw, caret: selection.location, fixed: working as String, before: before, after: after, rules: rules,
                      spellingWords: spellingWords, boundaries: boundaries, isRetry: isRetry)
        fixInFlight = fix
        changesSinceFix = []
        overlay.select(before.map { coordinator.storageRange(forRaw: $0, in: textView) }, in: textView)
        let apply = { [weak self, weak textView, weak coordinator] in
            guard let self else { return }
            self.fixInFlight = nil
            guard let textView, let coordinator else { return }
            self.apply(fix, in: textView, coordinator: coordinator, overlay: overlay)
            // Boundaries typed while the cursor was on its way
            if !self.pendingBoundaries.isEmpty { self.didChange(in: textView, coordinator: coordinator) }
        }
        let delay = WritingPartnerOverlay.selectDuration
        if delay > 0 {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: apply)
        } else {
            apply()
        }
    }

    /// Applies `fix` if the text up to the caret it was worked out at hasn't changed since: the person
    /// may have typed on after the caret, which is kept.
    private func apply(_ fix: Fix, in textView: NSTextView, coordinator: SwashTextView.Coordinator, overlay: WritingPartnerOverlay) {
        let current = coordinator.rawText(of: textView) as NSString
        let raw = fix.raw as NSString
        let selection = coordinator.rawRange(forStorage: textView.selectedRange(), in: textView)
        guard WritingPartnerDefaults.mode(defaults) == .automatic, !textView.hasMarkedText(),
              current.length >= fix.caret, selection.length == 0, selection.location >= fix.caret,
              current.substring(to: fix.caret) == raw.substring(to: fix.caret) else {
            // macOS may have changed the word first (text replacement turns "teh" into "the" while
            // the cursor is on its way): work the fix out again, once, on the text as it is now
            if !fix.isRetry, WritingPartnerDefaults.mode(defaults) == .automatic, selection.length == 0, !textView.hasMarkedText() {
                var moved = fix.boundaries
                for change in changesSinceFix {
                    moved = moved.compactMap { pending in
                        if pending.location >= NSMaxRange(change.range) { return (pending.location + change.delta, pending.enterEndedLine) }
                        return pending.location < change.range.location ? pending : nil
                    }
                }
                changesSinceFix = []
                pendingBoundaries = moved + pendingBoundaries
                overlay.cancel()
                punctuate(in: textView, coordinator: coordinator, isRetry: true)
                return
            }
            overlay.cancel()
            return
        }
        let fixed = fix.fixed as NSString
        let delta = fixed.length - raw.length
        let newText = fixed.substring(to: fix.caret + delta) + current.substring(from: fix.caret)
        let newCaret = selection.location + delta

        textView.breakUndoCoalescing()
        coordinator.applyEdit(in: textView, newRawText: newText, rawSelection: NSRange(location: newCaret, length: 0),
                              actionName: WritingPartnerDefaults.actionName)
        textView.breakUndoCoalescing()
        // Boundaries typed after the caret moved with the fix
        pendingBoundaries = pendingBoundaries.map { ($0.location >= fix.caret ? $0.location + delta : $0.location, $0.enterEndedLine) }
        lastApplied = fix.rules
        lastSpellingWords = fix.spellingWords
        caretBeforeFix = selection.location
        self.textView = textView
        self.coordinator = coordinator
        observeUndo(textView.undoManager)
        // Show where the fix landed once the editor has restyled it
        DispatchQueue.main.async { [weak textView, weak coordinator] in
            guard let textView, let coordinator else { return }
            overlay.landed(fix.after.map { coordinator.storageRange(forRaw: $0, in: textView) }, in: textView)
        }
    }

    /// `range` widened to the whole words it touches (a full stop added after a word takes the word).
    static func word(around range: NSRange, in text: NSString) -> NSRange {
        var start = range.location
        var end = NSMaxRange(range)
        while start > 0, PunctuateVoice.isWordCharacter(text.character(at: start - 1)) { start -= 1 }
        while end < text.length, PunctuateVoice.isWordCharacter(text.character(at: end)) { end += 1 }
        return NSRange(location: start, length: end - start)
    }

    /// Where `new` differs from `old`: each run of changed characters, as ranges in both.
    static func changedRanges(from old: NSString, to new: NSString) -> (before: [NSRange], after: [NSRange]) {
        // Trim the common prefix and suffix, then diff what's left character by character
        let limit = min(old.length, new.length)
        var prefix = 0
        while prefix < limit, old.character(at: prefix) == new.character(at: prefix) { prefix += 1 }
        var suffix = 0
        while suffix < limit - prefix, old.character(at: old.length - 1 - suffix) == new.character(at: new.length - 1 - suffix) { suffix += 1 }
        let oldMiddle = (0..<(old.length - prefix - suffix)).map { old.character(at: prefix + $0) }
        let newMiddle = (0..<(new.length - prefix - suffix)).map { new.character(at: prefix + $0) }
        let difference = newMiddle.difference(from: oldMiddle)
        var removed = IndexSet()
        var inserted = IndexSet()
        for change in difference {
            switch change {
            case .remove(let offset, _, _): removed.insert(offset)
            case .insert(let offset, _, _): inserted.insert(offset)
            }
        }
        // Pair each run of changes in the old text with the run at the same place in the new one
        var before: [NSRange] = []
        var after: [NSRange] = []
        var oldIndex = 0
        var newIndex = 0
        while oldIndex < oldMiddle.count || newIndex < newMiddle.count {
            if !removed.contains(oldIndex) && !inserted.contains(newIndex), oldIndex < oldMiddle.count, newIndex < newMiddle.count {
                oldIndex += 1
                newIndex += 1
                continue
            }
            let oldStart = oldIndex
            let newStart = newIndex
            while removed.contains(oldIndex) { oldIndex += 1 }
            while inserted.contains(newIndex) { newIndex += 1 }
            if oldIndex == oldStart && newIndex == newStart { break }
            before.append(NSRange(location: prefix + oldStart, length: oldIndex - oldStart))
            after.append(NSRange(location: prefix + newStart, length: newIndex - newStart))
        }
        return (before, after)
    }

    /// Undoing the partner's step straight away counts against its rules.
    private func observeUndo(_ undoManager: UndoManager?) {
        guard let undoManager, undoManager !== observedUndoManager else { return }
        if let undoObserver { NotificationCenter.default.removeObserver(undoObserver) }
        observedUndoManager = undoManager
        undoObserver = NotificationCenter.default.addObserver(
            forName: .NSUndoManagerDidUndoChange, object: undoManager, queue: .main
        ) { [weak self] notification in
            guard let self, !self.lastApplied.isEmpty,
                  (notification.object as? UndoManager)?.redoActionName == WritingPartnerDefaults.actionName else { return }
            // Undoing a spelling fix says the word is right: the spell checker leaves it alone in this
            // document. Other rules learn to fix less.
            var stats = WritingPartnerStats.load(self.defaults)
            for rule in self.lastApplied where rule != .spelling { stats.undone(rule) }
            stats.save(self.defaults)
            if let textView = self.textView {
                let tag = textView.spellCheckerDocumentTag
                for word in self.lastSpellingWords { NSSpellChecker.shared.ignoreWord(word, inSpellDocumentWithTag: tag) }
            }
            self.lastApplied = []
            self.lastSpellingWords = []
            // Undo selects the restored word; put the caret back where the person was typing, after
            // the editor has restyled the change
            guard let caret = self.caretBeforeFix else { return }
            self.caretBeforeFix = nil
            DispatchQueue.main.async { [weak self] in
                guard let self, let textView = self.textView, let coordinator = self.coordinator else { return }
                let length = (coordinator.rawText(of: textView) as NSString).length
                let raw = NSRange(location: min(caret, length), length: 0)
                textView.setSelectedRange(coordinator.storageRange(forRaw: raw, in: textView))
            }
        }
    }
}
#endif

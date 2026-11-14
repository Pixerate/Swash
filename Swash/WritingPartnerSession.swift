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
        }
        let isOn = WritingPartnerDefaults.mode(defaults) == .automatic
        // macOS's inline predictions also write at the caret; the two together corrupt words
        let predictions: NSTextInputTraitType = isOn ? .no : .default
        if textView.inlinePredictionType != predictions { textView.inlinePredictionType = predictions }
        guard isOn, let string, (string as NSString).length == 1, range.length == 0,
              textView.selectedRange().length == 0, !textView.hasMarkedText() else {
            // Anything but a typed character (a paste, a deletion) moves text under the pending offsets
            pendingBoundaries = []
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
    /// published and styled the change.
    func didChange(in textView: NSTextView, coordinator: SwashTextView.Coordinator) {
        guard !pendingBoundaries.isEmpty, !isScheduled else { return }
        isScheduled = true
        DispatchQueue.main.async { [weak self, weak textView, weak coordinator] in
            guard let self else { return }
            self.isScheduled = false
            guard let textView, let coordinator else { self.pendingBoundaries = []; return }
            self.punctuate(in: textView, coordinator: coordinator)
        }
    }

    private func punctuate(in textView: NSTextView, coordinator: SwashTextView.Coordinator) {
        let boundaries = pendingBoundaries
        pendingBoundaries = []
        guard WritingPartnerDefaults.mode(defaults) == .automatic, !textView.hasMarkedText(),
              textView.window != nil, textView.isEditable else { return }
        let raw = coordinator.rawText(of: textView)
        let selection = coordinator.rawRange(forStorage: textView.selectedRange(), in: textView)
        guard selection.length == 0 else { return }
        let stats = WritingPartnerStats.load(defaults)
        let flavor = coordinator.parent.flavor

        // Each boundary in order, on the text as the earlier ones left it
        var working = raw as NSString
        var caret = selection.location
        var shift = 0
        var rules: [PunctuationRule] = []
        for pending in boundaries.sorted(by: { $0.location < $1.location }) {
            let boundary = pending.location + shift
            guard boundary >= 0, boundary < working.length, boundary < caret else { continue }
            let c = working.character(at: boundary)
            guard PunctuateVoice.isWordBoundary(c) || c == 0x0A else { continue }
            let text = working as String
            let document = working == raw as NSString ? coordinator.formatting(for: text).document : MarkdownDocument.parse(text, flavor: flavor)
            let edits = PunctuateVoice.edits(text: text, boundary: boundary, document: document, flavor: flavor,
                                             enterEndedLine: pending.enterEndedLine, isActive: stats.isActive)
            for edit in edits.sorted(by: { $0.range.location > $1.range.location }) {
                working = working.replacingCharacters(in: edit.range, with: edit.replacement) as NSString
                let delta = (edit.replacement as NSString).length - edit.range.length
                if edit.range.location < caret { caret += delta }
                if edit.range.location <= boundary { shift += delta }
                rules += edit.rules
            }
        }
        guard !rules.isEmpty else { return }

        textView.breakUndoCoalescing()
        coordinator.applyEdit(in: textView, newRawText: working as String, rawSelection: NSRange(location: caret, length: 0),
                              actionName: WritingPartnerDefaults.actionName)
        textView.breakUndoCoalescing()
        lastApplied = rules
        caretBeforeFix = selection.location
        self.textView = textView
        self.coordinator = coordinator
        observeUndo(textView.undoManager)
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
            var stats = WritingPartnerStats.load(self.defaults)
            for rule in self.lastApplied { stats.undone(rule) }
            stats.save(self.defaults)
            self.lastApplied = []
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

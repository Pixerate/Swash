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
    /// The person just typed a word boundary; look at what they finished once the change lands.
    private var pendingBoundary = false
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
    func willType(_ string: String?, in range: NSRange, textView: NSTextView) {
        pendingBoundary = false
        if let undoManager = textView.undoManager, undoManager.isUndoing || undoManager.isRedoing { return }
        if !lastApplied.isEmpty {
            // Typing on after a fix keeps it
            var stats = WritingPartnerStats.load(defaults)
            for rule in lastApplied { stats.kept(rule) }
            stats.save(defaults)
            lastApplied = []
        }
        guard WritingPartnerDefaults.mode(defaults) == .automatic,
              let string, (string as NSString).length == 1, range.length == 0,
              textView.selectedRange().length == 0, !textView.hasMarkedText() else { return }
        let c = (string as NSString).character(at: 0)
        pendingBoundary = PunctuateVoice.isWordBoundary(c) || c == 0x0A
    }

    /// The person's change landed. Fixes run on the next turn of the run loop, after the editor has
    /// published and styled the change.
    func didChange(in textView: NSTextView, coordinator: SwashTextView.Coordinator) {
        guard pendingBoundary else { return }
        pendingBoundary = false
        DispatchQueue.main.async { [weak self, weak textView, weak coordinator] in
            guard let self, let textView, let coordinator else { return }
            self.punctuate(in: textView, coordinator: coordinator)
        }
    }

    private func punctuate(in textView: NSTextView, coordinator: SwashTextView.Coordinator) {
        guard WritingPartnerDefaults.mode(defaults) == .automatic, !textView.hasMarkedText(),
              textView.window != nil, textView.isEditable else { return }
        let raw = coordinator.rawText(of: textView)
        let selection = coordinator.rawRange(forStorage: textView.selectedRange(), in: textView)
        guard selection.length == 0, selection.location > 0 else { return }
        let stats = WritingPartnerStats.load(defaults)
        let document = coordinator.formatting(for: raw).document
        let edits = PunctuateVoice.edits(
            text: raw,
            boundary: selection.location - 1,
            document: document,
            flavor: coordinator.parent.flavor,
            isActive: stats.isActive
        )
        guard !edits.isEmpty else { return }

        var updated = raw as NSString
        var caret = selection.location
        for edit in edits.sorted(by: { $0.range.location > $1.range.location }) {
            updated = updated.replacingCharacters(in: edit.range, with: edit.replacement) as NSString
            if edit.range.location < caret {
                caret += (edit.replacement as NSString).length - edit.range.length
            }
        }
        textView.breakUndoCoalescing()
        coordinator.applyEdit(in: textView, newRawText: updated as String, rawSelection: NSRange(location: caret, length: 0),
                              actionName: WritingPartnerDefaults.actionName)
        textView.breakUndoCoalescing()
        lastApplied = edits.flatMap(\.rules)
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

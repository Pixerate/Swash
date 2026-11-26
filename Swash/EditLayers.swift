//
//  EditLayers.swift
//  Swash
//
//  Session-scoped edit layers (#229). What the writing partner changes is kept, for as long as the
//  editor is open, apart from what the person typed: a Copyedit layer (punctuation, spelling,
//  grammar, formatting) and a Ghostwrite layer (prose the bandleader rewrote in place). Each of the
//  partner's edits, or a whole layer, can be inspected and reverted without undoing anything typed
//  since. Nothing here is saved: the `.md` file is always the flattened text.
//
//  Foundation only, so the writing partner's test runner can compile it.
//

import Foundation

/// Who made a change (#229). The person's typing is the `user` layer; it isn't recorded edit by
/// edit, it's simply everything the other layers aren't.
nonisolated enum PartnerEditLayer: String, CaseIterable, Identifiable, Sendable {
    case user
    case copyedit
    case ghostwrite

    var id: String { rawValue }

    var title: String {
        switch self {
        case .user: return "You"
        case .copyedit: return "Copyedit"
        case .ghostwrite: return "Ghostwrite"
        }
    }

    /// The undo action name of reverting edits on this layer.
    var revertActionName: String { "Revert \(title)" }

    /// The layers the partner writes on, in the order they're listed.
    static let partnerLayers: [PartnerEditLayer] = [.copyedit, .ghostwrite]
}

/// One edit the partner made, as it stands in the text now.
nonisolated struct LayeredEdit: Identifiable, Equatable, Sendable {
    let id: Int
    let layer: PartnerEditLayer
    /// Where the partner's text (`replacement`) is now, in raw Markdown.
    var range: NSRange
    /// What was there before the partner changed it.
    let original: String
    /// What the partner wrote.
    let replacement: String
    /// The rules that made it, so reverting it counts against them like an undo.
    let rules: [PunctuationRule]
}

/// A change to the raw Markdown: replace `range` with `replacement`.
nonisolated struct EditLayerChange: Equatable, Sendable {
    var range: NSRange
    var replacement: String
}

/// The partner's edits this session, on their layers, kept in step with the text.
nonisolated struct EditLayerStack: Equatable, Sendable {
    private(set) var edits: [LayeredEdit] = []
    private var nextID = 1

    var isEmpty: Bool { edits.isEmpty }

    func edits(on layer: PartnerEditLayer) -> [LayeredEdit] {
        edits.filter { $0.layer == layer }
    }

    /// Records an edit the partner is making: `range` held `original` and now holds `replacement`.
    /// Moves the other edits through it first. An earlier edit on the same layer that it wrote over
    /// wholly is folded in, so reverting the new one restores what the person had; one on another
    /// layer just leaves (its text was rewritten).
    @discardableResult
    mutating func recordPartnerEdit(replacing range: NSRange, original: String, replacement: String,
                                    layer: PartnerEditLayer, rules: [PunctuationRule] = []) -> Int? {
        let replaced = move(through: range, replacement: replacement)
        var original = original
        var rules = rules
        for prior in replaced.sorted(by: { $0.range.location > $1.range.location })
        where prior.layer == layer && prior.range.location >= range.location && NSMaxRange(prior.range) <= NSMaxRange(range) {
            let local = NSRange(location: prior.range.location - range.location, length: prior.range.length)
            guard NSMaxRange(local) <= (original as NSString).length,
                  (original as NSString).substring(with: local) == prior.replacement else { continue }
            original = (original as NSString).replacingCharacters(in: local, with: prior.original)
            for rule in prior.rules where !rules.contains(rule) { rules.append(rule) }
        }
        return record(range: NSRange(location: range.location, length: (replacement as NSString).length),
                      original: original, replacement: replacement, layer: layer, rules: rules)
    }

    /// Records an edit already made: `range` is where `replacement` now is.
    @discardableResult
    mutating func record(range: NSRange, original: String, replacement: String,
                         layer: PartnerEditLayer, rules: [PunctuationRule] = []) -> Int? {
        guard layer != .user, original != replacement else { return nil }
        defer { nextID += 1 }
        edits.append(LayeredEdit(id: nextID, layer: layer, range: range, original: original,
                                 replacement: replacement, rules: rules))
        edits.sort { $0.range.location < $1.range.location }
        return nextID
    }

    /// Moves every edit through a change to the text (the person's, or the partner's own). A change
    /// that reaches into an edit's text rewrote it: from then on that text is the person's, so the
    /// edit leaves its layer and can't be reverted. Returns the edits that left.
    @discardableResult
    mutating func move(through range: NSRange, replacement: String) -> [LayeredEdit] {
        let delta = (replacement as NSString).length - range.length
        var removed: [LayeredEdit] = []
        edits = edits.compactMap { edit in
            var edit = edit
            let end = NSMaxRange(edit.range)
            if NSMaxRange(range) <= edit.range.location && !(range.length == 0 && edit.range.length == 0 && range.location == end) {
                // Wholly before it (an insertion at its start goes before it)
                edit.range.location += delta
                return edit
            }
            if range.location >= end {
                // Wholly after it (an insertion at its end stays outside)
                return edit
            }
            removed.append(edit)
            return nil
        }
        return removed
    }

    /// Drops edits whose text is no longer what the partner wrote (a change this stack didn't see).
    @discardableResult
    mutating func validate(against text: NSString) -> [LayeredEdit] {
        var removed: [LayeredEdit] = []
        edits.removeAll { edit in
            let intact = NSMaxRange(edit.range) <= text.length && text.substring(with: edit.range) == edit.replacement
            if !intact { removed.append(edit) }
            return !intact
        }
        return removed
    }

    /// The changes that put back what was there before the edits `ids`, last first so each one's
    /// range is still right when it's made. Edits no longer intact in `text` are left out.
    func reverts(for ids: Set<Int>, in text: NSString) -> [EditLayerChange] {
        edits
            .filter { ids.contains($0.id) }
            .filter { NSMaxRange($0.range) <= text.length && text.substring(with: $0.range) == $0.replacement }
            .sorted { $0.range.location > $1.range.location }
            .map { EditLayerChange(range: $0.range, replacement: $0.original) }
    }

    /// The ids of every edit on `layer`.
    func ids(on layer: PartnerEditLayer) -> Set<Int> {
        Set(edits(on: layer).map(\.id))
    }

    mutating func remove(_ ids: Set<Int>) {
        edits.removeAll { ids.contains($0.id) }
    }

    mutating func removeAll() {
        edits = []
    }

    /// `text` with `changes` (last first, as `reverts` gives them) made, and `caret` moved through them.
    static func apply(_ changes: [EditLayerChange], to text: NSString, caret: Int) -> (text: String, caret: Int) {
        var result = text as String
        var caret = caret
        for change in changes {
            let ns = result as NSString
            guard NSMaxRange(change.range) <= ns.length else { continue }
            result = ns.replacingCharacters(in: change.range, with: change.replacement)
            let length = (change.replacement as NSString).length
            if caret >= NSMaxRange(change.range) {
                caret += length - change.range.length
            } else if caret > change.range.location {
                caret = change.range.location + length
            }
        }
        return (result, caret)
    }
}

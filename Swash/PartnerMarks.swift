//
//  PartnerMarks.swift
//  Swash
//
//  What the writing partner isn't sure about (#128). In Automatically, a correction below its
//  confidence threshold, or one with more than one candidate, changes nothing: it leaves a quiet
//  mark on the word, to be settled when the person has finished typing. Marks live with the
//  editor's session, never in the Markdown, and move with every edit.
//

import Foundation

/// One place the partner would change, if the person agrees.
nonisolated struct PartnerUncertainMark: Equatable, Sendable {
    /// Unique within the session, so a shown candidate can find its mark after edits move it.
    var id: Int
    /// The fix for the first candidate: its range, original text, rules and bandleader ids.
    var edit: PartnerEdit
    /// What it could become, most likely first.
    var candidates: [String]

    var range: NSRange { edit.range }
    var original: String { edit.original }
    var confidence: Double { edit.confidence ?? 0.5 }

    /// The fix for `candidates[index]`.
    func edit(choosing index: Int) -> PartnerEdit {
        var chosen = edit
        chosen.replacement = candidates[min(max(0, index), candidates.count - 1)]
        chosen.alternatives = []
        return chosen
    }

    /// How VoiceOver and the rotor describe it.
    var label: String {
        let options = candidates.map { "“\($0)”" }
        let list = options.count <= 1 ? (options.first ?? "") : options.dropLast().joined(separator: ", ") + " or " + options.last!
        return "“\(original)” could be \(list)"
    }
}

nonisolated enum PartnerMarks {
    /// At most this many marks in a paragraph: beyond it the least confident go, so a rough draft
    /// isn't covered in underlines.
    static let maxPerParagraph = 3

    /// What a kept mark is remembered by: the same word or phrase isn't marked again in the document.
    static func key(_ original: String) -> String {
        original.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    /// The paragraph around `location` in `text`: the lines between blank lines.
    static func paragraph(at location: Int, in text: NSString) -> NSRange {
        var start = min(max(0, location), text.length)
        while start > 0 {
            let lineEnd = start - 1
            guard text.character(at: lineEnd) == 0x0A else { start -= 1; continue }
            // A blank line just before this one ends the paragraph
            if lineEnd > 0, text.character(at: lineEnd - 1) == 0x0A { break }
            if lineEnd == 0 { break }
            start -= 1
        }
        var end = min(max(0, location), text.length)
        while end < text.length {
            if text.character(at: end) == 0x0A, end + 1 < text.length, text.character(at: end + 1) == 0x0A { break }
            if text.character(at: end) == 0x0A, end + 1 == text.length { break }
            end += 1
        }
        return NSRange(location: start, length: end - start)
    }

    /// `marks` with `new` added: kept words aren't marked again, a new mark replaces one it overlaps,
    /// and each paragraph keeps only its `maxPerParagraph` most confident.
    static func adding(_ new: [PartnerUncertainMark], to marks: [PartnerUncertainMark], kept: Set<String>,
                       in text: NSString) -> [PartnerUncertainMark] {
        var result = marks
        for mark in new where !kept.contains(key(mark.original)) && !mark.candidates.isEmpty {
            result.removeAll { NSIntersectionRange($0.range, mark.range).length > 0 || NSEqualRanges($0.range, mark.range) }
            result.append(mark)
        }
        var byParagraph: [Int: [PartnerUncertainMark]] = [:]
        for mark in result { byParagraph[paragraph(at: mark.range.location, in: text).location, default: []].append(mark) }
        var capped: [PartnerUncertainMark] = []
        for (_, group) in byParagraph {
            // Most confident first; among equals, the earlier one
            let ranked = group.sorted { ($0.confidence, -$0.range.location) > ($1.confidence, -$1.range.location) }
            capped += ranked.prefix(maxPerParagraph)
        }
        return capped.sorted { $0.range.location < $1.range.location }
    }

    /// `marks` after `range` was replaced with `replacement`. Marks after it move; a mark the edit
    /// reaches into is `edited` (the person settled it their way, or the partner replaced it).
    /// Typing just before or just after a mark leaves it where it is.
    static func moved(_ marks: [PartnerUncertainMark], through range: NSRange, replacement: String)
        -> (marks: [PartnerUncertainMark], edited: [PartnerUncertainMark]) {
        let delta = (replacement as NSString).length - range.length
        var kept: [PartnerUncertainMark] = []
        var edited: [PartnerUncertainMark] = []
        for var mark in marks {
            let markRange = mark.range
            if NSMaxRange(range) <= markRange.location {
                // Wholly before the mark (an insertion at its start counts as before)
                mark.edit.range.location += delta
                kept.append(mark)
            } else if range.location >= NSMaxRange(markRange) {
                kept.append(mark)
            } else {
                edited.append(mark)
            }
        }
        return (kept, edited)
    }

    /// The mark the caret at `location` is in (between its first and last character, or just after it).
    static func index(at location: Int, in marks: [PartnerUncertainMark]) -> Int? {
        marks.firstIndex { location > $0.range.location && location <= NSMaxRange($0.range) }
    }

    /// The mark after (or, going back, before) the one at `index`, wrapping round; nil when none is left.
    static func step(from index: Int?, by offset: Int, count: Int) -> Int? {
        guard count > 0 else { return nil }
        guard let index else { return offset >= 0 ? 0 : count - 1 }
        return ((index + offset) % count + count) % count
    }
}

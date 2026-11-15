//
//  WritingPartner.swift
//  Swash
//
//  The writing partner's local tier (#61): small fixes to punctuation and capitals that Swash makes
//  as you type, each one its own undo step. Nothing here touches the network.
//
//  The Punctuate voice looks only at the word you just finished (when you type a space or a
//  punctuation mark after it) or the paragraph you just ended (with a blank line). It never edits
//  the word the caret is in, and never anything inside code, math, HTML, links' addresses, front
//  matter or tables. Each rule learns from you: undoing its fix straight away halves its weight,
//  keeping it raises it, and a rule whose weight falls too low stops.
//

import Foundation
import NaturalLanguage
import PixerateMarkdown

nonisolated enum WritingPartnerMode: String, CaseIterable, Identifiable, Sendable {
    case off
    case automatic

    var id: String { rawValue }

    var title: String {
        switch self {
        case .off: return "Off"
        case .automatic: return "Automatically"
        }
    }
}

nonisolated enum WritingPartnerDefaults {
    static let mode = "writingPartnerMode"
    static let stats = "writingPartnerStats"
    /// Whether the partner corrects spelling. Unset, it follows the system's "Correct spelling
    /// automatically" (the editor's own autocorrect is off while the partner is on).
    static let spelling = "writingPartnerSpelling"
    /// The undo action name of the partner's edits.
    static let actionName = "Punctuation"

    /// Whether the partner corrects spelling: the stored choice, else `systemDefault` (the system's
    /// "Correct spelling automatically").
    static func spelling(_ defaults: UserDefaults = .standard, systemDefault: Bool) -> Bool {
        defaults.object(forKey: spelling) == nil ? systemDefault : defaults.bool(forKey: spelling)
    }

    static func mode(_ defaults: UserDefaults = .standard) -> WritingPartnerMode {
        defaults.string(forKey: mode).flatMap(WritingPartnerMode.init(rawValue:)) ?? .off
    }
}

/// One thing the Punctuate voice fixes.
nonisolated enum PunctuationRule: String, CaseIterable, Codable, Sendable {
    /// `i` → `I`, `i'm` → `I'm`.
    case pronounI
    /// `dont` → `don't`, `im` → `I'm`.
    case contraction
    /// A capital letter to start a sentence.
    case sentenceCase
    /// A full stop or question mark at the end of a line.
    case terminalPunctuation
    /// A misspelt word, as the system's spell checker would autocorrect it (`becuase` → `because`).
    case spelling

    var title: String {
        switch self {
        case .pronounI: return "Capital I"
        case .contraction: return "Apostrophes"
        case .sentenceCase: return "Capitals at the start of sentences"
        case .terminalPunctuation: return "Full stops and question marks"
        case .spelling: return "Spelling"
        }
    }
}

/// A fix to the raw Markdown: replace `range` with `replacement`. `rules` are the rules it applies
/// (a word can get an apostrophe and a capital at once); undoing it counts against each of them.
nonisolated struct PunctuationEdit: Equatable, Sendable {
    var range: NSRange
    var replacement: String
    var rules: [PunctuationRule]
}

/// What the partner learned: a weight per rule, raised when you keep a fix and halved when you undo it.
nonisolated struct WritingPartnerStats: Codable, Equatable, Sendable {
    struct Entry: Codable, Equatable, Sendable {
        var kept = 0
        var undone = 0
        var weight = 1.0
    }

    var rules: [String: Entry] = [:]

    /// Below this, a rule stops (two undos in a row from the start).
    static let minimumWeight = 0.3

    func weight(_ rule: PunctuationRule) -> Double { rules[rule.rawValue]?.weight ?? 1 }
    func isActive(_ rule: PunctuationRule) -> Bool { weight(rule) >= Self.minimumWeight }

    mutating func kept(_ rule: PunctuationRule) {
        var entry = rules[rule.rawValue] ?? Entry()
        entry.kept += 1
        entry.weight = min(2, entry.weight * 1.1)
        rules[rule.rawValue] = entry
    }

    mutating func undone(_ rule: PunctuationRule) {
        var entry = rules[rule.rawValue] ?? Entry()
        entry.undone += 1
        entry.weight *= 0.5
        rules[rule.rawValue] = entry
    }

    static func load(_ defaults: UserDefaults = .standard) -> WritingPartnerStats {
        guard let data = defaults.data(forKey: WritingPartnerDefaults.stats),
              let stats = try? JSONDecoder().decode(WritingPartnerStats.self, from: data) else { return WritingPartnerStats() }
        return stats
    }

    func save(_ defaults: UserDefaults = .standard) {
        if let data = try? JSONEncoder().encode(self) { defaults.set(data, forKey: WritingPartnerDefaults.stats) }
    }
}

/// The Punctuate voice: fixes for the word or paragraph just finished.
nonisolated enum PunctuateVoice {
    /// The fixes to make after the person typed the character at `boundary` (raw-Markdown UTF-16
    /// offset; the caret is just after it). `document` is `text` parsed in `flavor`.
    static func edits(
        text: String,
        boundary: Int,
        document: MarkdownDocument,
        flavor: MarkdownFlavor,
        enterEndedLine: Bool? = nil,
        isActive: (PunctuationRule) -> Bool = { _ in true },
        spellingCorrection: ((_ word: String, _ range: NSRange, _ text: String) -> String?)? = nil
    ) -> [PunctuationEdit] {
        let ns = text as NSString
        guard boundary >= 0, boundary < ns.length else { return [] }
        let typed = ns.character(at: boundary)
        var edits: [PunctuationEdit] = []

        guard isWordBoundary(typed) || typed == newline else { return [] }

        // The word just finished: letters and apostrophes before the boundary
        var start = boundary
        while start > 0, isWordCharacter(ns.character(at: start - 1)) { start -= 1 }
        let wordRange = NSRange(location: start, length: boundary - start)
        guard wordRange.length > 0, isProse(wordRange, ns: ns, document: document) else { return [] }
        guard !insideUnclosedSpan(before: start, ns: ns) else { return [] }
        let word = ns.substring(with: wordRange)

        var replacement = word
        var rules: [PunctuationRule] = []
        if let fixed = fixedWord(word, flavor: flavor, isActive: isActive) {
            replacement = fixed.word
            rules.append(fixed.rule)
        } else if isActive(.spelling), let spellingCorrection, (word as NSString).length > 2,
                  !word.contains(where: { $0.isUppercase }) || word.first?.isUppercase == true && !word.dropFirst().contains(where: { $0.isUppercase }),
                  let corrected = spellingCorrection(word, wordRange, text), corrected != word,
                  !corrected.contains(" ") {
            replacement = corrected
            rules.append(.spelling)
        }
        if flavor != .slack, isActive(.sentenceCase),
           let first = replacement.unicodeScalars.first, CharacterSet.lowercaseLetters.contains(first),
           !replacement.dropFirst().contains(where: { $0.isUppercase }),
           startsSentence(at: start, ns: ns, document: document) {
            replacement = replacement.prefix(1).uppercased() + replacement.dropFirst()
            rules.append(.sentenceCase)
        }
        if !rules.isEmpty, replacement != word {
            edits.append(PunctuationEdit(range: wordRange, replacement: replacement, rules: rules))
        }
        // `its` before an adverb, article, verb or pronoun ("its really", "its a") is "it's"
        if isActive(.contraction), let edit = itsBefore(word: word, at: start, ns: ns, document: document) {
            edits.append(edit)
        }
        // Enter at the end of a line ends its sentence: give it a full stop or a question mark
        if typed == newline, flavor != .slack, isActive(.terminalPunctuation),
           let edit = terminalPunctuation(ns: ns, lineEnd: boundary, document: document, enterEndedLine: enterEndedLine) {
            edits.append(edit)
        }
        return edits
    }

    /// What the voice looks at for the boundary at `boundary`: the word before it, or the line it
    /// ends when it's a newline. Nil when that isn't prose (code, math, a URL…), so there's nothing
    /// to show as being checked.
    static func checkedRange(text: String, boundary: Int, document: MarkdownDocument) -> NSRange? {
        let ns = text as NSString
        guard boundary > 0, boundary < ns.length else { return nil }
        let typed = ns.character(at: boundary)
        if typed == newline {
            var lineStart = boundary
            while lineStart > 0, ns.character(at: lineStart - 1) != newline { lineStart -= 1 }
            let line = NSRange(location: lineStart, length: boundary - lineStart)
            guard line.length > 0, !(ns.substring(with: line).trimmingCharacters(in: .whitespaces).isEmpty) else { return nil }
            var last = boundary - 1
            while last > lineStart, ns.character(at: last) == 0x20 { last -= 1 }
            guard isProse(NSRange(location: last, length: 1), ns: ns, document: document) else { return nil }
            return line
        }
        guard isWordBoundary(typed) else { return nil }
        var start = boundary
        while start > 0, isWordCharacter(ns.character(at: start - 1)) { start -= 1 }
        let word = NSRange(location: start, length: boundary - start)
        guard word.length > 0, isProse(word, ns: ns, document: document), !insideUnclosedSpan(before: start, ns: ns) else { return nil }
        return word
    }

    // MARK: Words

    private static let newline: unichar = 0x0A

    /// Characters that end a word: space, tab and sentence punctuation.
    static func isWordBoundary(_ c: unichar) -> Bool {
        switch c {
        case 0x20, 0x09, 0x2C, 0x2E, 0x3F, 0x21, 0x3B, 0x3A: return true // space tab , . ? ! ; :
        default: return false
        }
    }

    static func isWordCharacter(_ c: unichar) -> Bool {
        if c == 0x27 || c == 0x2019 { return true } // ' and ’
        guard let scalar = Unicode.Scalar(c) else { return false }
        return CharacterSet.letters.contains(scalar)
    }

    /// Missing apostrophes. Words that are also real words without one (its, well, were, ill, id,
    /// wont, lets, shell, hell, wed) are left alone.
    static let contractions: [String: String] = [
        "dont": "don't", "doesnt": "doesn't", "didnt": "didn't", "cant": "can't", "couldnt": "couldn't",
        "shouldnt": "shouldn't", "wouldnt": "wouldn't", "isnt": "isn't", "arent": "aren't", "wasnt": "wasn't",
        "werent": "weren't", "havent": "haven't", "hasnt": "hasn't", "hadnt": "hadn't", "mustnt": "mustn't",
        "neednt": "needn't", "youre": "you're", "theyre": "they're", "youve": "you've", "theyve": "they've",
        "weve": "we've", "youll": "you'll", "theyll": "they'll", "youd": "you'd", "theyd": "they'd",
        "thats": "that's", "whats": "what's", "theres": "there's", "heres": "here's", "wheres": "where's",
        "whos": "who's", "hes": "he's", "shes": "she's", "aint": "ain't", "im": "I'm", "ive": "I've",
    ]

    private static let pronounForms: [String: String] = ["i": "I", "i'm": "I'm", "i've": "I've", "i'd": "I'd", "i'll": "I'll",
                                                         "i’m": "I’m", "i’ve": "I’ve", "i’d": "I’d", "i’ll": "I’ll"]

    private static func fixedWord(_ word: String, flavor: MarkdownFlavor, isActive: (PunctuationRule) -> Bool) -> (word: String, rule: PunctuationRule)? {
        if isActive(.pronounI), let fixed = pronounForms[word] { return (fixed, .pronounI) }
        guard isActive(.contraction) else { return nil }
        let lower = word.lowercased()
        guard let fixed = contractions[lower] else { return nil }
        if lower == "im" || lower == "ive" { return word == "IM" || word == "IVE" ? nil : (fixed, .contraction) }
        if word == lower { return (fixed, .contraction) }
        if word == word.uppercased() { return (fixed.uppercased(), .contraction) }
        if word == word.prefix(1).uppercased() + word.dropFirst() { return (fixed.prefix(1).uppercased() + fixed.dropFirst(), .contraction) }
        return nil // mixed case: a name or a code word
    }

    /// `its` is right before a noun or adjective ("its colour", "its own") and wrong before an
    /// adverb, article, verb or pronoun ("its really", "its a", "its going", "its me"). Once the
    /// word after it is finished, the tagger says which, from the line so far. "its about" can go
    /// either way and stays.
    static func itsBefore(word: String, at start: Int, ns: NSString, document: MarkdownDocument) -> PunctuationEdit? {
        guard start >= 2, ns.character(at: start - 1) == 0x20 else { return nil }
        var previousStart = start - 1
        while previousStart > 0, isWordCharacter(ns.character(at: previousStart - 1)) { previousStart -= 1 }
        let previousRange = NSRange(location: previousStart, length: start - 1 - previousStart)
        guard previousRange.length == 3 else { return nil }
        let previous = ns.substring(with: previousRange)
        guard previous.lowercased() == "its", isProse(previousRange, ns: ns, document: document) else { return nil }
        var lineStart = previousStart
        while lineStart > 0, ns.character(at: lineStart - 1) != newline { lineStart -= 1 }
        let line = ns.substring(with: NSRange(location: lineStart, length: start + (word as NSString).length - lineStart))
        let tagger = NLTagger(tagSchemes: [.lexicalClass])
        tagger.string = line
        let wordStart = line.index(line.endIndex, offsetBy: -word.count)
        let (tag, _) = tagger.tag(at: wordStart, unit: .word, scheme: .lexicalClass)
        guard let tag, [.adverb, .determiner, .verb, .pronoun].contains(tag) else { return nil }
        let fixed: String
        if previous == "its" { fixed = "it's" } else if previous == "ITS" { fixed = "IT'S" } else if previous == "Its" { fixed = "It's" } else { return nil }
        return PunctuationEdit(range: previousRange, replacement: fixed, rules: [.contraction])
    }

    // MARK: Where prose is

    /// The deepest node whose range contains `location`.
    static func node(at location: Int, in document: MarkdownDocument) -> MarkdownNode {
        var node = document.root
        descend: while true {
            for child in node.children where NSLocationInRange(location, child.range) {
                node = child
                continue descend
            }
            return node
        }
    }

    /// The word is ordinary text in a paragraph, heading or list: not in code, math, HTML, an
    /// address, front matter or a table, and not part of a URL, path, email or mention.
    static func isProse(_ range: NSRange, ns: NSString, document: MarkdownDocument) -> Bool {
        var node: MarkdownNode? = node(at: range.location, in: document)
        guard node?.kind == .text else { return false }
        while let current = node {
            switch current.kind {
            case .code, .codeBlock, .math, .htmlInline, .htmlBlock, .frontMatter, .image, .table,
                 .linkReferenceDefinition:
                return false
            case .link(_, _, let kind) where kind == .autolink || kind == .extendedAutolink:
                return false
            default:
                node = current.parent
            }
        }
        // The token around the word (to the previous space) mustn't be a URL, path, email, mention or tag
        var tokenStart = range.location
        while tokenStart > 0 {
            let c = ns.character(at: tokenStart - 1)
            if c == 0x20 || c == 0x09 || c == newline { break }
            tokenStart -= 1
        }
        let token = ns.substring(with: NSRange(location: tokenStart, length: NSMaxRange(range) - tokenStart))
        if token.contains("/") || token.contains("@") || token.contains("#") || token.contains("\\") || token.contains(":") || token.contains("_") {
            return false
        }
        if token.dropLast(range.length).contains(".") { return false } // file.name, e.g.word
        return true
    }

    /// A code span or inline math still being typed: an odd number of backticks or dollar signs
    /// earlier on the line, which the parser can't see as code or math until it's closed.
    static func insideUnclosedSpan(before location: Int, ns: NSString) -> Bool {
        var backticks = 0
        var dollars = 0
        var i = location
        while i > 0 {
            let c = ns.character(at: i - 1)
            if c == newline { break }
            if c == 0x60 { backticks += 1 }
            if c == 0x24, i < 2 || ns.character(at: i - 2) != 0x5C { dollars += 1 }
            i -= 1
        }
        return backticks % 2 == 1 || dollars % 2 == 1
    }

    // MARK: Sentences

    private static let abbreviations: Set<String> = ["e.g", "i.e", "etc", "vs", "cf", "approx", "mr", "mrs", "ms", "dr", "st", "no", "fig", "ca", "al"]

    /// The word at `start` begins a sentence: it's the first word of its paragraph, heading, list
    /// item or quote, or follows `.`, `?` or `!` (not an abbreviation, ellipsis or decimal).
    static func startsSentence(at start: Int, ns: NSString, document: MarkdownDocument) -> Bool {
        let text = node(at: start, in: document)
        var block = text.parent
        while let current = block, !current.kind.isBlock { block = current.parent }
        guard let block else { return false }
        switch block.kind {
        case .paragraph, .heading: break
        default: return false
        }
        if let first = firstText(in: block), first === text, firstNonMarkup(in: ns, from: first.range.location, to: start) {
            return true
        }
        // Back over spaces and opening markup to the end of the previous sentence
        var i = start
        while i > 0 {
            let c = ns.character(at: i - 1)
            if c == 0x20 || c == 0x2A || c == 0x5F || c == 0x7E || c == 0x5B || c == 0x28 || c == 0x22 || c == 0x201C {
                i -= 1
            } else {
                break
            }
        }
        guard i > 0 else { return false }
        // Swash shows each line on its own, so a word that starts a line starts a sentence
        if ns.character(at: i - 1) == newline { return true }
        guard i < start else { return false }
        let end = ns.character(at: i - 1)
        // Closing quotes and brackets after the stop: "Done." or (done.)
        var stop = i - 1
        if end == 0x22 || end == 0x201D || end == 0x29, stop > 0 { stop -= 1 }
        let mark = ns.character(at: stop)
        if mark == 0x3F || mark == 0x21 { return true } // ? !
        guard mark == 0x2E else { return false }
        if stop > 0 {
            let before = ns.character(at: stop - 1)
            if before == 0x2E { return false } // ellipsis
            if let scalar = Unicode.Scalar(before), CharacterSet.decimalDigits.contains(scalar) { return false }
        }
        var wordStart = stop
        while wordStart > 0, isWordCharacter(ns.character(at: wordStart - 1)) || ns.character(at: wordStart - 1) == 0x2E { wordStart -= 1 }
        let previous = ns.substring(with: NSRange(location: wordStart, length: stop - wordStart)).lowercased()
        if abbreviations.contains(previous) { return false }
        if previous.count == 1 { return false } // initials: J. Smith
        return true
    }

    private static func firstText(in block: MarkdownNode) -> MarkdownNode? {
        var found: MarkdownNode?
        block.walk { node in
            if found == nil, node.kind == .text { found = node }
        }
        return found
    }

    /// Only opening markup (and spaces) between `from` and `to`.
    private static func firstNonMarkup(in ns: NSString, from: Int, to: Int) -> Bool {
        guard from <= to else { return false }
        for i in from..<to {
            switch ns.character(at: i) {
            case 0x20, 0x2A, 0x5F, 0x7E, 0x22, 0x201C, 0x28: continue
            default: return false
            }
        }
        return true
    }

    // MARK: Paragraph ends

    private static let questionWords: Set<String> = [
        "who", "what", "when", "where", "why", "how", "which", "whose", "whom",
        "is", "are", "am", "was", "were", "do", "does", "did", "can", "could", "would", "should", "will", "shall",
        "may", "might", "have", "has", "had", "isn't", "aren't", "don't", "doesn't", "didn't", "can't", "won't",
        "wouldn't", "shouldn't", "couldn't",
    ]

    /// A full stop or question mark for the line just ended with Enter at `lineEnd` (the newline):
    /// four or more words of prose ending in a letter or digit, in a paragraph (not a heading, list
    /// item, callout, footnote or table). Only when Enter was pressed at the end of the line, not to
    /// split it.
    /// `enterEndedLine` says whether Enter was pressed at the end of the line, when the caller saw
    /// it happen; otherwise the text after the newline decides.
    static func terminalPunctuation(ns: NSString, lineEnd: Int, document: MarkdownDocument, enterEndedLine: Bool? = nil) -> PunctuationEdit? {
        guard lineEnd > 0 else { return nil }
        let endedLine = enterEndedLine ?? (lineEnd + 1 >= ns.length || ns.character(at: lineEnd + 1) == newline)
        guard endedLine else { return nil } // Enter split a line
        let last = lineEnd - 1
        let lastChar = ns.character(at: last)
        guard let scalar = Unicode.Scalar(lastChar), CharacterSet.alphanumerics.contains(scalar) else { return nil }
        let text = node(at: last, in: document)
        guard text.kind == .text else { return nil }
        var paragraph = text.parent
        while let current = paragraph, current.kind != .paragraph {
            if current.kind.isBlock { return nil }
            paragraph = current.parent
        }
        guard let paragraph else { return nil }
        var ancestor = paragraph.parent
        while let current = ancestor {
            switch current.kind {
            case .listItem, .tableCell, .alert, .footnoteDefinition: return nil
            default: ancestor = current.parent
            }
        }
        guard isProse(NSRange(location: last, length: 1), ns: ns, document: document),
              !insideUnclosedSpan(before: last, ns: ns) else { return nil }
        var lineStart = lineEnd
        while lineStart > 0, ns.character(at: lineStart - 1) != newline { lineStart -= 1 }
        let line = ns.substring(with: NSRange(location: lineStart, length: lineEnd - lineStart))
        let words = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
        guard words.count >= 4 else { return nil }
        let first = words[0].lowercased().trimmingCharacters(in: CharacterSet.letters.inverted.subtracting(CharacterSet(charactersIn: "'’")))
        let mark = questionWords.contains(first) ? "?" : "."
        return PunctuationEdit(range: NSRange(location: lineEnd, length: 0), replacement: mark, rules: [.terminalPunctuation])
    }
}

/// One edit the partner's cursor plays out (#878): it selects `range` (whole words, in the text
/// before the fix) and types `replacement` over it, as a person would retype a word. Each is its
/// own undo step; undoing it counts against `rules`, and tells the spell checker `spellingWords`
/// are words.
nonisolated struct PartnerEdit: Equatable, Sendable {
    var range: NSRange
    /// The text `range` held when the fix was worked out: the edit is played only if it's still there.
    var original: String
    var replacement: String
    var rules: [PunctuationRule]
    var spellingWords: [String]
}

/// Where one of the voice's edits landed in the fixed text, and what it did.
nonisolated struct PartnerMark: Equatable, Sendable {
    var range: NSRange
    var rules: [PunctuationRule]
    /// The word a spelling fix replaced.
    var spellingWord: String?
}

extension PunctuateVoice {
    /// The fix that turns `old` into `new`, as whole-word edits from left to right. `marks` say where
    /// the voice's edits landed in `new`, so each edit carries the rules that made it.
    static func partnerEdits(from old: NSString, to new: NSString, marks: [PartnerMark]) -> [PartnerEdit] {
        let (changedBefore, changedAfter) = changedRanges(from: old, to: new)
        // Widen each change to the words it touches, and merge changes in the same word
        var pairs: [(before: NSRange, after: NSRange)] = []
        for (before, after) in zip(changedBefore, changedAfter) {
            let pair = (word(around: before, in: old), word(around: after, in: new))
            if let last = pairs.last, pair.0.location <= NSMaxRange(last.before) {
                pairs[pairs.count - 1] = (NSUnionRange(last.before, pair.0), NSUnionRange(last.after, pair.1))
            } else {
                pairs.append(pair)
            }
        }
        return pairs.map { before, after in
            let touching = marks.filter { $0.range.location <= NSMaxRange(after) && NSMaxRange($0.range) >= after.location }
            var rules: [PunctuationRule] = []
            for rule in touching.flatMap(\.rules) where !rules.contains(rule) { rules.append(rule) }
            let original = old.substring(with: before)
            let spelling = touching.compactMap(\.spellingWord).filter { original.contains($0) }
            return PartnerEdit(range: before, original: original, replacement: new.substring(with: after),
                               rules: rules, spellingWords: spelling)
        }
    }

    /// `range` widened to the whole words it touches (a full stop added after a word takes the word).
    static func word(around range: NSRange, in text: NSString) -> NSRange {
        var start = range.location
        var end = NSMaxRange(range)
        while start > 0, isWordCharacter(text.character(at: start - 1)) { start -= 1 }
        while end < text.length, isWordCharacter(text.character(at: end)) { end += 1 }
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
}

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
    /// The undo action name of the partner's edits.
    static let actionName = "Punctuation"

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
    /// A full stop or question mark at the end of a paragraph.
    case terminalPunctuation

    var title: String {
        switch self {
        case .pronounI: return "Capital I"
        case .contraction: return "Apostrophes"
        case .sentenceCase: return "Capitals at the start of sentences"
        case .terminalPunctuation: return "Full stops and question marks"
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
        isActive: (PunctuationRule) -> Bool = { _ in true }
    ) -> [PunctuationEdit] {
        let ns = text as NSString
        guard boundary >= 0, boundary < ns.length else { return [] }
        let typed = ns.character(at: boundary)
        var edits: [PunctuationEdit] = []

        if typed == newline {
            // A blank line ends the paragraph above: give it a full stop or a question mark
            if boundary > 0, ns.character(at: boundary - 1) == newline, flavor != .slack, isActive(.terminalPunctuation),
               let edit = terminalPunctuation(ns: ns, paragraphEnd: boundary - 1, document: document) {
                edits.append(edit)
            }
            return edits
        }
        guard isWordBoundary(typed) else { return [] }

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
        return edits
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
        guard i < start, i > 0, ns.character(at: i - 1) != newline else { return false }
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

    /// A full stop or question mark after a finished paragraph of at least four words that ends
    /// in a letter or digit. Not for headings, list items, quotes' callouts or table cells.
    static func terminalPunctuation(ns: NSString, paragraphEnd: Int, document: MarkdownDocument) -> PunctuationEdit? {
        guard paragraphEnd > 0 else { return nil }
        let last = paragraphEnd - 1
        let lastChar = ns.character(at: last)
        guard let scalar = Unicode.Scalar(lastChar), CharacterSet.alphanumerics.contains(scalar) else { return nil }
        let text = node(at: last, in: document)
        guard text.kind == .text else { return nil }
        var paragraph = text.parent
        while let current = paragraph, current.kind != .paragraph {
            if current.kind.isBlock { return nil }
            paragraph = current.parent
        }
        guard let paragraph, NSMaxRange(paragraph.range) == paragraphEnd else { return nil }
        var ancestor = paragraph.parent
        while let current = ancestor {
            switch current.kind {
            case .listItem, .tableCell, .alert, .footnoteDefinition: return nil
            default: ancestor = current.parent
            }
        }
        // One line only: lines broken by hand are often poetry or addresses
        let source = ns.substring(with: paragraph.range)
        guard !source.contains("\n") else { return nil }
        let words = source.split(whereSeparator: { $0 == " " || $0 == "\t" })
        guard words.count >= 4, isProse(NSRange(location: last, length: 1), ns: ns, document: document) else { return nil }
        let first = words[0].lowercased().trimmingCharacters(in: CharacterSet.letters.inverted.subtracting(CharacterSet(charactersIn: "'")))
        let mark = questionWords.contains(first) ? "?" : "."
        return PunctuationEdit(range: NSRange(location: paragraphEnd, length: 0), replacement: mark, rules: [.terminalPunctuation])
    }
}

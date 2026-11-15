//
//  main.swift
//  WritingPartnerEval
//
//  Strip-and-restore evaluation for the writing partner's Punctuate voice (#106, part of #61):
//  1. Loads the Markdown corpus in Tests/WritingPartnerEval/corpus (GFM and Slack samples).
//  2. Strips punctuation and casing the partner owns (.?! at sentence ends, apostrophes in
//     contractions, commas before "but", sentence-start capitals, capital I, OK) and optionally
//     injects typos from a fixed, seeded list — never touching protected contexts.
//  3. Replays each stripped document character by character with a manual clock and a fixed fake
//     spell checker, so scores are 100% deterministic across Macs and CI runners.
//  4. Scores precision, recall and F1 (overall and per rule), wrong changes, edits to the word the
//     caret is in while typing (penalised), and changes inside protected contexts (code, math,
//     tables, link destinations or front matter: must be zero).
//  5. Writes a Markdown report (totals, per-rule scores, per-document table and worst documents
//     with diffs) and checks results against Tests/WritingPartnerEval/baseline.json.
//

import Foundation
import PixerateMarkdown

// MARK: - Seeded PRNG & Fixed Fake Spell Checker

nonisolated struct SplitMix64: RandomNumberGenerator, Sendable {
    var state: UInt64

    init(seed: UInt64) {
        self.state = seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    mutating func nextUnit() -> Double {
        Double(next() >> 11) * (1.0 / Double(1 << 53))
    }
}

/// Fixed word → typo pairs for deterministic typo injection and fake spell checking.
nonisolated enum EvalSpelling {
    static let wordToTypo: [String: String] = [
        "because": "becuase",
        "happening": "happenign",
        "separate": "seperate",
        "definitely": "definately",
        "receive": "recieve",
        "necessary": "neccessary",
        "argument": "arguement",
        "environment": "enviroment",
        "immediately": "immediatly",
        "beginning": "begining",
        "document": "docuemnt",
        "sentence": "sentance",
        "paragraph": "paragarph",
        "different": "diffrent",
        "available": "availabe",
        "language": "langauge",
        "character": "charcter",
        "without": "wihtout",
        "through": "throuhg",
        "between": "betwen",
        "another": "antoher",
        "example": "exmaple",
        "changes": "chagnes",
        "before": "befoer",
        "window": "widnow",
        "always": "alwyas",
        "people": "poeple",
        "simple": "simpel",
        "number": "numebr",
        "keyboard": "keybaord",
        "terminal": "termnial",
        "directory": "direcotry",
        "temporary": "temproary",
        "benchmark": "bencmhark",
        "colleague": "collegue",
        "preference": "prefernece",
        "architecture": "architetcure",
        "animation": "animatoin",
        "connection": "conneciton",
    ]

    static let typoToWord: [String: String] = {
        var map: [String: String] = [
            "teh": "the",
            "Teh": "The",
            "hte": "the",
            "Hte": "The",
        ]
        for (word, typo) in wordToTypo {
            map[typo] = word
            let capWord = word.prefix(1).uppercased() + word.dropFirst()
            let capTypo = typo.prefix(1).uppercased() + typo.dropFirst()
            map[capTypo] = capWord
        }
        return map
    }()

    static let fakeChecker: (String, NSRange, String) -> String? = { word, _, _ in
        typoToWord[word]
    }
}

// MARK: - Protected Contexts

nonisolated enum ProtectedContextKind: String, CaseIterable, Codable, Sendable {
    case code
    case math
    case table
    case linkDestination
    case frontMatter
    case html
}

nonisolated struct ProtectedSpan: Equatable, Sendable {
    var kind: ProtectedContextKind
    var range: NSRange
    var snippet: String
}

nonisolated enum ProtectedContextDetector {
    /// Extracts all ranges in `text` that belong to code, math, tables, link destinations, front
    /// matter or HTML. The partner must make zero changes inside any of these ranges.
    static func protectedSpans(in text: String, document: MarkdownDocument) -> [ProtectedSpan] {
        let ns = text as NSString
        var spans: [ProtectedSpan] = []

        func add(_ kind: ProtectedContextKind, _ range: NSRange) {
            guard range.length > 0, range.location >= 0, NSMaxRange(range) <= ns.length else { return }
            spans.append(ProtectedSpan(kind: kind, range: range, snippet: ns.substring(with: range)))
        }

        document.root.walk { node in
            switch node.kind {
            case .code:
                add(.code, node.range)
            case .codeBlock(_, let info):
                let trimmed = info.trimmingCharacters(in: .whitespaces).lowercased()
                add(trimmed == "math" ? .math : .code, node.range)
            case .math:
                add(.math, node.range)
            case .table:
                add(.table, node.range)
            case .frontMatter:
                add(.frontMatter, node.range)
            case .htmlInline, .htmlBlock:
                add(.html, node.range)
            case .linkReferenceDefinition, .image:
                add(.linkDestination, node.range)
            case .link(_, _, let kind):
                switch kind {
                case .autolink, .extendedAutolink:
                    add(.linkDestination, node.range)
                case .inline, .reference:
                    for marker in node.markers {
                        add(.linkDestination, marker)
                    }
                }
            default:
                break
            }
        }
        return spans.sorted {
            $0.range.location != $1.range.location
                ? $0.range.location < $1.range.location
                : $0.range.length < $1.range.length
        }
    }

    static func intersects(_ range: NSRange, spans: [ProtectedSpan]) -> ProtectedSpan? {
        for span in spans {
            if range.length == 0 {
                if range.location > span.range.location && range.location < NSMaxRange(span.range) {
                    return span
                }
            } else if NSIntersectionRange(range, span.range).length > 0 {
                return span
            }
        }
        return nil
    }
}

// MARK: - Stripper

nonisolated struct StrippedItem: Equatable, Sendable {
    var originalRange: NSRange
    var strippedRange: NSRange
    var originalText: String
    var strippedText: String
    var rules: [PunctuationRule]
}

nonisolated struct StrippedDocument: Sendable {
    var name: String
    var flavor: MarkdownFlavor
    var original: String
    var stripped: String
    var items: [StrippedItem]
    var protectedSpansInOriginal: [ProtectedSpan]
    var protectedSpansInStripped: [ProtectedSpan]
}

enum Stripper {
    /// Contractions stripped by the eval: all contractions the partner owns plus common English
    /// contractions ("won't") so recall measures what the rule table covers and what it misses.
    static let contractionToStripped: [String: String] = {
        var map: [String: String] = [
            "it's": "its",
            "i'd": "id",
            "i'll": "ill",
            "won't": "wont",
        ]
        for (stripped, fixed) in TextMechanics.contractions {
            map[fixed.lowercased()] = stripped
        }
        return map
    }()

    private static let abbreviations: Set<String> = [
        "e.g", "i.e", "etc", "vs", "cf", "approx", "mr", "mrs", "ms", "dr", "st", "no", "fig", "ca", "al"
    ]

    private static let contextSensitiveNeighbors: Set<String> = [
        "its", "it's", "id", "i'd", "ill", "i'll", "but"
    ]

    private static let questionWords: Set<String> = [
        "who", "what", "when", "where", "why", "how", "which", "whose", "whom",
        "is", "are", "am", "was", "were", "do", "does", "did", "can", "could", "would", "should", "will", "shall",
        "may", "might", "have", "has", "had", "isn't", "aren't", "don't", "doesn't", "didn't", "can't", "won't",
        "wouldn't", "shouldn't", "couldn't",
    ]

    static func strip(
        name: String,
        original: String,
        flavor: MarkdownFlavor,
        injectTypos: Bool = true,
        typoProbability: Double = 0.65,
        seed: UInt64 = 0x5357_4153_48
    ) -> StrippedDocument {
        let ns = original as NSString
        let document = MarkdownDocument.parse(original, flavor: flavor)
        let protectedOriginal = ProtectedContextDetector.protectedSpans(in: original, document: document)

        // Mix the document name into the seed so each file gets its own deterministic stream
        var docSeed = seed
        for byte in name.utf8 {
            docSeed = (docSeed ^ UInt64(byte)) &* 0x1000_0000_01B3
        }
        var rng = SplitMix64(seed: docSeed)

        struct RawEdit {
            var range: NSRange
            var originalText: String
            var replacement: String
            var rules: [PunctuationRule]
        }

        var rawEdits: [RawEdit] = []

        func isProtected(_ range: NSRange) -> Bool {
            ProtectedContextDetector.intersects(range, spans: protectedOriginal) != nil
        }

        // Collect all word ranges in the document
        var words: [(range: NSRange, text: String)] = []
        var idx = 0
        while idx < ns.length {
            if PunctuateVoice.isWordCharacter(ns.character(at: idx)) {
                let start = idx
                while idx < ns.length, PunctuateVoice.isWordCharacter(ns.character(at: idx)) {
                    idx += 1
                }
                let range = NSRange(location: start, length: idx - start)
                words.append((range, ns.substring(with: range)))
            } else {
                idx += 1
            }
        }

        // 1. Strip word-level rules: pronounI, capitals, contractions, sentenceCase, spelling typos
        for (wordIndex, entry) in words.enumerated() {
            let wordRange = entry.range
            let rawWord = entry.text
            let normalizedWord = rawWord.replacingOccurrences(of: "’", with: "'")
            guard !isProtected(wordRange),
                  TextMechanics.isProse(wordRange, ns: ns, document: document) else { continue }

            let lower = normalizedWord.lowercased()
            let atSentenceStart = flavor != .slack
                && EvalSentences.startsSentence(at: wordRange.location, ns: ns, document: document)
            let isTitleCase = normalizedWord.first?.isUppercase == true
                && !normalizedWord.dropFirst().contains(where: { $0.isUppercase })

            // Standalone pronoun "I"
            if normalizedWord == "I" {
                rawEdits.append(RawEdit(range: wordRange, originalText: rawWord, replacement: "i", rules: [.pronounI]))
                continue
            }

            // "OK" (non-Slack)
            if flavor != .slack, normalizedWord == "OK" {
                rawEdits.append(RawEdit(range: wordRange, originalText: rawWord, replacement: "ok", rules: [.capitals]))
                continue
            }

            // Contractions
            if let strippedContraction = contractionToStripped[lower] {
                if lower == "i'm" || lower == "i've" {
                    if normalizedWord == "I'm" || normalizedWord == "I've" {
                        rawEdits.append(RawEdit(range: wordRange, originalText: rawWord, replacement: strippedContraction, rules: [.contraction]))
                    }
                    continue
                }
                if lower == "i'd" || lower == "i'll" {
                    if normalizedWord == "I'd" || normalizedWord == "I'll" {
                        let rules: [PunctuationRule] = atSentenceStart ? [.contraction, .sentenceCase] : [.contraction]
                        rawEdits.append(RawEdit(range: wordRange, originalText: rawWord, replacement: strippedContraction, rules: rules))
                    }
                    continue
                }
                if atSentenceStart && isTitleCase {
                    rawEdits.append(RawEdit(range: wordRange, originalText: rawWord, replacement: strippedContraction, rules: [.contraction, .sentenceCase]))
                    continue
                }
                if normalizedWord == lower {
                    rawEdits.append(RawEdit(range: wordRange, originalText: rawWord, replacement: strippedContraction, rules: [.contraction]))
                    continue
                }
                if normalizedWord == normalizedWord.uppercased() {
                    rawEdits.append(RawEdit(range: wordRange, originalText: rawWord, replacement: strippedContraction.uppercased(), rules: [.contraction]))
                    continue
                }
                continue
            }

            // Skip words with apostrophes (possessives such as "reader's")
            guard !normalizedWord.contains("'") else { continue }

            let shouldLowerSentenceStart = atSentenceStart && isTitleCase && normalizedWord.count >= 2

            // Check whether this word is eligible for seeded typo injection
            var injectTypo = false
            if injectTypos, let _ = EvalSpelling.wordToTypo[lower] {
                let prevLower = wordIndex > 0 ? words[wordIndex - 1].text.replacingOccurrences(of: "’", with: "'").lowercased() : ""
                let nextLower = wordIndex + 1 < words.count ? words[wordIndex + 1].text.replacingOccurrences(of: "’", with: "'").lowercased() : ""
                let nearContextRule = contextSensitiveNeighbors.contains(prevLower) || contextSensitiveNeighbors.contains(nextLower)
                let isQuestionLead = atSentenceStart && questionWords.contains(lower)
                // Only inject on lowercase words or sentence-start title-case words (never mid-sentence proper nouns)
                let caseEligible = normalizedWord == lower || shouldLowerSentenceStart
                if !nearContextRule && !isQuestionLead && caseEligible {
                    injectTypo = rng.nextUnit() < typoProbability
                }
            }

            if injectTypo, let typo = EvalSpelling.wordToTypo[lower] {
                let rules: [PunctuationRule] = shouldLowerSentenceStart ? [.spelling, .sentenceCase] : [.spelling]
                rawEdits.append(RawEdit(range: wordRange, originalText: rawWord, replacement: typo, rules: rules))
            } else if shouldLowerSentenceStart {
                rawEdits.append(RawEdit(range: wordRange, originalText: rawWord, replacement: lower, rules: [.sentenceCase]))
            }
        }

        // 2. Strip commas before "but" in prose (non-Slack)
        if flavor != .slack && words.count >= 2 {
            for i in 1..<words.count {
                let current = words[i]
                let prev = words[i - 1]
                guard current.text.lowercased() == "but" else { continue }
                let betweenStart = NSMaxRange(prev.range)
                let betweenLength = current.range.location - betweenStart
                guard betweenLength == 2,
                      ns.substring(with: NSRange(location: betweenStart, length: 2)) == ", " else { continue }
                let commaRange = NSRange(location: betweenStart, length: 1)
                guard !isProtected(commaRange),
                      TextMechanics.isProse(prev.range, ns: ns, document: document),
                      TextMechanics.isProse(current.range, ns: ns, document: document) else { continue }
                rawEdits.append(RawEdit(range: commaRange, originalText: ",", replacement: "", rules: [.clauseComma]))
            }
        }

        // 3. Strip terminal punctuation (.?!) at line ends of prose paragraphs (non-Slack)
        if flavor != .slack {
            for pos in 0..<ns.length where ns.character(at: pos) == 0x0A {
                guard pos >= 2 else { continue }
                let markPos = pos - 1
                let mark = ns.character(at: markPos)
                guard mark == 0x2E || mark == 0x3F || mark == 0x21 else { continue } // . ? !
                let beforeMark = ns.character(at: markPos - 1)
                guard let scalar = Unicode.Scalar(beforeMark), CharacterSet.alphanumerics.contains(scalar) else { continue }
                if mark == 0x2E && markPos >= 2 && ns.character(at: markPos - 2) == 0x2E { continue } // ellipsis

                // Skip trailing abbreviations such as "etc."
                var wordStart = markPos
                while wordStart > 0,
                      PunctuateVoice.isWordCharacter(ns.character(at: wordStart - 1)) || ns.character(at: wordStart - 1) == 0x2E {
                    wordStart -= 1
                }
                let lastToken = ns.substring(with: NSRange(location: wordStart, length: markPos - wordStart)).lowercased()
                if abbreviations.contains(lastToken) { continue }

                let markRange = NSRange(location: markPos, length: 1)
                guard !isProtected(markRange),
                      isTerminalParagraphProse(at: markPos - 1, ns: ns, document: document) else { continue }
                rawEdits.append(RawEdit(
                    range: markRange,
                    originalText: ns.substring(with: markRange),
                    replacement: "",
                    rules: [.terminalPunctuation]
                ))
            }
        }

        // Sort raw edits in ascending document order and build stripped text + items
        rawEdits.sort { $0.range.location < $1.range.location }
        var stripped = ""
        var items: [StrippedItem] = []
        var cursor = 0
        for edit in rawEdits {
            guard edit.range.location >= cursor else { continue }
            if edit.range.location > cursor {
                stripped += ns.substring(with: NSRange(location: cursor, length: edit.range.location - cursor))
            }
            let strippedStart = (stripped as NSString).length
            stripped += edit.replacement
            let strippedLength = (edit.replacement as NSString).length
            items.append(StrippedItem(
                originalRange: edit.range,
                strippedRange: NSRange(location: strippedStart, length: strippedLength),
                originalText: edit.originalText,
                strippedText: edit.replacement,
                rules: edit.rules
            ))
            cursor = NSMaxRange(edit.range)
        }
        if cursor < ns.length {
            stripped += ns.substring(from: cursor)
        }

        let strippedDoc = MarkdownDocument.parse(stripped, flavor: flavor)
        let protectedStripped = ProtectedContextDetector.protectedSpans(in: stripped, document: strippedDoc)

        return StrippedDocument(
            name: name,
            flavor: flavor,
            original: original,
            stripped: stripped,
            items: items,
            protectedSpansInOriginal: protectedOriginal,
            protectedSpansInStripped: protectedStripped
        )
    }

    private static func isTerminalParagraphProse(at location: Int, ns: NSString, document: MarkdownDocument) -> Bool {
        let text = EvalSentences.node(at: location, in: document)
        guard text.kind == .text else { return false }
        var paragraph = text.parent
        while let current = paragraph, current.kind != .paragraph {
            if current.kind.isBlock { return false }
            paragraph = current.parent
        }
        guard let paragraph else { return false }
        var ancestor = paragraph.parent
        while let current = ancestor {
            switch current.kind {
            case .listItem, .tableCell, .alert, .footnoteDefinition:
                return false
            default:
                ancestor = current.parent
            }
        }
        return TextMechanics.isProse(NSRange(location: location, length: 1), ns: ns, document: document)
    }
}

// MARK: - Manual-Clock Replay Harness

nonisolated struct ManualClock: Sendable {
    private(set) var nowMs: Int = 0

    mutating func advance(by ms: Int) {
        nowMs += max(0, ms)
    }
}

nonisolated struct RecordedPartnerEdit: Equatable, Sendable {
    var strippedRange: NSRange
    var workingRange: NSRange
    var originalWord: String
    var replacement: String
    var rules: [PunctuationRule]
    var timestampMs: Int
    var touchedCaretWord: Bool
    var touchedProtectedContext: ProtectedContextKind?
}

nonisolated struct ReplayResult: Sendable {
    var replayed: String
    var recordedEdits: [RecordedPartnerEdit]
    var finalTextByStrippedRange: [NSRange: String]
    var rulesByStrippedRange: [NSRange: [PunctuationRule]]
    var caretWordEdits: Int
    var protectedChanges: Int
    var protectedViolations: [String]
    var durationMs: Int
}

enum ReplayHarness {
    /// Replays `doc.stripped` character by character with a manual clock and fixed fake spell checker.
    static func replay(_ doc: StrippedDocument) -> ReplayResult {
        let strippedNS = doc.stripped as NSString
        var working = "" as NSString
        // For each UTF-16 unit in `working`, the UTF-16 index in `doc.stripped` it originated from.
        var origins: [Int] = []
        var clock = ManualClock()

        struct PendingBoundary {
            var workingLocation: Int
            var enterEndedLine: Bool?
            var dueAtMs: Int
        }

        var pendingBoundaries: [PendingBoundary] = []
        var recordedEdits: [RecordedPartnerEdit] = []
        var rulesByStrippedRange: [NSRange: [PunctuationRule]] = [:]
        var insertedByStrippedOffset: [Int: String] = [:]
        var caretWordEdits = 0
        var protectedViolations: [String] = []

        func currentCaretWordRange(at caret: Int, in text: NSString) -> NSRange? {
            var start = caret
            while start > 0, PunctuateVoice.isWordCharacter(text.character(at: start - 1)) {
                start -= 1
            }
            var end = caret
            while end < text.length, PunctuateVoice.isWordCharacter(text.character(at: end)) {
                end += 1
            }
            return end > start ? NSRange(location: start, length: end - start) : nil
        }

        func mapToStrippedRange(_ workingRange: NSRange) -> NSRange {
            if workingRange.length == 0 {
                let sLoc: Int
                if workingRange.location < origins.count {
                    sLoc = origins[workingRange.location]
                } else if let last = origins.last {
                    sLoc = last + 1
                } else {
                    sLoc = 0
                }
                return NSRange(location: sLoc, length: 0)
            }
            let sStart = origins[workingRange.location]
            let sEnd = origins[NSMaxRange(workingRange) - 1] + 1
            return NSRange(location: sStart, length: max(1, sEnd - sStart))
        }

        func applyVoiceEdit(_ edit: PunctuationEdit, caret: inout Int) {
            let oldSnippet = working.substring(with: edit.range)
            let strippedRange = mapToStrippedRange(edit.range)

            // Check whether this edit touches the word the caret is currently in
            var touchedCaretWord = false
            if let caretWord = currentCaretWordRange(at: caret, in: working) {
                if NSMaxRange(edit.range) >= caretWord.location && edit.range.location <= NSMaxRange(caretWord) {
                    touchedCaretWord = true
                    caretWordEdits += 1
                }
            }

            // Check whether this edit touches any protected context in the stripped document
            var touchedProtected: ProtectedContextKind?
            if let span = ProtectedContextDetector.intersects(strippedRange, spans: doc.protectedSpansInStripped) {
                touchedProtected = span.kind
                protectedViolations.append(
                    "\(doc.name): edit \(oldSnippet.debugDescription) → \(edit.replacement.debugDescription) inside \(span.kind.rawValue)"
                )
            }

            let repLength = (edit.replacement as NSString).length
            let delta = repLength - edit.range.length
            working = working.replacingCharacters(in: edit.range, with: edit.replacement) as NSString

            // Update origins array to preserve stripped-coordinate boundaries
            if edit.range.length == 0 {
                let sOrigin = strippedRange.location
                let newOrigins = Array(repeating: sOrigin, count: repLength)
                origins.insert(contentsOf: newOrigins, at: edit.range.location)
                insertedByStrippedOffset[sOrigin, default: ""] += edit.replacement
            } else {
                let sStart = strippedRange.location
                let sEnd = NSMaxRange(strippedRange)
                var newOrigins = Array(repeating: sStart, count: repLength)
                if repLength > 0 {
                    newOrigins[repLength - 1] = max(sStart, sEnd - 1)
                }
                origins.replaceSubrange(edit.range.location..<NSMaxRange(edit.range), with: newOrigins)
            }

            if edit.range.location <= caret {
                caret += delta
            }
            for i in pendingBoundaries.indices where pendingBoundaries[i].workingLocation >= NSMaxRange(edit.range) {
                pendingBoundaries[i].workingLocation += delta
            }

            var accumulated = rulesByStrippedRange[strippedRange] ?? []
            for rule in edit.rules where !accumulated.contains(rule) {
                accumulated.append(rule)
            }
            rulesByStrippedRange[strippedRange] = accumulated

            recordedEdits.append(RecordedPartnerEdit(
                strippedRange: strippedRange,
                workingRange: edit.range,
                originalWord: oldSnippet,
                replacement: edit.replacement,
                rules: edit.rules,
                timestampMs: clock.nowMs,
                touchedCaretWord: touchedCaretWord,
                touchedProtectedContext: touchedProtected
            ))
        }

        func flushDueBoundaries(upTo timeMs: Int, caret: inout Int) {
            while let firstIdx = pendingBoundaries.firstIndex(where: { $0.dueAtMs <= timeMs }) {
                let pending = pendingBoundaries.remove(at: firstIdx)
                let boundary = pending.workingLocation
                guard boundary >= 0, boundary < working.length, boundary < caret else { continue }
                let text = working as String
                let parsed = MarkdownDocument.parse(text, flavor: doc.flavor)
                let edits = PunctuateVoice.edits(
                    text: text,
                    boundary: boundary,
                    document: parsed,
                    flavor: doc.flavor,
                    enterEndedLine: pending.enterEndedLine,
                    isActive: { !$0.isTypography }, // the default rules (typography is off unless turned on)
                    spellingCorrection: EvalSpelling.fakeChecker
                )
                for edit in edits.sorted(by: { $0.range.location > $1.range.location }) {
                    applyVoiceEdit(edit, caret: &caret)
                }
            }
        }

        var caret = 0
        var sIdx = 0
        while sIdx < strippedNS.length {
            let charRange = strippedNS.rangeOfComposedCharacterSequence(at: sIdx)
            let token = strippedNS.substring(with: charRange)
            let codeUnit = strippedNS.character(at: charRange.location)

            // Advance the manual clock before this keystroke and run any due boundary checks
            let stepMs: Int
            if codeUnit == 0x0A {
                stepMs = 120
            } else if PunctuateVoice.isWordBoundary(codeUnit) {
                stepMs = 70
            } else {
                stepMs = 40
            }
            clock.advance(by: stepMs)
            flushDueBoundaries(upTo: clock.nowMs, caret: &caret)

            // Insert the typed character at the caret
            let keystrokeLocation = caret
            working = working.replacingCharacters(in: NSRange(location: caret, length: 0), with: token) as NSString
            for offset in 0..<charRange.length {
                origins.insert(charRange.location + offset, at: caret + offset)
            }
            caret += charRange.length

            if PunctuateVoice.isWordBoundary(codeUnit) || codeUnit == 0x0A {
                let enterEndedLine: Bool? = (codeUnit == 0x0A)
                    ? (keystrokeLocation + 1 >= working.length || working.character(at: keystrokeLocation + 1) == 0x0A)
                    : nil
                // Schedule boundary check on the manual clock (runs 20 ms after the boundary key)
                pendingBoundaries.append(PendingBoundary(
                    workingLocation: keystrokeLocation,
                    enterEndedLine: enterEndedLine,
                    dueAtMs: clock.nowMs + 20
                ))
            } else {
                // Non-boundary keystroke: the caret is currently inside a word. Verify the voice
                // never returns an edit while typing inside a word.
                let text = working as String
                let parsed = MarkdownDocument.parse(text, flavor: doc.flavor)
                let prematureEdits = PunctuateVoice.edits(
                    text: text,
                    boundary: keystrokeLocation,
                    document: parsed,
                    flavor: doc.flavor,
                    isActive: { !$0.isTypography },
                    spellingCorrection: EvalSpelling.fakeChecker
                )
                for edit in prematureEdits.sorted(by: { $0.range.location > $1.range.location }) {
                    applyVoiceEdit(edit, caret: &caret)
                }
            }

            sIdx = NSMaxRange(charRange)
        }

        // Flush any remaining scheduled boundaries at end of typing
        clock.advance(by: 100)
        flushDueBoundaries(upTo: clock.nowMs, caret: &caret)

        // Extract final text for each stripped item range and each edited range
        var finalTextByStrippedRange: [NSRange: String] = [:]
        let allTrackedRanges = Set(doc.items.map(\.strippedRange)).union(rulesByStrippedRange.keys)

        for range in allTrackedRanges {
            if range.length == 0 {
                finalTextByStrippedRange[range] = insertedByStrippedOffset[range.location] ?? ""
            } else {
                let sStart = range.location
                let sEnd = NSMaxRange(range) - 1
                if let wStart = origins.firstIndex(of: sStart),
                   let wEnd = origins.lastIndex(of: sEnd),
                   wEnd >= wStart {
                    finalTextByStrippedRange[range] = working.substring(with: NSRange(location: wStart, length: wEnd - wStart + 1))
                }
            }
        }

        // Also verify that every protected span in the replayed document matches the original
        let replayedString = working as String
        let replayedDoc = MarkdownDocument.parse(replayedString, flavor: doc.flavor)
        let protectedReplayed = ProtectedContextDetector.protectedSpans(in: replayedString, document: replayedDoc)
        if protectedReplayed.count != doc.protectedSpansInOriginal.count {
            protectedViolations.append(
                "\(doc.name): protected span count changed (\(doc.protectedSpansInOriginal.count) → \(protectedReplayed.count))"
            )
        } else {
            for (origSpan, repSpan) in zip(doc.protectedSpansInOriginal, protectedReplayed) {
                if origSpan.kind != repSpan.kind || origSpan.snippet != repSpan.snippet {
                    protectedViolations.append(
                        "\(doc.name): \(origSpan.kind.rawValue) changed from \(origSpan.snippet.debugDescription) to \(repSpan.snippet.debugDescription)"
                    )
                }
            }
        }

        return ReplayResult(
            replayed: replayedString,
            recordedEdits: recordedEdits,
            finalTextByStrippedRange: finalTextByStrippedRange,
            rulesByStrippedRange: rulesByStrippedRange,
            caretWordEdits: caretWordEdits,
            protectedChanges: protectedViolations.count,
            protectedViolations: protectedViolations,
            durationMs: clock.nowMs
        )
    }
}

// MARK: - Scorer

nonisolated struct RuleScore: Codable, Equatable, Sendable {
    var stripped: Int = 0
    var restored: Int = 0
    var missed: Int = 0
    var wrong: Int = 0

    var precision: Double {
        let denom = restored + wrong
        return denom == 0 ? 1.0 : Double(restored) / Double(denom)
    }

    var recall: Double {
        let denom = restored + missed
        return denom == 0 ? 1.0 : Double(restored) / Double(denom)
    }

    var f1: Double {
        let p = precision
        let r = recall
        return (p + r) == 0 ? 0.0 : (2.0 * p * r) / (p + r)
    }

    mutating func merge(_ other: RuleScore) {
        stripped += other.stripped
        restored += other.restored
        missed += other.missed
        wrong += other.wrong
    }
}

nonisolated struct Discrepancy: Equatable, Sendable {
    enum Kind: String, Sendable {
        case missed = "Missed"
        case wrong = "Wrong"
    }
    var kind: Kind
    var rule: PunctuationRule
    var expected: String
    var actual: String
}

nonisolated struct DocumentScore: Sendable {
    var name: String
    var flavor: MarkdownFlavor
    var original: String
    var stripped: String
    var replayed: String
    var totalRuleScore: RuleScore
    var perRule: [PunctuationRule: RuleScore]
    var caretWordEdits: Int
    var protectedChanges: Int
    var protectedViolations: [String]
    var discrepancies: [Discrepancy]

    /// Penalty per caret-word edit (each edit inside the word being typed subtracts 0.05 from F1).
    var caretPenalty: Double {
        Double(caretWordEdits) * 0.05
    }

    var netScore: Double {
        max(0.0, totalRuleScore.f1 - caretPenalty)
    }
}

nonisolated struct EvalSummary: Sendable {
    var documents: [DocumentScore]
    var totalRuleScore: RuleScore
    var perRule: [PunctuationRule: RuleScore]
    var caretWordEdits: Int
    var protectedChanges: Int
    var protectedViolations: [String]

    var caretPenalty: Double {
        Double(caretWordEdits) * 0.05
    }

    var netScore: Double {
        max(0.0, totalRuleScore.f1 - caretPenalty)
    }
}

nonisolated enum Scorer {
    static func score(document doc: StrippedDocument, replay: ReplayResult) -> DocumentScore {
        let strippedNS = doc.stripped as NSString
        var perRule: [PunctuationRule: RuleScore] = [:]
        for rule in PunctuationRule.allCases {
            perRule[rule] = RuleScore()
        }
        var discrepancies: [Discrepancy] = []

        var itemsByRange: [NSRange: StrippedItem] = [:]
        for item in doc.items {
            itemsByRange[item.strippedRange] = item
        }

        let allRanges = Set(itemsByRange.keys).union(replay.rulesByStrippedRange.keys).sorted {
            $0.location != $1.location ? $0.location < $1.location : $0.length < $1.length
        }

        for range in allRanges {
            let item = itemsByRange[range]
            let expectedRules = item?.rules ?? []
            let appliedRules = replay.rulesByStrippedRange[range] ?? []
            let originalText = item?.originalText ?? (range.length > 0 ? strippedNS.substring(with: range) : "")
            let finalText = replay.finalTextByStrippedRange[range] ?? (range.length > 0 ? strippedNS.substring(with: range) : "")

            if range.length == 0 {
                // Zero-length punctuation insertion (.clauseComma or .terminalPunctuation)
                for rule in expectedRules {
                    perRule[rule, default: RuleScore()].stripped += 1
                    if finalText == originalText {
                        perRule[rule, default: RuleScore()].restored += 1
                    } else if finalText.isEmpty {
                        perRule[rule, default: RuleScore()].missed += 1
                        discrepancies.append(Discrepancy(kind: .missed, rule: rule, expected: originalText, actual: "∅"))
                    } else {
                        perRule[rule, default: RuleScore()].missed += 1
                        perRule[rule, default: RuleScore()].wrong += 1
                        discrepancies.append(Discrepancy(kind: .wrong, rule: rule, expected: originalText, actual: finalText))
                    }
                }
                for rule in appliedRules where !expectedRules.contains(rule) {
                    if finalText != originalText {
                        perRule[rule, default: RuleScore()].wrong += 1
                        discrepancies.append(Discrepancy(kind: .wrong, rule: rule, expected: "∅", actual: finalText))
                    }
                }
            } else {
                // Word replacement (.pronounI, .capitals, .contraction, .sentenceCase, .spelling)
                let origNorm = originalText.replacingOccurrences(of: "’", with: "'")
                let finalNorm = finalText.replacingOccurrences(of: "’", with: "'")

                for rule in expectedRules {
                    perRule[rule, default: RuleScore()].stripped += 1
                    let isRestored: Bool
                    switch rule {
                    case .sentenceCase:
                        isRestored = finalNorm.first == origNorm.first
                    case .contraction, .spelling:
                        isRestored = finalNorm.lowercased() == origNorm.lowercased()
                    case .pronounI, .capitals, .terminalPunctuation, .clauseComma, .curlyQuotes, .dashes, .ellipses:
                        isRestored = finalNorm == origNorm
                    }
                    if isRestored {
                        perRule[rule, default: RuleScore()].restored += 1
                    } else {
                        perRule[rule, default: RuleScore()].missed += 1
                        discrepancies.append(Discrepancy(kind: .missed, rule: rule, expected: originalText, actual: finalText))
                    }
                }

                // Check for wrong changes made by applied rules that weren't in expectedRules
                for rule in appliedRules where !expectedRules.contains(rule) {
                    let isWrong: Bool
                    switch rule {
                    case .sentenceCase:
                        isWrong = finalNorm.first != origNorm.first
                    case .contraction, .spelling:
                        isWrong = finalNorm.lowercased() != origNorm.lowercased()
                    case .pronounI, .capitals, .terminalPunctuation, .clauseComma, .curlyQuotes, .dashes, .ellipses:
                        isWrong = finalNorm != origNorm
                    }
                    if isWrong {
                        perRule[rule, default: RuleScore()].wrong += 1
                        discrepancies.append(Discrepancy(kind: .wrong, rule: rule, expected: originalText, actual: finalText))
                    }
                }
            }
        }

        var total = RuleScore()
        for rule in PunctuationRule.allCases {
            if let s = perRule[rule] {
                total.merge(s)
            }
        }

        return DocumentScore(
            name: doc.name,
            flavor: doc.flavor,
            original: doc.original,
            stripped: doc.stripped,
            replayed: replay.replayed,
            totalRuleScore: total,
            perRule: perRule,
            caretWordEdits: replay.caretWordEdits,
            protectedChanges: replay.protectedChanges,
            protectedViolations: replay.protectedViolations,
            discrepancies: discrepancies
        )
    }

    static func summarize(_ docs: [DocumentScore]) -> EvalSummary {
        var total = RuleScore()
        var perRule: [PunctuationRule: RuleScore] = [:]
        for rule in PunctuationRule.allCases {
            perRule[rule] = RuleScore()
        }
        var caretWordEdits = 0
        var protectedChanges = 0
        var protectedViolations: [String] = []

        for doc in docs {
            total.merge(doc.totalRuleScore)
            for rule in PunctuationRule.allCases {
                if let r = doc.perRule[rule] {
                    perRule[rule, default: RuleScore()].merge(r)
                }
            }
            caretWordEdits += doc.caretWordEdits
            protectedChanges += doc.protectedChanges
            protectedViolations.append(contentsOf: doc.protectedViolations)
        }

        return EvalSummary(
            documents: docs,
            totalRuleScore: total,
            perRule: perRule,
            caretWordEdits: caretWordEdits,
            protectedChanges: protectedChanges,
            protectedViolations: protectedViolations
        )
    }
}

// MARK: - Baseline File & Regression Check

nonisolated struct EvalBaseline: Codable, Equatable, Sendable {
    struct OverallMetrics: Codable, Equatable, Sendable {
        var stripped: Int
        var restored: Int
        var missed: Int
        var wrongChanges: Int
        var precision: Double
        var recall: Double
        var f1: Double
        var netScore: Double
        var caretWordEdits: Int
        var protectedChanges: Int
    }

    struct RuleMetrics: Codable, Equatable, Sendable {
        var stripped: Int
        var restored: Int
        var missed: Int
        var wrongChanges: Int
        var precision: Double
        var recall: Double
        var f1: Double
    }

    struct DocumentMetrics: Codable, Equatable, Sendable {
        var name: String
        var flavor: String
        var stripped: Int
        var restored: Int
        var missed: Int
        var wrongChanges: Int
        var precision: Double
        var recall: Double
        var f1: Double
        var netScore: Double
        var caretWordEdits: Int
        var protectedChanges: Int
    }

    var seed: UInt64
    var maxScoreDropMargin: Double
    var maxRuleScoreDropMargin: Double
    var overall: OverallMetrics
    var rules: [String: RuleMetrics]
    var documents: [DocumentMetrics]

    static func round4(_ value: Double) -> Double {
        (value * 10000.0).rounded() / 10000.0
    }

    static func from(summary: EvalSummary, seed: UInt64, margin: Double, ruleMargin: Double) -> EvalBaseline {
        var rulesMap: [String: RuleMetrics] = [:]
        for rule in PunctuationRule.allCases {
            let s = summary.perRule[rule] ?? RuleScore()
            rulesMap[rule.rawValue] = RuleMetrics(
                stripped: s.stripped,
                restored: s.restored,
                missed: s.missed,
                wrongChanges: s.wrong,
                precision: round4(s.precision),
                recall: round4(s.recall),
                f1: round4(s.f1)
            )
        }

        let docs = summary.documents.map { doc in
            DocumentMetrics(
                name: doc.name,
                flavor: doc.flavor.rawValue,
                stripped: doc.totalRuleScore.stripped,
                restored: doc.totalRuleScore.restored,
                missed: doc.totalRuleScore.missed,
                wrongChanges: doc.totalRuleScore.wrong,
                precision: round4(doc.totalRuleScore.precision),
                recall: round4(doc.totalRuleScore.recall),
                f1: round4(doc.totalRuleScore.f1),
                netScore: round4(doc.netScore),
                caretWordEdits: doc.caretWordEdits,
                protectedChanges: doc.protectedChanges
            )
        }

        return EvalBaseline(
            seed: seed,
            maxScoreDropMargin: margin,
            maxRuleScoreDropMargin: ruleMargin,
            overall: OverallMetrics(
                stripped: summary.totalRuleScore.stripped,
                restored: summary.totalRuleScore.restored,
                missed: summary.totalRuleScore.missed,
                wrongChanges: summary.totalRuleScore.wrong,
                precision: round4(summary.totalRuleScore.precision),
                recall: round4(summary.totalRuleScore.recall),
                f1: round4(summary.totalRuleScore.f1),
                netScore: round4(summary.netScore),
                caretWordEdits: summary.caretWordEdits,
                protectedChanges: summary.protectedChanges
            ),
            rules: rulesMap,
            documents: docs
        )
    }

    static func check(summary: EvalSummary, against baseline: EvalBaseline, marginOverride: Double?) -> [String] {
        var failures: [String] = []
        let margin = marginOverride ?? baseline.maxScoreDropMargin
        let ruleMargin = marginOverride ?? baseline.maxRuleScoreDropMargin

        if summary.protectedChanges > 0 {
            failures.append(
                "Protected-context changes must be 0, got \(summary.protectedChanges): \(summary.protectedViolations.joined(separator: "; "))"
            )
        }
        if summary.caretWordEdits > baseline.overall.caretWordEdits {
            failures.append(
                "Caret-word edits increased from baseline \(baseline.overall.caretWordEdits) to \(summary.caretWordEdits)"
            )
        }
        if summary.totalRuleScore.precision + margin < baseline.overall.precision {
            failures.append(String(
                format: "Overall precision %.2f%% dropped below baseline %.2f%% by more than %.2f%%",
                summary.totalRuleScore.precision * 100, baseline.overall.precision * 100, margin * 100
            ))
        }
        if summary.totalRuleScore.recall + margin < baseline.overall.recall {
            failures.append(String(
                format: "Overall recall %.2f%% dropped below baseline %.2f%% by more than %.2f%%",
                summary.totalRuleScore.recall * 100, baseline.overall.recall * 100, margin * 100
            ))
        }
        if summary.netScore + margin < baseline.overall.netScore {
            failures.append(String(
                format: "Overall net score %.2f%% dropped below baseline %.2f%% by more than %.2f%%",
                summary.netScore * 100, baseline.overall.netScore * 100, margin * 100
            ))
        }

        for rule in PunctuationRule.allCases {
            guard let baseRule = baseline.rules[rule.rawValue],
                  let currentRule = summary.perRule[rule] else { continue }
            if currentRule.f1 + ruleMargin < baseRule.f1 {
                failures.append(String(
                    format: "Rule '%@' (%@) F1 %.2f%% dropped below baseline %.2f%% by more than %.2f%%",
                    rule.rawValue, rule.title, currentRule.f1 * 100, baseRule.f1 * 100, ruleMargin * 100
                ))
            }
        }

        return failures
    }
}

// MARK: - Markdown Report Generator

nonisolated enum ReportGenerator {
    static func pct(_ value: Double) -> String {
        String(format: "%.1f%%", value * 100.0)
    }

    static func lineDiff(original: String, replayed: String) -> String {
        let origLines = original.components(separatedBy: "\n")
        let repLines = replayed.components(separatedBy: "\n")
        let maxLines = max(origLines.count, repLines.count)
        var diffLines: [String] = []
        for idx in 0..<maxLines {
            let o = idx < origLines.count ? origLines[idx] : nil
            let r = idx < repLines.count ? repLines[idx] : nil
            if o != r {
                diffLines.append("@@ line \(idx + 1) @@")
                if let o { diffLines.append("- \(o)") }
                if let r { diffLines.append("+ \(r)") }
            }
        }
        return diffLines.joined(separator: "\n")
    }

    static func generate(summary: EvalSummary, baseline: EvalBaseline?, failures: [String], worstCount: Int = 3) -> String {
        var md: [String] = []
        md.append("# Writing Partner Strip-and-Restore Eval Report")
        md.append("")
        md.append("## Overall Totals")
        md.append("")
        md.append("| Metric | Value | Baseline |")
        md.append("| :--- | ---: | ---: |")
        md.append("| Documents evaluated | \(summary.documents.count) | \(baseline.map { "\($0.documents.count)" } ?? "—") |")
        md.append("| Stripped items (expected) | \(summary.totalRuleScore.stripped) | \(baseline.map { "\($0.overall.stripped)" } ?? "—") |")
        md.append("| Restored items (TP) | \(summary.totalRuleScore.restored) | \(baseline.map { "\($0.overall.restored)" } ?? "—") |")
        md.append("| Missed items (FN) | \(summary.totalRuleScore.missed) | \(baseline.map { "\($0.overall.missed)" } ?? "—") |")
        md.append("| Wrong changes (FP) | \(summary.totalRuleScore.wrong) | \(baseline.map { "\($0.overall.wrongChanges)" } ?? "—") |")
        md.append("| Precision | \(pct(summary.totalRuleScore.precision)) | \(baseline.map { pct($0.overall.precision) } ?? "—") |")
        md.append("| Recall | \(pct(summary.totalRuleScore.recall)) | \(baseline.map { pct($0.overall.recall) } ?? "—") |")
        md.append("| F1 Score | \(pct(summary.totalRuleScore.f1)) | \(baseline.map { pct($0.overall.f1) } ?? "—") |")
        md.append("| Edits to caret word (penalised) | \(summary.caretWordEdits) | \(baseline.map { "\($0.overall.caretWordEdits)" } ?? "—") |")
        md.append("| Protected-context changes (must be 0) | \(summary.protectedChanges) | \(baseline.map { "\($0.overall.protectedChanges)" } ?? "—") |")
        md.append("| **Net Score** | **\(pct(summary.netScore))** | **\(baseline.map { pct($0.overall.netScore) } ?? "—")** |")
        md.append("")

        md.append("## Per-Rule Scores")
        md.append("")
        md.append("| Rule | Description | Stripped | Restored | Missed | Wrong | Precision | Recall | F1 |")
        md.append("| :--- | :--- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |")
        for rule in PunctuationRule.allCases {
            let s = summary.perRule[rule] ?? RuleScore()
            md.append(
                "| `\(rule.rawValue)` | \(rule.title) | \(s.stripped) | \(s.restored) | \(s.missed) | \(s.wrong) | \(pct(s.precision)) | \(pct(s.recall)) | \(pct(s.f1)) |"
            )
        }
        md.append("")

        md.append("## Per-Document Scores")
        md.append("")
        md.append("| Document | Flavor | Stripped | Restored | Missed | Wrong | Caret Edits | Protected | Precision | Recall | Score |")
        md.append("| :--- | :--- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |")
        for doc in summary.documents {
            let s = doc.totalRuleScore
            md.append(
                "| `\(doc.name)` | \(doc.flavor.rawValue) | \(s.stripped) | \(s.restored) | \(s.missed) | \(s.wrong) | \(doc.caretWordEdits) | \(doc.protectedChanges) | \(pct(s.precision)) | \(pct(s.recall)) | \(pct(doc.netScore)) |"
            )
        }
        md.append("")

        let imperfect = summary.documents
            .filter { $0.replayed != $0.original || !$0.discrepancies.isEmpty }
            .sorted {
                if abs($0.netScore - $1.netScore) > 1e-9 { return $0.netScore < $1.netScore }
                return $0.discrepancies.count > $1.discrepancies.count
            }

        md.append("## Worst Documents With Diffs")
        md.append("")
        if imperfect.isEmpty {
            md.append("All corpus documents were restored with zero diffs.")
            md.append("")
        } else {
            for doc in imperfect.prefix(worstCount) {
                md.append("### `\(doc.name)` (Score: \(pct(doc.netScore)), Precision: \(pct(doc.totalRuleScore.precision)), Recall: \(pct(doc.totalRuleScore.recall)))")
                md.append("")
                if !doc.discrepancies.isEmpty {
                    for d in doc.discrepancies {
                        md.append("- **\(d.kind.rawValue)** (`\(d.rule.rawValue)`): expected `\(d.expected)`, got `\(d.actual)`")
                    }
                    md.append("")
                }
                let diff = lineDiff(original: doc.original, replayed: doc.replayed)
                if !diff.isEmpty {
                    md.append("```diff")
                    md.append(diff)
                    md.append("```")
                    md.append("")
                }
            }
        }

        if !failures.isEmpty {
            md.append("## Baseline Regressions")
            md.append("")
            for failure in failures {
                md.append("- ❌ \(failure)")
            }
            md.append("")
        }

        return md.joined(separator: "\n")
    }
}

// MARK: - CLI Entry Point

var corpusPath = "Tests/WritingPartnerEval/corpus"
var baselinePath = "Tests/WritingPartnerEval/baseline.json"
var reportPath = "build/writing-partner-eval/report.md"
var updateBaseline = false
var injectTypos = true
var seed: UInt64 = 0x5357_4153_48
var marginOverride: Double?

let args = Array(CommandLine.arguments.dropFirst())
var argIdx = 0
while argIdx < args.count {
    switch args[argIdx] {
    case "--corpus":
        argIdx += 1
        if argIdx < args.count { corpusPath = args[argIdx] }
    case "--baseline":
        argIdx += 1
        if argIdx < args.count { baselinePath = args[argIdx] }
    case "--report":
        argIdx += 1
        if argIdx < args.count { reportPath = args[argIdx] }
    case "--update-baseline":
        updateBaseline = true
    case "--no-typos":
        injectTypos = false
    case "--seed":
        argIdx += 1
        if argIdx < args.count, let parsed = UInt64(args[argIdx]) { seed = parsed }
    case "--margin":
        argIdx += 1
        if argIdx < args.count, let parsed = Double(args[argIdx]) { marginOverride = parsed }
    default:
        break
    }
    argIdx += 1
}

let fm = FileManager.default
guard let entries = try? fm.contentsOfDirectory(atPath: corpusPath) else {
    fputs("ERROR: Could not read corpus directory at \(corpusPath)\n", stderr)
    exit(2)
}

let files = entries.filter { $0.hasSuffix(".md") }.sorted()
guard !files.isEmpty else {
    fputs("ERROR: No Markdown files found in \(corpusPath)\n", stderr)
    exit(2)
}

var docScores: [DocumentScore] = []
for file in files {
    let fullPath = (corpusPath as NSString).appendingPathComponent(file)
    guard let content = try? String(contentsOfFile: fullPath, encoding: .utf8) else {
        fputs("ERROR: Could not read \(fullPath)\n", stderr)
        exit(2)
    }
    let flavor: MarkdownFlavor = (file.hasSuffix(".slack.md") || file.hasPrefix("slack-")) ? .slack : .github
    let strippedDoc = Stripper.strip(
        name: file,
        original: content,
        flavor: flavor,
        injectTypos: injectTypos,
        seed: seed
    )
    let replayResult = ReplayHarness.replay(strippedDoc)
    let docScore = Scorer.score(document: strippedDoc, replay: replayResult)
    docScores.append(docScore)
}

let summary = Scorer.summarize(docScores)
let defaultMargin = 0.01
let defaultRuleMargin = 0.02

let currentBaseline = EvalBaseline.from(
    summary: summary,
    seed: seed,
    margin: marginOverride ?? defaultMargin,
    ruleMargin: marginOverride ?? defaultRuleMargin
)

if updateBaseline {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    var data = try encoder.encode(currentBaseline)
    data.append(0x0A)
    let dir = (baselinePath as NSString).deletingLastPathComponent
    if !dir.isEmpty {
        try? fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
    }
    try data.write(to: URL(fileURLWithPath: baselinePath))
    print("Updated baseline at \(baselinePath)")
}

var loadedBaseline: EvalBaseline?
if let data = try? Data(contentsOf: URL(fileURLWithPath: baselinePath)),
   let decoded = try? JSONDecoder().decode(EvalBaseline.self, from: data) {
    loadedBaseline = decoded
} else if !updateBaseline {
    fputs("ERROR: Missing or invalid baseline file at \(baselinePath). Run with --update-baseline to record one.\n", stderr)
    exit(2)
}

let failures = loadedBaseline.map { EvalBaseline.check(summary: summary, against: $0, marginOverride: marginOverride) } ?? []

// Self-check that regression gates catch protected-context violations, caret-word edits and score drops
if let baseline = loadedBaseline {
    var withProtected = summary
    withProtected.protectedChanges = 1
    withProtected.protectedViolations = ["synthetic protected violation"]
    guard !EvalBaseline.check(summary: withProtected, against: baseline, marginOverride: marginOverride).isEmpty else {
        fputs("ERROR: Baseline gate failed to catch protected-context violation\n", stderr)
        exit(2)
    }

    var withCaretEdit = summary
    withCaretEdit.caretWordEdits = baseline.overall.caretWordEdits + 1
    guard !EvalBaseline.check(summary: withCaretEdit, against: baseline, marginOverride: marginOverride).isEmpty else {
        fputs("ERROR: Baseline gate failed to catch caret-word edit penalty\n", stderr)
        exit(2)
    }

    var withDroppedRecall = summary
    withDroppedRecall.totalRuleScore.restored = max(0, summary.totalRuleScore.restored - 20)
    withDroppedRecall.totalRuleScore.missed = summary.totalRuleScore.missed + 20
    guard !EvalBaseline.check(summary: withDroppedRecall, against: baseline, marginOverride: marginOverride).isEmpty else {
        fputs("ERROR: Baseline gate failed to catch recall/score drop\n", stderr)
        exit(2)
    }
}

let report = ReportGenerator.generate(summary: summary, baseline: loadedBaseline, failures: failures)

if !reportPath.isEmpty {
    let reportDir = (reportPath as NSString).deletingLastPathComponent
    if !reportDir.isEmpty {
        try? fm.createDirectory(atPath: reportDir, withIntermediateDirectories: true)
    }
    try? report.write(toFile: reportPath, atomically: true, encoding: .utf8)
}

print(report)

if !failures.isEmpty {
    fputs("WRITING PARTNER EVAL FAILED (\(failures.count) regression(s)):\n", stderr)
    for failure in failures {
        fputs("  - \(failure)\n", stderr)
    }
    exit(1)
}

print("WRITING PARTNER EVAL PASSED — Net Score: \(ReportGenerator.pct(summary.netScore)), Precision: \(ReportGenerator.pct(summary.totalRuleScore.precision)), Recall: \(ReportGenerator.pct(summary.totalRuleScore.recall)), Protected Changes: \(summary.protectedChanges), Caret Edits: \(summary.caretWordEdits)")
exit(0)


/// Sentence starts for the stripper: the rule the writing partner uses (now in the editor's
/// `TextMechanics`, which keeps it internal), copied for deciding what to lower-case.
enum EvalSentences {
    static func node(at location: Int, in document: MarkdownDocument) -> MarkdownNode {
        document.nodePath(containing: NSRange(location: location, length: 0)).last ?? document.root
    }

    private static let abbreviations: Set<String> = ["e.g", "i.e", "etc", "vs", "cf", "approx", "mr", "mrs", "ms", "dr", "st", "no", "fig", "ca", "al"]

    static func startsSentence(at start: Int, ns: NSString, document: MarkdownDocument) -> Bool {
        let text = node(at: start, in: document)
        var block = text.parent
        while let current = block, !current.kind.isBlock { block = current.parent }
        guard let block else { return false }
        switch block.kind {
        case .paragraph, .heading: break
        default: return false
        }
        var first: MarkdownNode?
        block.walk { node in if first == nil, node.kind == .text { first = node } }
        if let first, first === text, (first.range.location..<start).allSatisfy({ [0x20, 0x2A, 0x5F, 0x7E, 0x22, 0x201C, 0x28].contains(ns.character(at: $0)) }) {
            return true
        }
        var i = start
        while i > 0, [0x20, 0x2A, 0x5F, 0x7E, 0x5B, 0x28, 0x22, 0x201C].contains(ns.character(at: i - 1)) { i -= 1 }
        guard i > 0 else { return false }
        if ns.character(at: i - 1) == 0x0A { return true }
        guard i < start else { return false }
        var stop = i - 1
        let end = ns.character(at: stop)
        if end == 0x22 || end == 0x201D || end == 0x29, stop > 0 { stop -= 1 }
        let mark = ns.character(at: stop)
        if mark == 0x3F || mark == 0x21 { return true }
        guard mark == 0x2E else { return false }
        if stop > 0 {
            let before = ns.character(at: stop - 1)
            if before == 0x2E || (before >= 0x30 && before <= 0x39) { return false }
        }
        var wordStart = stop
        while wordStart > 0, TextMechanics.isWordCharacter(ns.character(at: wordStart - 1)) || ns.character(at: wordStart - 1) == 0x2E { wordStart -= 1 }
        let previous = ns.substring(with: NSRange(location: wordStart, length: stop - wordStart)).lowercased()
        return !abbreviations.contains(previous) && previous.count != 1
    }
}

//
//  WritingBandleader.swift
//  Swash
//
//  The writing partner's pause tier (#61, #101): when you pause, a "bandleader" reads the
//  paragraph you're writing and decides what should play next.
//
//  Uses the contract in Pixerate/schemas#73. Leaves out code blocks, math and tables, and never
//  sends the whole document, as the privacy text promises.
//

import Foundation
import NaturalLanguage
import Observation
import PixerateMarkdown
#if os(macOS)
import AppKit
#endif

// MARK: - Schema Types (Pixerate/schemas#73)

nonisolated enum JazzTextFlavor: String, Codable, Sendable, CaseIterable {
    case commonmark = "commonmark"
    case gfm = "gfm"
    case slack = "slack"
}

extension MarkdownFlavor {
    var jazzTextFlavor: JazzTextFlavor {
        switch self {
        case .github: return .gfm
        case .commonMark, .original: return .commonmark
        case .slack: return .slack
        }
    }
}

nonisolated enum JazzTextGenre: String, Codable, Sendable, CaseIterable {
    case prose = "prose"
    case notes = "notes"
    case chat = "chat"
    case poem = "poem"
    case dialogue = "dialogue"
    case quote = "quote"
    case list = "list"
    case technical = "technical"
    case heading = "heading"

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self).lowercased()
        switch raw {
        case "verse", "poetry", "poem": self = .poem
        case "quotation", "quote", "blockquote": self = .quote
        case "dialogue", "dialog": self = .dialogue
        default:
            guard let value = JazzTextGenre(rawValue: raw) else {
                throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unknown genre: \(raw)")
            }
            self = value
        }
    }
}

nonisolated enum JazzTextSuggestionKind: String, Codable, Sendable, CaseIterable {
    case list = "list"
    case heading = "heading"
    case math = "math"
    case title = "title"
    case alert = "alert"
    case quote = "quote"
    case spelling = "spelling"
    case wrongWord = "wrong-word"
    case houseStyle = "house-style"
    case tone = "tone"

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        switch raw {
        case "list": self = .list
        case "heading": self = .heading
        case "math": self = .math
        case "title": self = .title
        case "alert": self = .alert
        case "quote": self = .quote
        case "spelling": self = .spelling
        case "wrong-word", "wrongWord", "wrong_word": self = .wrongWord
        case "house-style", "houseStyle", "house_style", "terms", "team-terms", "vocabulary": self = .houseStyle
        case "tone": self = .tone
        default:
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Unknown JazzTextSuggestionKind: \(raw)"
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    var title: String {
        switch self {
        case .list: return "Make this a list"
        case .heading: return "Make this a heading"
        case .math: return "Format as math"
        case .title: return "Make this a title"
        case .alert: return "Format as alert"
        case .quote: return "Format as quote"
        case .spelling: return "Fix spelling"
        case .wrongWord: return "Use the right word"
        case .houseStyle: return "Follow house style"
        case .tone: return "Adjust tone"
        }
    }

    /// True when the suggestion edits words or phrases inline through the partner's cursor or
    /// underline offer (#98, #120), rather than proposing a block-level structural card.
    var isInlineEdit: Bool {
        switch self {
        case .spelling, .wrongWord, .houseStyle, .tone:
            return true
        case .list, .heading, .math, .title, .alert, .quote:
            return false
        }
    }

    /// True when the suggestion is governed by the spelling & vocabulary tier (#98, #120).
    var isSpellingKind: Bool {
        switch self {
        case .spelling, .wrongWord, .houseStyle:
            return true
        default:
            return false
        }
    }
}

nonisolated enum JazzTextVoiceId: String, Codable, Sendable, CaseIterable {
    case punctuate = "punctuate"
    case smartTypography = "smart-typography"
    case chat = "chat"
    case grammar = "grammar"
}

nonisolated enum JazzTextGrammarRule: String, Codable, Sendable, CaseIterable {
    case agreementAndTense = "agreement-and-tense"
    case missingWords = "missing-words"
    case doubledWords = "doubled-words"
    case aAndAn = "a-and-an"

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self).lowercased()
        switch raw {
        case "agreement-and-tense", "agreementandtense", "agreement", "tense", "word-form", "wordform":
            self = .agreementAndTense
        case "missing-words", "missingwords", "missing-word", "missingword", "missing":
            self = .missingWords
        case "doubled-words", "doubledwords", "doubled-word", "doubledword", "doubled":
            self = .doubledWords
        case "a-and-an", "aandan", "article", "articles":
            self = .aAndAn
        default:
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Unknown grammar rule: \(raw)"
            )
        }
    }

    var punctuationRule: PunctuationRule {
        switch self {
        case .agreementAndTense: return .agreementAndTense
        case .missingWords: return .missingWords
        case .doubledWords: return .doubledWords
        case .aAndAn: return .aAndAn
        }
    }
}

nonisolated struct JazzTextGrammarCorrection: Codable, Sendable, Equatable {
    var rule: JazzTextGrammarRule
    var range: JazzTextRange
    var replacement: String
    var confidence: Double
    var why: String?

    init(
        rule: JazzTextGrammarRule,
        range: JazzTextRange,
        replacement: String,
        confidence: Double = 1.0,
        why: String? = nil
    ) {
        self.rule = rule
        self.range = range
        self.replacement = replacement
        self.confidence = confidence
        self.why = why
    }

    enum CodingKeys: String, CodingKey {
        case rule
        case kind
        case range
        case replacement
        case confidence
        case why
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let rule = try container.decodeIfPresent(JazzTextGrammarRule.self, forKey: .rule) {
            self.rule = rule
        } else {
            self.rule = try container.decode(JazzTextGrammarRule.self, forKey: .kind)
        }
        self.range = try container.decode(JazzTextRange.self, forKey: .range)
        self.replacement = try container.decode(String.self, forKey: .replacement)
        self.confidence = try container.decodeIfPresent(Double.self, forKey: .confidence) ?? 1.0
        self.why = try container.decodeIfPresent(String.self, forKey: .why)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(rule, forKey: .rule)
        try container.encode(range, forKey: .range)
        try container.encode(replacement, forKey: .replacement)
        try container.encode(confidence, forKey: .confidence)
        try container.encodeIfPresent(why, forKey: .why)
    }
}

nonisolated struct JazzTextRange: Codable, Sendable, Equatable {
    var start: Int
    var end: Int

    init(start: Int, end: Int) {
        self.start = start
        self.end = end
    }
}

nonisolated struct JazzTextSuggestion: Codable, Sendable, Equatable {
    var id: String?
    var kind: JazzTextSuggestionKind
    var range: JazzTextRange
    var replacement: String
    var why: String
    var confidence: Double?
    var applyAtOnce: Bool?
    var checkId: String?

    init(
        id: String? = nil,
        kind: JazzTextSuggestionKind,
        range: JazzTextRange,
        replacement: String,
        why: String,
        confidence: Double? = nil,
        applyAtOnce: Bool? = nil,
        checkId: String? = nil
    ) {
        self.id = id
        self.kind = kind
        self.range = range
        self.replacement = replacement
        self.why = why
        self.confidence = confidence
        self.applyAtOnce = applyAtOnce
        self.checkId = checkId
    }

    enum CodingKeys: String, CodingKey {
        case id
        case kind
        case range
        case replacement
        case why
        case confidence
        case applyAtOnce
        case checkId
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decodeIfPresent(String.self, forKey: .id)
        self.kind = try container.decode(JazzTextSuggestionKind.self, forKey: .kind)
        self.range = try container.decode(JazzTextRange.self, forKey: .range)
        self.replacement = try container.decode(String.self, forKey: .replacement)
        self.why = try container.decodeIfPresent(String.self, forKey: .why) ?? ""
        self.confidence = try container.decodeIfPresent(Double.self, forKey: .confidence)
        self.applyAtOnce = try container.decodeIfPresent(Bool.self, forKey: .applyAtOnce)
        self.checkId = try container.decodeIfPresent(String.self, forKey: .checkId)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(id, forKey: .id)
        try container.encode(kind, forKey: .kind)
        try container.encode(range, forKey: .range)
        try container.encode(replacement, forKey: .replacement)
        try container.encode(why, forKey: .why)
        try container.encodeIfPresent(confidence, forKey: .confidence)
        try container.encodeIfPresent(applyAtOnce, forKey: .applyAtOnce)
        try container.encodeIfPresent(checkId, forKey: .checkId)
    }

    /// Stable identifier used when reporting feedback (`Pixerate/schemas#87`) even if the server omitted `id`.
    var effectiveId: String {
        id ?? "\(kind.rawValue):\(range.start)-\(range.end):\(replacement)"
    }

    /// Certain inline suggestions apply at once through the partner's cursor in Automatic mode;
    /// lower-confidence or ambiguous ones are offered as underlined suggestions (#103, #120).
    var shouldApplyAtOnce: Bool {
        guard kind.isInlineEdit else { return false }
        if let applyAtOnce { return applyAtOnce }
        if let confidence { return confidence >= 0.85 }
        return true
    }
}

// MARK: - Feedback Schema Types (Pixerate/schemas#87)

nonisolated enum JazzTextFeedbackOutcome: String, Codable, Sendable, CaseIterable {
    case accepted = "accepted"
    case edited = "edited"
    case dismissed = "dismissed"
    case ignored = "ignored"
    case undone = "undone"
}

nonisolated struct JazzTextFeedbackItem: Codable, Sendable, Equatable {
    var suggestionId: String
    var kind: JazzTextSuggestionKind
    var outcome: JazzTextFeedbackOutcome
    var original: String?
    var replacement: String
    var finalText: String?
    var checkId: String?

    init(
        suggestionId: String,
        kind: JazzTextSuggestionKind,
        outcome: JazzTextFeedbackOutcome,
        original: String? = nil,
        replacement: String,
        finalText: String? = nil,
        checkId: String? = nil
    ) {
        self.suggestionId = suggestionId
        self.kind = kind
        self.outcome = outcome
        self.original = original
        self.replacement = replacement
        self.finalText = finalText
        self.checkId = checkId
    }

    enum CodingKeys: String, CodingKey {
        case suggestionId
        case kind
        case outcome
        case original
        case replacement
        case finalText
        case checkId
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.suggestionId = try container.decode(String.self, forKey: .suggestionId)
        self.kind = try container.decode(JazzTextSuggestionKind.self, forKey: .kind)
        self.outcome = try container.decode(JazzTextFeedbackOutcome.self, forKey: .outcome)
        self.original = try container.decodeIfPresent(String.self, forKey: .original)
        self.replacement = try container.decode(String.self, forKey: .replacement)
        self.finalText = try container.decodeIfPresent(String.self, forKey: .finalText)
        self.checkId = try container.decodeIfPresent(String.self, forKey: .checkId)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(suggestionId, forKey: .suggestionId)
        try container.encode(kind, forKey: .kind)
        try container.encode(outcome, forKey: .outcome)
        try container.encodeIfPresent(original, forKey: .original)
        try container.encode(replacement, forKey: .replacement)
        try container.encodeIfPresent(finalText, forKey: .finalText)
        try container.encodeIfPresent(checkId, forKey: .checkId)
    }
}

nonisolated struct JazzTextFeedbackRequest: Codable, Sendable, Equatable {
    var items: [JazzTextFeedbackItem]
    var teamId: String?

    init(items: [JazzTextFeedbackItem], teamId: String? = nil) {
        self.items = items
        self.teamId = teamId
    }

    enum CodingKeys: String, CodingKey {
        case items
        case teamId
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.items = try container.decodeIfPresent([JazzTextFeedbackItem].self, forKey: .items) ?? []
        self.teamId = try container.decodeIfPresent(String.self, forKey: .teamId)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(items, forKey: .items)
        try container.encodeIfPresent(teamId, forKey: .teamId)
    }
}

nonisolated struct JazzTextVoice: Codable, Sendable, Equatable {
    var voice: JazzTextVoiceId
    var strength: Double
    var disabledRules: [String]?

    init(voice: JazzTextVoiceId, strength: Double = 1.0, disabledRules: [String]? = nil) {
        self.voice = voice
        self.strength = strength
        self.disabledRules = disabledRules
    }

    enum CodingKeys: String, CodingKey {
        case voice
        case strength
        case disabledRules
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.voice = try container.decode(JazzTextVoiceId.self, forKey: .voice)
        self.strength = try container.decodeIfPresent(Double.self, forKey: .strength) ?? 1.0
        self.disabledRules = try container.decodeIfPresent([String].self, forKey: .disabledRules)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(voice, forKey: .voice)
        try container.encode(strength, forKey: .strength)
        try container.encodeIfPresent(disabledRules, forKey: .disabledRules)
    }
}

nonisolated struct JazzTextVoiceStats: Codable, Sendable, Equatable {
    var kept: Int
    var undone: Int

    nonisolated init(kept: Int = 0, undone: Int = 0) {
        self.kept = kept
        self.undone = undone
    }

    enum CodingKeys: String, CodingKey {
        case kept
        case undone
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.kept = try container.decodeIfPresent(Int.self, forKey: .kept) ?? 0
        self.undone = try container.decodeIfPresent(Int.self, forKey: .undone) ?? 0
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(kept, forKey: .kept)
        try container.encode(undone, forKey: .undone)
    }
}

nonisolated struct JazzTextVoiceState: Codable, Sendable, Equatable {
    var voice: JazzTextVoiceId
    var strength: Double
    var kept: Int
    var undone: Int
    var rules: [String: JazzTextVoiceStats]

    nonisolated init(
        voice: JazzTextVoiceId,
        strength: Double = 1.0,
        kept: Int = 0,
        undone: Int = 0,
        rules: [String: JazzTextVoiceStats] = [:]
    ) {
        self.voice = voice
        self.strength = strength
        self.kept = kept
        self.undone = undone
        self.rules = rules
    }

    enum CodingKeys: String, CodingKey {
        case voice
        case strength
        case kept
        case undone
        case rules
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.voice = try container.decode(JazzTextVoiceId.self, forKey: .voice)
        self.strength = try container.decodeIfPresent(Double.self, forKey: .strength) ?? 1.0
        self.kept = try container.decodeIfPresent(Int.self, forKey: .kept) ?? 0
        self.undone = try container.decodeIfPresent(Int.self, forKey: .undone) ?? 0
        self.rules = try container.decodeIfPresent([String: JazzTextVoiceStats].self, forKey: .rules) ?? [:]
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(voice, forKey: .voice)
        try container.encode(strength, forKey: .strength)
        try container.encode(kept, forKey: .kept)
        try container.encode(undone, forKey: .undone)
        try container.encode(rules, forKey: .rules)
    }
}

nonisolated struct JazzTextLeadRequest: Codable, Sendable, Equatable {
    var paragraph: String
    var before: String?
    var after: String?
    var flavor: JazzTextFlavor
    var voices: [JazzTextVoiceState]
    var teamId: String?
    var language: String?
    var feedback: [JazzTextFeedbackItem]?

    init(
        paragraph: String,
        before: String? = nil,
        after: String? = nil,
        flavor: JazzTextFlavor = .gfm,
        voices: [JazzTextVoiceState] = [],
        teamId: String? = nil,
        language: String? = nil,
        feedback: [JazzTextFeedbackItem]? = nil
    ) {
        self.paragraph = paragraph
        self.before = before
        self.after = after
        self.flavor = flavor
        self.voices = voices
        self.teamId = teamId
        self.language = language
        self.feedback = feedback
    }

    enum CodingKeys: String, CodingKey {
        case paragraph
        case before
        case after
        case flavor
        case voices
        case teamId
        case language
        case feedback
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.paragraph = try container.decode(String.self, forKey: .paragraph)
        self.before = try container.decodeIfPresent(String.self, forKey: .before)
        self.after = try container.decodeIfPresent(String.self, forKey: .after)
        self.flavor = try container.decodeIfPresent(JazzTextFlavor.self, forKey: .flavor) ?? .gfm
        self.voices = try container.decodeIfPresent([JazzTextVoiceState].self, forKey: .voices) ?? []
        self.teamId = try container.decodeIfPresent(String.self, forKey: .teamId)
        self.language = try container.decodeIfPresent(String.self, forKey: .language)
        self.feedback = try container.decodeIfPresent([JazzTextFeedbackItem].self, forKey: .feedback)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(paragraph, forKey: .paragraph)
        try container.encodeIfPresent(before, forKey: .before)
        try container.encodeIfPresent(after, forKey: .after)
        try container.encode(flavor, forKey: .flavor)
        try container.encode(voices, forKey: .voices)
        try container.encodeIfPresent(teamId, forKey: .teamId)
        try container.encodeIfPresent(language, forKey: .language)
        try container.encodeIfPresent(feedback, forKey: .feedback)
    }
}

nonisolated struct JazzTextLeadResponse: Codable, Sendable, Equatable {
    var genre: JazzTextGenre
    var palette: [JazzTextVoice]
    var suggestions: [JazzTextSuggestion]
    var grammar: [JazzTextGrammarCorrection]
    var vocabulary: [String]?
    var why: String
    var fuelBalance: Int?

    init(
        genre: JazzTextGenre,
        palette: [JazzTextVoice],
        suggestions: [JazzTextSuggestion] = [],
        grammar: [JazzTextGrammarCorrection] = [],
        vocabulary: [String]? = nil,
        why: String,
        fuelBalance: Int? = nil
    ) {
        self.genre = genre
        self.palette = palette
        self.suggestions = suggestions
        self.grammar = grammar
        self.vocabulary = vocabulary
        self.why = why
        self.fuelBalance = fuelBalance
    }

    enum CodingKeys: String, CodingKey {
        case genre
        case palette
        case suggestions
        case grammar
        case vocabulary
        case why
        case fuelBalance
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.genre = try container.decode(JazzTextGenre.self, forKey: .genre)
        self.palette = try container.decode([JazzTextVoice].self, forKey: .palette)
        self.suggestions = try container.decodeIfPresent([JazzTextSuggestion].self, forKey: .suggestions) ?? []
        self.grammar = try container.decodeIfPresent([JazzTextGrammarCorrection].self, forKey: .grammar) ?? []
        self.vocabulary = try container.decodeIfPresent([String].self, forKey: .vocabulary)
        self.why = try container.decode(String.self, forKey: .why)
        self.fuelBalance = try container.decodeIfPresent(Int.self, forKey: .fuelBalance)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(genre, forKey: .genre)
        try container.encode(palette, forKey: .palette)
        try container.encode(suggestions, forKey: .suggestions)
        if !grammar.isEmpty {
            try container.encode(grammar, forKey: .grammar)
        }
        try container.encodeIfPresent(vocabulary, forKey: .vocabulary)
        try container.encode(why, forKey: .why)
        try container.encodeIfPresent(fuelBalance, forKey: .fuelBalance)
    }
}

// MARK: - WritingBandleader Protocol & Providers

/// Remembers suggestions dismissed, vocabulary learned, and feedback reported during the editing session.
nonisolated final class BandleaderSessionMemory: @unchecked Sendable {
    private var dismissedSuggestionKeys: Set<String> = []
    private var dismissedSuggestionIds: Set<String> = []
    private var dismissedWordReplacements: Set<String> = []
    private var learnedVocabulary: Set<String> = []
    private var feedbackHistory: [JazzTextFeedbackItem] = []

    init() {}

    func dismiss(suggestion: JazzTextSuggestion, in paragraph: String) {
        let key = makeKey(suggestion: suggestion, paragraph: paragraph)
        dismissedSuggestionKeys.insert(key)
        // Only a server id names the same suggestion across paragraphs; the derived id doesn't
        if let id = suggestion.id { dismissedSuggestionIds.insert(id) }
        let ns = paragraph as NSString
        let range = suggestion.range.nsRange
        if range.location >= 0, NSMaxRange(range) <= ns.length {
            let original = ns.substring(with: range)
            dismissWord(original, replacement: suggestion.replacement, suggestionId: suggestion.id)
        }
    }

    func dismissWord(_ original: String, replacement: String, suggestionId: String? = nil) {
        let pairKey = "\(original.lowercased())->\(replacement.lowercased())"
        dismissedWordReplacements.insert(pairKey)
        if let suggestionId {
            dismissedSuggestionIds.insert(suggestionId)
        }
        learnWord(original)
    }

    func isDismissed(suggestion: JazzTextSuggestion, in paragraph: String) -> Bool {
        if let id = suggestion.id, dismissedSuggestionIds.contains(id) {
            return true
        }
        let key = makeKey(suggestion: suggestion, paragraph: paragraph)
        if dismissedSuggestionKeys.contains(key) {
            return true
        }
        let ns = paragraph as NSString
        let range = suggestion.range.nsRange
        if range.location >= 0, NSMaxRange(range) <= ns.length {
            let original = ns.substring(with: range)
            let pairKey = "\(original.lowercased())->\(suggestion.replacement.lowercased())"
            if dismissedWordReplacements.contains(pairKey) {
                return true
            }
        }
        return false
    }

    func isWordReplacementDismissed(original: String, replacement: String, suggestionId: String? = nil) -> Bool {
        if let suggestionId, dismissedSuggestionIds.contains(suggestionId) {
            return true
        }
        let pairKey = "\(original.lowercased())->\(replacement.lowercased())"
        return dismissedWordReplacements.contains(pairKey)
    }

    func learnWord(_ word: String) {
        let trimmed = word.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        learnedVocabulary.insert(trimmed)
        learnedVocabulary.insert(trimmed.lowercased())
    }

    func learnWords(_ words: [String]) {
        for word in words {
            learnWord(word)
        }
    }

    func isKnownWord(_ word: String) -> Bool {
        let trimmed = word.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        return learnedVocabulary.contains(trimmed) || learnedVocabulary.contains(trimmed.lowercased())
    }

    var vocabulary: Set<String> {
        learnedVocabulary
    }

    func recordFeedback(_ item: JazzTextFeedbackItem) {
        feedbackHistory.append(item)
        switch item.outcome {
        case .dismissed, .undone:
            dismissedSuggestionIds.insert(item.suggestionId)
            if let original = item.original, !original.isEmpty {
                dismissWord(original, replacement: item.replacement, suggestionId: item.suggestionId)
            }
        case .accepted, .edited, .ignored:
            break
        }
    }

    var recordedFeedback: [JazzTextFeedbackItem] {
        feedbackHistory
    }

    func latestOutcome(for suggestionId: String) -> JazzTextFeedbackOutcome? {
        feedbackHistory.last(where: { $0.suggestionId == suggestionId })?.outcome
    }

    private func makeKey(suggestion: JazzTextSuggestion, paragraph: String) -> String {
        "\(suggestion.kind.rawValue):\(suggestion.replacement):\(paragraph.hashValue)"
    }

    func clear() {
        dismissedSuggestionKeys.removeAll()
        dismissedSuggestionIds.removeAll()
        dismissedWordReplacements.removeAll()
        learnedVocabulary.removeAll()
        feedbackHistory.removeAll()
    }
}

nonisolated protocol WritingBandleader: Sendable {
    func lead(request: JazzTextLeadRequest) async throws -> JazzTextLeadResponse?
    func reportFeedback(_ request: JazzTextFeedbackRequest) async
}

nonisolated extension WritingBandleader {
    func reportFeedback(_ request: JazzTextFeedbackRequest) async {}
}

/// The default bandleader when signed out, offline or switched off: local voices only.
nonisolated final class NoneWritingBandleader: WritingBandleader {
    init() {}
    func lead(request: JazzTextLeadRequest) async throws -> JazzTextLeadResponse? {
        return nil
    }
}

/// The available writing partner providers in Settings › Writing.
nonisolated enum WritingPartnerProvider: String, CaseIterable, Identifiable, Sendable {
    case none
    case onDevice
    case pixerate

    var id: String { rawValue }

    var title: String {
        switch self {
        case .none: return "None (local only)"
        case .onDevice: return "On-Device (Apple Intelligence)"
        case .pixerate: return "Pixerate"
        }
    }
}

@MainActor
enum WritingBandleaderFactory {
    static var makePixerateBandleader: () -> any WritingBandleader = {
        NoneWritingBandleader()
    }

    /// Whether Pixerate can answer: signed in. Set by the app (`installPixerateBandleader`); false
    /// where the account isn't linked (Quick Look, the test runners).
    nonisolated(unsafe) static var isPixerateAvailable: () -> Bool = { false }
    /// Whether the on-device tier can answer: Apple Intelligence available (macOS 26 and later). Set
    /// by the app (`installOnDeviceBandleader`).
    nonisolated(unsafe) static var isOnDeviceAvailable: () -> Bool = { false }
    static var makeOnDeviceBandleader: () -> any WritingBandleader = {
        NoneWritingBandleader()
    }

    static func makeBandleader(_ provider: WritingPartnerProvider) -> any WritingBandleader {
        switch provider {
        case .none:
            return NoneWritingBandleader()
        case .onDevice:
            return makeOnDeviceBandleader()
        case .pixerate:
            return makePixerateBandleader()
        }
    }
}

// MARK: - Voice Settings per Paragraph

nonisolated struct ParagraphVoiceSettings: Sendable, Equatable {
    var genre: JazzTextGenre
    var isPunctuateDisabled: Bool
    var isGrammarDisabled: Bool
    var disabledRules: Set<PunctuationRule>
    var paragraphRange: NSRange

    init(
        genre: JazzTextGenre,
        isPunctuateDisabled: Bool = false,
        isGrammarDisabled: Bool = false,
        disabledRules: Set<PunctuationRule> = [],
        paragraphRange: NSRange = NSRange(location: 0, length: 0)
    ) {
        self.genre = genre
        self.isPunctuateDisabled = isPunctuateDisabled
        self.isGrammarDisabled = isGrammarDisabled
        self.disabledRules = disabledRules
        self.paragraphRange = paragraphRange
    }

    static func from(
        response: JazzTextLeadResponse,
        paragraphRange: NSRange,
        paragraph: String? = nil
    ) -> ParagraphVoiceSettings {
        var disabled = response.genre == .poem
        var grammarDisabled = GrammarVoice.isVerseDialogueOrQuotation(
            paragraph: paragraph ?? "",
            genre: response.genre,
            why: response.why
        )
        var rules = Set<PunctuationRule>()

        for voice in response.palette {
            if voice.voice == .punctuate {
                if voice.strength <= 0 {
                    disabled = true
                }
                if let ruleStrings = voice.disabledRules {
                    for r in ruleStrings {
                        if let mapped = mapRuleName(r) {
                            rules.insert(mapped)
                        }
                    }
                }
            } else if voice.voice == .grammar {
                if voice.strength <= 0 {
                    grammarDisabled = true
                }
                if let ruleStrings = voice.disabledRules {
                    for r in ruleStrings {
                        if let mapped = mapRuleName(r) {
                            rules.insert(mapped)
                        }
                    }
                }
            }
        }

        if grammarDisabled {
            for rule in PunctuationRule.allCases where rule.isGrammar {
                rules.insert(rule)
            }
        }

        return ParagraphVoiceSettings(
            genre: response.genre,
            isPunctuateDisabled: disabled,
            isGrammarDisabled: grammarDisabled,
            disabledRules: rules,
            paragraphRange: paragraphRange
        )
    }

    private static func mapRuleName(_ name: String) -> PunctuationRule? {
        switch name.lowercased() {
        case "end-stop", "terminal-punctuation", "terminalpunctuation":
            return .terminalPunctuation
        case "sentence-case", "sentencecase":
            return .sentenceCase
        case "pronoun-i", "pronouni":
            return .pronounI
        case "contraction", "contractions":
            return .contraction
        case "spelling":
            return .spelling
        case "capitals", "ok":
            return .capitals
        case "clause-comma", "clausecomma":
            return .clauseComma
        case "doubled-words", "doubledwords", "doubled-word", "doubledword":
            return .doubledWords
        case "a-and-an", "aandan", "article", "articles":
            return .aAndAn
        case "agreement-and-tense", "agreementandtense", "agreement", "tense", "word-form", "wordform":
            return .agreementAndTense
        case "missing-words", "missingwords", "missing-word", "missingword":
            return .missingWords
        default:
            return nil
        }
    }
}

// MARK: - Privacy & Context Extraction

nonisolated enum BandleaderContextExtractor {
    /// Extracts the paragraph at `caret`, leaving out code blocks, math and tables, and never
    /// sending the whole document. Returns `nil` if the caret is inside code, math, or table,
    /// or if the paragraph is empty or exceeds 4000 characters.
    static func extract(
        from documentText: String,
        caret: Int,
        flavor: MarkdownFlavor
    ) -> (paragraph: String, range: NSRange, before: String?, after: String?)? {
        let ns = documentText as NSString
        guard ns.length > 0 else { return nil }
        let clampedCaret = max(0, min(caret, ns.length))

        let document = MarkdownDocument.parse(documentText, flavor: flavor)

        // If caret is inside code, math or table, do not send a request.
        if isExcludedAt(clampedCaret, ns: ns, document: document) {
            return nil
        }

        // Find the paragraph boundaries around the caret.
        guard let pRange = findParagraphRange(at: clampedCaret, ns: ns) else {
            return nil
        }

        let rawParagraph = ns.substring(with: pRange)
        let trimmed = rawParagraph.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, (rawParagraph as NSString).length <= 4000 else {
            return nil
        }

        // If the paragraph itself consists of a code block, math block, or table, skip it.
        if isParagraphExcluded(rawParagraph) {
            return nil
        }

        // Extract before context (up to 2000 chars, excluding code/math/tables, never whole doc).
        let beforeText = extractContext(
            from: ns,
            range: NSRange(location: 0, length: pRange.location),
            isBefore: true,
            maxChars: 2000
        )

        // Extract after context (up to 2000 chars, excluding code/math/tables, never whole doc).
        let afterStart = NSMaxRange(pRange)
        let afterLength = max(0, ns.length - afterStart)
        let afterText = extractContext(
            from: ns,
            range: NSRange(location: afterStart, length: afterLength),
            isBefore: false,
            maxChars: 2000
        )

        return (
            paragraph: rawParagraph,
            range: pRange,
            before: beforeText,
            after: afterText
        )
    }

    private static func findParagraphRange(at location: Int, ns: NSString) -> NSRange? {
        guard ns.length > 0 else { return nil }

        // Expand backward to double newline or start of string
        var start = min(location, ns.length)
        while start > 0 {
            if ns.character(at: start - 1) == 0x0A {
                if start >= 2 && ns.character(at: start - 2) == 0x0A {
                    break
                }
                if start == 1 {
                    break
                }
            }
            start -= 1
        }

        // Expand forward to double newline or end of string
        var end = min(location, ns.length)
        while end < ns.length {
            if ns.character(at: end) == 0x0A {
                if end + 1 < ns.length && ns.character(at: end + 1) == 0x0A {
                    break
                }
            }
            end += 1
        }

        // Trim leading and trailing newlines from paragraph range
        while start < end && ns.character(at: start) == 0x0A {
            start += 1
        }
        while end > start && ns.character(at: end - 1) == 0x0A {
            end -= 1
        }

        guard end > start else { return nil }
        return NSRange(location: start, length: end - start)
    }

    private static func isExcludedAt(_ location: Int, ns: NSString, document: MarkdownDocument) -> Bool {
        let loc = min(location, max(0, ns.length - 1))
        var node: MarkdownNode? = document.nodePath(containing: NSRange(location: loc, length: 0)).last
        while let current = node {
            switch current.kind {
            case .code, .codeBlock, .math, .table:
                return true
            default:
                node = current.parent
            }
        }
        return false
    }

    private static func isParagraphExcluded(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") || trimmed.hasPrefix("$$") {
            return true
        }
        if trimmed.hasPrefix("|") && trimmed.contains("|") {
            return true
        }
        return false
    }

    private static func extractContext(
        from ns: NSString,
        range: NSRange,
        isBefore: Bool,
        maxChars: Int
    ) -> String? {
        guard range.length > 0 else { return nil }

        let sliceRange: NSRange
        if isBefore {
            let start = max(range.location, NSMaxRange(range) - maxChars)
            sliceRange = NSRange(location: start, length: NSMaxRange(range) - start)
        } else {
            let len = min(range.length, maxChars)
            sliceRange = NSRange(location: range.location, length: len)
        }

        let raw = ns.substring(with: sliceRange)
        let cleaned = stripExcludedBlocks(raw).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return nil }
        return cleaned
    }

    static func stripExcludedBlocks(_ text: String) -> String {
        // Strip fenced code blocks: ```...``` or ~~~...~~~
        var result = text
        while let open = result.range(of: "```") {
            if let close = result.range(of: "```", range: open.upperBound..<result.endIndex) {
                result.removeSubrange(open.lowerBound..<close.upperBound)
            } else {
                result.removeSubrange(open.lowerBound..<result.endIndex)
                break
            }
        }
        while let open = result.range(of: "~~~") {
            if let close = result.range(of: "~~~", range: open.upperBound..<result.endIndex) {
                result.removeSubrange(open.lowerBound..<close.upperBound)
            } else {
                result.removeSubrange(open.lowerBound..<result.endIndex)
                break
            }
        }
        // Strip display math blocks: $$...$$
        while let open = result.range(of: "$$") {
            if let close = result.range(of: "$$", range: open.upperBound..<result.endIndex) {
                result.removeSubrange(open.lowerBound..<close.upperBound)
            } else {
                result.removeSubrange(open.lowerBound..<result.endIndex)
                break
            }
        }
        // Strip table rows (lines starting with | and containing |)
        let lines = result.components(separatedBy: "\n")
        let nonTableLines = lines.filter { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            return !(trimmed.hasPrefix("|") && trimmed.contains("|"))
        }
        return nonTableLines.joined(separator: "\n")
    }
}

// MARK: - Pause Detection

nonisolated final class WritingPauseDetector: @unchecked Sendable {
    typealias Clock = @Sendable () -> Date

    var pauseDelay: TimeInterval
    private let clock: Clock

    private var scheduledTime: Date?
    private var lastRequestedRevision: String?
    private var pendingParagraph: String?
    private var pendingRange: NSRange?
    private var pendingCaret: Int = 0

    init(pauseDelay: TimeInterval = 1.2, clock: @escaping Clock = { Date() }) {
        self.pauseDelay = pauseDelay
        self.clock = clock
    }

    /// True when a pause check is pending.
    var isScheduled: Bool { scheduledTime != nil }

    /// The time the scheduled check is waiting for.
    var deadline: Date? { scheduledTime }

    /// Records typing. If a sentence ended (`.` `?` `!` or Enter at sentence end), schedules a pause
    /// after `pauseDelay`. If the user continues typing, backs off by rescheduling to `now + pauseDelay`.
    func noteTyping(
        character: unichar,
        paragraph: String,
        range: NSRange,
        caret: Int,
        enterEndedSentence: Bool = false
    ) {
        pendingParagraph = paragraph
        pendingRange = range
        pendingCaret = caret

        let now = clock()
        let isSentenceEnd = character == 0x2E || character == 0x3F || character == 0x21 || enterEndedSentence

        if isSentenceEnd {
            scheduledTime = now.addingTimeInterval(pauseDelay)
        } else if scheduledTime != nil {
            // Backoff while the user keeps editing
            scheduledTime = now.addingTimeInterval(pauseDelay)
        }
    }

    /// Triggered when the caret leaves the current paragraph.
    func noteLeftParagraph(
        oldParagraph: String,
        oldRange: NSRange
    ) {
        pendingParagraph = oldParagraph
        pendingRange = oldRange
        pendingCaret = oldRange.location
        // Immediate trigger on leaving a paragraph (if revision hasn't been requested)
        scheduledTime = clock()
    }

    /// Updates the pending paragraph text and range when in-paragraph edits (like local punctuation)
    /// change the text while a pause timer is already scheduled.
    func updatePendingParagraph(
        _ paragraph: String,
        range: NSRange,
        caret: Int
    ) {
        guard scheduledTime != nil else { return }
        pendingParagraph = paragraph
        pendingRange = range
        pendingCaret = caret
    }

    /// Evaluates if a pause has occurred. Returns the paragraph and range if eligible, or nil.
    func checkPause() -> (paragraph: String, range: NSRange, caret: Int)? {
        guard let targetTime = scheduledTime, clock() >= targetTime else { return nil }
        scheduledTime = nil

        guard let paragraph = pendingParagraph, let range = pendingRange else { return nil }

        let trimmed = paragraph.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        // At most one request per paragraph revision
        if lastRequestedRevision == paragraph {
            return nil
        }

        lastRequestedRevision = paragraph
        return (paragraph: paragraph, range: range, caret: pendingCaret)
    }

    /// Cancels any scheduled pause (e.g. on undo, redo or mode change).
    func cancel() {
        scheduledTime = nil
        pendingParagraph = nil
        pendingRange = nil
    }

    /// Resets revision memory (for tests or document reload).
    func resetRevisions() {
        lastRequestedRevision = nil
    }
}


// MARK: - Quick Note tidy-up (#108)
//
// A subscription feature: the tidy-up comes from jazz on the Pixerate server (Swash#61's boundary).
// Swash proposes it on pause or save, previews it, and applies it as one undo step. There are no
// local tidy rules: without Pixerate (signed in with Pro), Quick Notes aren't tidied.

nonisolated extension JazzTextRange {
    var nsRange: NSRange { NSRange(location: start, length: end - start) }
}

extension WritingBandleaderFactory {
    /// A provider tests set instead of the app's.
    static var overrideBandleader: (any WritingBandleader)?

    /// Who tidies a Quick Note: Pixerate when it can answer, otherwise nobody (the on-device tier
    /// doesn't tidy notes, #102).
    static func currentBandleader() -> any WritingBandleader {
        if let overrideBandleader { return overrideBandleader }
        return isPixerateAvailable() ? makePixerateBandleader() : NoneWritingBandleader()
    }

    /// Calls the active pause-tier bandleader (`override` if set, else `provider`), and when the
    /// Pixerate tier returns `nil` or throws (signed out, out of Fuel `402`, rate-limited `429`,
    /// or offline), falls back to the on-device bandleader if available (#120).
    static func leadWithFallback(
        request: JazzTextLeadRequest,
        provider: WritingPartnerProvider,
        override: (any WritingBandleader)? = nil
    ) async -> (response: JazzTextLeadResponse, bandleader: any WritingBandleader)? {
        if let override {
            if let response = try? await override.lead(request: request) {
                return (response, override)
            }
            if isOnDeviceAvailable() {
                let fallback = makeOnDeviceBandleader()
                if let response = try? await fallback.lead(request: request) {
                    return (response, fallback)
                }
            }
            return nil
        }

        if let activeOverride = overrideBandleader {
            if let response = try? await activeOverride.lead(request: request) {
                return (response, activeOverride)
            }
            if isOnDeviceAvailable() {
                let fallback = makeOnDeviceBandleader()
                if let response = try? await fallback.lead(request: request) {
                    return (response, fallback)
                }
            }
            return nil
        }

        switch provider {
        case .pixerate:
            let primary = makePixerateBandleader()
            if let response = try? await primary.lead(request: request) {
                return (response, primary)
            }
            if isOnDeviceAvailable() {
                let fallback = makeOnDeviceBandleader()
                if let response = try? await fallback.lead(request: request) {
                    return (response, fallback)
                }
            }
            return nil
        case .onDevice:
            let onDevice = makeOnDeviceBandleader()
            if let response = try? await onDevice.lead(request: request) {
                return (response, onDevice)
            }
            return nil
        case .none:
            return nil
        }
    }
}

/// A bandleader that answers from a handler, for tests.
nonisolated final class StubWritingBandleader: WritingBandleader, @unchecked Sendable {
    typealias Handler = @Sendable (JazzTextLeadRequest) async throws -> JazzTextLeadResponse?
    typealias FeedbackHandler = @Sendable (JazzTextFeedbackRequest) async -> Void

    private let handler: Handler
    private let feedbackHandler: FeedbackHandler?
    private(set) var requests: [JazzTextLeadRequest] = []
    private(set) var feedbackRequests: [JazzTextFeedbackRequest] = []

    var feedbackItems: [JazzTextFeedbackItem] {
        feedbackRequests.flatMap(\.items)
    }

    init(
        handler: @escaping Handler,
        feedbackHandler: FeedbackHandler? = nil
    ) {
        self.handler = handler
        self.feedbackHandler = feedbackHandler
    }

    func lead(request: JazzTextLeadRequest) async throws -> JazzTextLeadResponse? {
        requests.append(request)
        return try await handler(request)
    }

    func reportFeedback(_ request: JazzTextFeedbackRequest) async {
        feedbackRequests.append(request)
        await feedbackHandler?(request)
    }
}

// MARK: - Bandleader Suggestion Planner (#120)

/// Plans how a `JazzTextLeadResponse` should be applied in the editor:
/// - `vocabulary`: personal and team vocabulary words learned from the server so they are neither
///   flagged nor "corrected" away by the local spell checker.
/// - `automaticEdits`: high-confidence / immediate inline spelling, wrong-word, and team-term fixes
///   played at once through the partner's cursor in Automatic mode (each as its own undo step).
/// - `offeredEdits`: lower-confidence inline suggestions (`shouldApplyAtOnce == false`) in Automatic
///   mode, or all inline suggestions in Suggest mode (#103), offered as underlined suggestions.
/// - `structuralSuggestion`: the first non-dismissed block-level structural suggestion (list, heading, etc.).
nonisolated enum BandleaderSuggestionPlanner {
    struct Plan: Sendable, Equatable {
        var voiceSettings: ParagraphVoiceSettings
        var vocabulary: [String]
        var automaticEdits: [PartnerEdit]
        var offeredEdits: [PartnerEdit]
        var structuralSuggestion: JazzTextSuggestion?
    }

    static func plan(
        response: JazzTextLeadResponse,
        paragraph: String,
        paragraphRange: NSRange,
        documentText: String,
        flavor: MarkdownFlavor = .github,
        mode: WritingPartnerMode = .automatic,
        spellingEnabled: Bool = true,
        memory: BandleaderSessionMemory
    ) -> Plan {
        let voiceSettings = ParagraphVoiceSettings.from(response: response, paragraphRange: paragraphRange)

        var learnedWords: [String] = []
        if let vocab = response.vocabulary {
            for word in vocab {
                let trimmed = word.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty, !learnedWords.contains(trimmed) {
                    learnedWords.append(trimmed)
                }
            }
            memory.learnWords(learnedWords)
        }

        let paragraphNS = paragraph as NSString
        let documentNS = documentText as NSString
        let document = MarkdownDocument.parse(documentText, flavor: flavor)
        let excludedRanges = Self.excludedRanges(in: document)

        var automaticEdits: [PartnerEdit] = []
        var offeredEdits: [PartnerEdit] = []
        var structuralSuggestion: JazzTextSuggestion?

        // Sort inline edits ascending by start offset so we can reject overlapping suggestions cleanly
        var occupiedRanges: [NSRange] = []

        for suggestion in response.suggestions {
            guard !memory.isDismissed(suggestion: suggestion, in: paragraph) else { continue }

            if !suggestion.kind.isInlineEdit {
                if structuralSuggestion == nil {
                    structuralSuggestion = suggestion
                }
                continue
            }

            if suggestion.kind.isSpellingKind && !spellingEnabled {
                continue
            }

            let localStart = suggestion.range.start
            let localEnd = suggestion.range.end
            guard localStart >= 0, localEnd >= localStart, localEnd <= paragraphNS.length else { continue }

            let localRange = NSRange(location: localStart, length: localEnd - localStart)
            let rawRange = NSRange(location: paragraphRange.location + localStart, length: localRange.length)
            guard NSMaxRange(rawRange) <= documentNS.length else { continue }

            let original = paragraphNS.substring(with: localRange)
            guard documentNS.substring(with: rawRange) == original else { continue }
            guard original != suggestion.replacement else { continue }

            // Never touch code, math, HTML, front matter, tables, or link URLs
            if excludedRanges.contains(where: { NSIntersectionRange($0, rawRange).length > 0 }) {
                continue
            }

            // If this word is in the user's vocabulary (and the suggestion isn't an explicit house-style
            // team term rule), do not flag or "correct" it away.
            if suggestion.kind != .houseStyle && memory.isKnownWord(original) {
                continue
            }

            // Skip if the user already undid or dismissed this specific word -> replacement
            if memory.isWordReplacementDismissed(
                original: original,
                replacement: suggestion.replacement,
                suggestionId: suggestion.effectiveId
            ) {
                continue
            }

            // Avoid overlapping inline edits in the same paragraph pass
            if occupiedRanges.contains(where: { NSIntersectionRange($0, rawRange).length > 0 }) {
                continue
            }
            occupiedRanges.append(rawRange)

            let rules: [PunctuationRule] = suggestion.kind.isSpellingKind ? [.spelling] : []
            let spellingWords: [String] = suggestion.kind.isSpellingKind ? [original] : []
            let edit = PartnerEdit(
                range: rawRange,
                original: original,
                replacement: suggestion.replacement,
                rules: rules,
                spellingWords: spellingWords,
                actionName: WritingPartnerDefaults.actionName,
                bandleaderSuggestionId: suggestion.effectiveId,
                bandleaderSuggestionKind: suggestion.kind,
                bandleaderCheckId: suggestion.checkId
            )

            if mode == .automatic && suggestion.shouldApplyAtOnce {
                automaticEdits.append(edit)
            } else if mode != .off {
                offeredEdits.append(edit)
            }
        }

        automaticEdits.sort { $0.range.location < $1.range.location }
        offeredEdits.sort { $0.range.location < $1.range.location }

        return Plan(
            voiceSettings: voiceSettings,
            vocabulary: learnedWords,
            automaticEdits: automaticEdits,
            offeredEdits: offeredEdits,
            structuralSuggestion: structuralSuggestion
        )
    }

    private static func excludedRanges(in document: MarkdownDocument) -> [NSRange] {
        var ranges: [NSRange] = []
        document.root.walk { node in
            switch node.kind {
            case .code, .codeBlock, .math, .htmlInline, .htmlBlock, .frontMatter, .table:
                ranges.append(node.range)
            case .link, .image:
                // Exclude the URL/title tail after the `[label]` part of a link or image
                if let lastChild = node.children.last {
                    let tailStart = NSMaxRange(lastChild.range)
                    let tailEnd = NSMaxRange(node.range)
                    if tailEnd > tailStart {
                        ranges.append(NSRange(location: tailStart, length: tailEnd - tailStart))
                    }
                } else {
                    ranges.append(node.range)
                }
            default:
                break
            }
        }
        return ranges
    }
}

// MARK: - Quick Note Tidy Proposal & Diff (#108)

nonisolated struct QuickNoteTidyDiffSegment: Equatable, Sendable {
    enum Kind: String, Equatable, Sendable {
        case unchanged
        case removed
        case inserted
    }

    var kind: Kind
    var text: String

    init(kind: Kind, text: String) {
        self.kind = kind
        self.text = text
    }
}

nonisolated struct QuickNoteTidyProposal: Equatable, Sendable {
    var originalText: String
    var tidiedText: String
    var suggestions: [JazzTextSuggestion]
    var why: String
    var diff: [QuickNoteTidyDiffSegment]

    init(
        originalText: String,
        tidiedText: String,
        suggestions: [JazzTextSuggestion],
        why: String,
        diff: [QuickNoteTidyDiffSegment]? = nil
    ) {
        self.originalText = originalText
        self.tidiedText = tidiedText
        self.suggestions = suggestions
        self.why = why
        self.diff = diff ?? Self.computeDiff(from: originalText, to: tidiedText)
    }

    /// Builds a tidy proposal by applying `response.suggestions` to `originalText`.
    /// Returns `nil` when there are no applicable suggestions or when the resulting text is unchanged.
    static func from(
        originalText: String,
        response: JazzTextLeadResponse,
        flavor: MarkdownFlavor = .github
    ) -> QuickNoteTidyProposal? {
        guard !response.suggestions.isEmpty else { return nil }
        let ns = originalText as NSString
        let length = ns.length
        let document = MarkdownDocument.parse(originalText)
        let excludedRanges = Self.excludedRanges(in: document, text: ns)

        // Sort ascending to validate bounds and filter overlaps or excluded code/math/table ranges
        let sorted = response.suggestions.sorted {
            if $0.range.start != $1.range.start { return $0.range.start < $1.range.start }
            return $0.range.end > $1.range.end
        }

        var accepted: [JazzTextSuggestion] = []
        var lastEnd = 0
        for suggestion in sorted {
            let start = suggestion.range.start
            let end = suggestion.range.end
            guard start >= 0, end >= start, end <= length, start >= lastEnd else { continue }
            let range = NSRange(location: start, length: end - start)
            // If this is a sub-range suggestion (not a whole-note replacement that already preserved exclusions),
            // reject suggestions that cut into code, math, or tables.
            if !(start == 0 && end == length) {
                let touchesExcluded = excludedRanges.contains { NSIntersectionRange($0, range).length > 0 }
                if touchesExcluded { continue }
            }
            if ns.substring(with: range) == suggestion.replacement { continue }
            accepted.append(suggestion)
            lastEnd = end
        }

        guard !accepted.isEmpty else { return nil }

        let working = NSMutableString(string: originalText)
        for suggestion in accepted.reversed() {
            working.replaceCharacters(in: suggestion.range.nsRange, with: suggestion.replacement)
        }
        let tidied = working as String
        guard tidied != originalText else { return nil }

        let rationale: String
        let trimmedWhy = response.why.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedWhy.isEmpty {
            rationale = trimmedWhy
        } else {
            var reasons: [String] = []
            for s in accepted {
                let w = s.why.trimmingCharacters(in: .whitespacesAndNewlines)
                if !w.isEmpty, !reasons.contains(w) { reasons.append(w) }
            }
            rationale = reasons.isEmpty ? "Tidy Quick Note" : reasons.joined(separator: "; ")
        }

        return QuickNoteTidyProposal(
            originalText: originalText,
            tidiedText: tidied,
            suggestions: accepted,
            why: rationale
        )
    }

    /// Computes a readable token-level diff between `oldText` and `newText` for the "Tidy" preview.
    static func computeDiff(from oldText: String, to newText: String) -> [QuickNoteTidyDiffSegment] {
        if oldText == newText {
            return oldText.isEmpty ? [] : [QuickNoteTidyDiffSegment(kind: .unchanged, text: oldText)]
        }
        let oldTokens = tokenize(oldText)
        let newTokens = tokenize(newText)
        let diff = newTokens.difference(from: oldTokens)

        var removedIndices = IndexSet()
        var insertedIndices = IndexSet()
        for change in diff {
            switch change {
            case .remove(let offset, _, _): removedIndices.insert(offset)
            case .insert(let offset, _, _): insertedIndices.insert(offset)
            }
        }

        var segments: [QuickNoteTidyDiffSegment] = []
        func append(_ kind: QuickNoteTidyDiffSegment.Kind, _ text: String) {
            guard !text.isEmpty else { return }
            if let last = segments.last, last.kind == kind {
                segments[segments.count - 1].text += text
            } else {
                segments.append(QuickNoteTidyDiffSegment(kind: kind, text: text))
            }
        }

        var i = 0
        var j = 0
        while i < oldTokens.count || j < newTokens.count {
            if i < oldTokens.count, j < newTokens.count, !removedIndices.contains(i), !insertedIndices.contains(j) {
                append(.unchanged, oldTokens[i])
                i += 1
                j += 1
                continue
            }
            while i < oldTokens.count, removedIndices.contains(i) {
                append(.removed, oldTokens[i])
                i += 1
            }
            while j < newTokens.count, insertedIndices.contains(j) {
                append(.inserted, newTokens[j])
                j += 1
            }
        }
        return segments
    }

    private static func tokenize(_ text: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        enum CharKind { case word, space, other }
        var lastKind: CharKind?

        for scalar in text.unicodeScalars {
            let kind: CharKind
            if CharacterSet.alphanumerics.contains(scalar) || scalar == "'" || scalar == "’" {
                kind = .word
            } else if scalar == " " || scalar == "\t" {
                kind = .space
            } else {
                kind = .other
            }
            if kind == .other || (lastKind != nil && lastKind != kind) {
                if !current.isEmpty {
                    tokens.append(current)
                    current = ""
                }
            }
            current.unicodeScalars.append(scalar)
            lastKind = kind
        }
        if !current.isEmpty { tokens.append(current) }
        return tokens
    }

    static func excludedRanges(in document: MarkdownDocument, text: NSString) -> [NSRange] {
        var ranges: [NSRange] = []
        document.root.walk { node in
            switch node.kind {
            case .code, .codeBlock, .math, .htmlInline, .htmlBlock, .frontMatter, .table:
                ranges.append(node.range)
            default:
                break
            }
        }
        return ranges
    }
}


// MARK: - Quick Note Pause Detector (#108)

/// Tracks typing pauses in Quick Note on an injectable clock so tests run deterministically.
nonisolated final class QuickNotePauseDetector: @unchecked Sendable {
    typealias Clock = @Sendable () -> Date

    var pauseDelay: TimeInterval
    private let clock: Clock
    private(set) var deadline: Date?
    private(set) var lastCheckedRevision: String?
    private var pendingText: String = ""

    init(pauseDelay: TimeInterval = 1.2, clock: @escaping Clock = { Date() }) {
        self.pauseDelay = pauseDelay
        self.clock = clock
    }

    var isScheduled: Bool { deadline != nil }

    /// Records an edit to the Quick Note text and schedules (or backs off) a pause check.
    func noteEdit(text: String) {
        pendingText = text
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            deadline = nil
            return
        }
        deadline = clock().addingTimeInterval(pauseDelay)
    }

    /// Evaluates whether the pause deadline has passed for an unchecked note revision.
    func checkPause(currentText: String? = nil) -> String? {
        guard let target = deadline, clock() >= target else { return nil }
        deadline = nil
        let candidate = currentText ?? pendingText
        let trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, lastCheckedRevision != candidate else { return nil }
        lastCheckedRevision = candidate
        return candidate
    }

    func markChecked(_ revision: String) {
        lastCheckedRevision = revision
        deadline = nil
    }

    func cancel() {
        deadline = nil
    }
}

// MARK: - Quick Note Tidy Session (#108)

nonisolated enum QuickNoteSaveAction: Equatable, Sendable {
    case createDocument
    case appendToTarget
}

/// Manages a Quick Note's text, pause/save tidy-up triggers, preview proposal, and single-step undo.
@MainActor
@Observable
final class QuickNoteTidySession {
    private(set) var text: String = ""
    private(set) var proposal: QuickNoteTidyProposal?
    private(set) var isChecking: Bool = false

    @ObservationIgnored let undoManager: UndoManager
    @ObservationIgnored var bandleader: any WritingBandleader
    @ObservationIgnored let defaults: UserDefaults
    @ObservationIgnored var flavor: MarkdownFlavor
    @ObservationIgnored let pauseDetector: QuickNotePauseDetector

    @ObservationIgnored var onCreate: ((String) -> Void)?
    @ObservationIgnored var onAppend: ((String) -> Void)?

    @ObservationIgnored private var pauseTask: Task<Void, Never>?
    @ObservationIgnored private var dismissedRevisions: Set<String> = []
    @ObservationIgnored private var acceptedRevisions: Set<String> = []
    @ObservationIgnored private var isApplyingProgrammaticChange = false

    #if os(macOS)
    @ObservationIgnored weak var textView: NSTextView?
    #endif

    init(
        bandleader: (any WritingBandleader)? = nil,
        defaults: UserDefaults = .standard,
        flavor: MarkdownFlavor = .github,
        pauseDelay: TimeInterval = 1.2,
        clock: @escaping QuickNotePauseDetector.Clock = { Date() },
        undoManager: UndoManager? = nil
    ) {
        self.bandleader = bandleader ?? WritingBandleaderFactory.currentBandleader()
        self.defaults = defaults
        self.flavor = flavor
        self.pauseDetector = QuickNotePauseDetector(pauseDelay: pauseDelay, clock: clock)
        let manager = undoManager ?? UndoManager()
        manager.groupsByEvent = false
        self.undoManager = manager
    }

    var isEmpty: Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var isTidyEnabled: Bool {
        WritingPartnerDefaults.quickNoteTidy(defaults)
    }

    var canUndo: Bool { undoManager.canUndo }
    var canRedo: Bool { undoManager.canRedo }
    var undoActionName: String { undoManager.undoActionName }
    var redoActionName: String { undoManager.redoActionName }

    // MARK: Editing

    /// Updates the Quick Note text from user typing, scheduling a pause check and recording undo.
    func userDidEditText(_ newText: String, scheduleLiveTimer: Bool = true) {
        guard newText != text else { return }
        let oldText = text
        text = newText

        if !isApplyingProgrammaticChange {
            registerTextUndo(from: oldText, to: newText, actionName: "Typing")
        }

        // Editing while a proposal is visible clears the stale proposal
        if let proposal, proposal.originalText != newText {
            self.proposal = nil
        }

        guard isTidyEnabled else {
            pauseDetector.cancel()
            pauseTask?.cancel()
            return
        }

        pauseDetector.noteEdit(text: newText)
        if scheduleLiveTimer {
            scheduleAutomaticPauseCheck()
        }
    }

    /// Simulates typing in tests without starting wall-clock timers.
    func type(_ newText: String) {
        userDidEditText(newText, scheduleLiveTimer: false)
        syncTextViewIfNeeded()
    }

    private func scheduleAutomaticPauseCheck() {
        pauseTask?.cancel()
        let delay = pauseDetector.pauseDelay
        guard delay > 0 else { return }
        pauseTask = Task { @MainActor [weak self] in
            let nanoseconds = UInt64(max(0.05, delay) * 1_000_000_000)
            try? await Task.sleep(nanoseconds: nanoseconds)
            guard !Task.isCancelled, let self else { return }
            _ = await self.checkPause()
        }
    }

    // MARK: Pause & Save Triggers

    /// Checks whether the pause deadline has passed and, if so, asks the bandleader for a tidy-up proposal.
    @discardableResult
    func checkPause() async -> QuickNoteTidyProposal? {
        guard isTidyEnabled else { return nil }
        guard let candidate = pauseDetector.checkPause(currentText: text) else { return nil }
        guard !dismissedRevisions.contains(candidate), !acceptedRevisions.contains(candidate) else { return nil }
        return await requestProposal(for: candidate)
    }

    /// Immediately triggers a pause tidy-up check on the current note.
    @discardableResult
    func triggerPause() async -> QuickNoteTidyProposal? {
        pauseTask?.cancel()
        guard isTidyEnabled else { return nil }
        let candidate = text
        let trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard pauseDetector.lastCheckedRevision != candidate,
              !dismissedRevisions.contains(candidate),
              !acceptedRevisions.contains(candidate) else {
            return proposal
        }
        pauseDetector.markChecked(candidate)
        return await requestProposal(for: candidate)
    }

    /// Triggered when the person saves the Quick Note ("New Document" or "Add to …").
    /// If the note hasn't been checked yet and the bandleader proposes a tidy-up, shows the "Tidy"
    /// prompt instead of saving silently and returns `false`. Once accepted, dismissed, or when no
    /// tidy-up is proposed (or Quick Note tidy-up is off in Settings), performs the save and returns `true`.
    @discardableResult
    func save(_ action: QuickNoteSaveAction = .createDocument) async -> Bool {
        pauseTask?.cancel()
        pauseDetector.cancel()
        guard !isEmpty else { return false }

        if proposal != nil {
            // A tidy proposal is already showing for the person to accept or dismiss
            return false
        }

        let current = text
        if isTidyEnabled,
           !acceptedRevisions.contains(current),
           !dismissedRevisions.contains(current),
           pauseDetector.lastCheckedRevision != current {
            pauseDetector.markChecked(current)
            if let proposed = await requestProposal(for: current), proposed.tidiedText != current {
                // Shown, never applied silently: hold save so the person can preview and accept or dismiss
                return false
            }
        }

        performSaveCallback(action)
        return true
    }

    private func performSaveCallback(_ action: QuickNoteSaveAction) {
        switch action {
        case .createDocument:
            onCreate?(text)
        case .appendToTarget:
            onAppend?(text)
        }
    }

    private func requestProposal(for snapshot: String) async -> QuickNoteTidyProposal? {
        let stats = WritingPartnerStats.load(defaults)
        var ruleStats: [String: JazzTextVoiceStats] = [:]
        var totalKept = 0
        var totalUndone = 0
        for (rule, entry) in stats.rules {
            ruleStats[rule] = JazzTextVoiceStats(kept: entry.kept, undone: entry.undone)
            totalKept += entry.kept
            totalUndone += entry.undone
        }
        let voiceState = JazzTextVoiceState(
            voice: .punctuate,
            strength: 1.0,
            kept: totalKept,
            undone: totalUndone,
            rules: ruleStats
        )
        let request = JazzTextLeadRequest(
            paragraph: snapshot,
            flavor: flavor.jazzTextFlavor,
            voices: [voiceState]
        )

        isChecking = true
        defer { isChecking = false }

        guard let response = try? await bandleader.lead(request: request) else { return nil }
        // Ensure the note wasn't edited while the request was in flight
        guard text == snapshot, isTidyEnabled else { return nil }
        guard let built = QuickNoteTidyProposal.from(originalText: snapshot, response: response, flavor: flavor) else {
            return nil
        }
        proposal = built
        return built
    }

    // MARK: Accept, Dismiss & Single-Step Undo

    /// Accepts the active tidy-up proposal, applying all of its changes as a single "Tidy" undo step.
    func acceptProposal() {
        guard let currentProposal = proposal else { return }
        proposal = nil
        let oldText = text
        let newText = currentProposal.tidiedText
        guard newText != oldText else { return }

        acceptedRevisions.insert(newText)
        pauseDetector.markChecked(newText)

        applyProgrammaticText(newText, from: oldText, actionName: WritingPartnerDefaults.tidyActionName)
    }

    /// Dismisses the active tidy-up proposal and leaves the note untouched.
    func dismissProposal() {
        guard let currentProposal = proposal else { return }
        dismissedRevisions.insert(currentProposal.originalText)
        pauseDetector.markChecked(currentProposal.originalText)
        proposal = nil
    }

    func undo() {
        guard undoManager.canUndo else { return }
        undoManager.undo()
    }

    func redo() {
        guard undoManager.canRedo else { return }
        undoManager.redo()
    }

    private func applyProgrammaticText(_ newText: String, from oldText: String, actionName: String) {
        isApplyingProgrammaticChange = true
        defer { isApplyingProgrammaticChange = false }

        text = newText
        syncTextViewIfNeeded()
        registerTextUndo(from: oldText, to: newText, actionName: actionName)
    }

    private func registerTextUndo(from oldText: String, to newText: String, actionName: String) {
        undoManager.beginUndoGrouping()
        undoManager.registerUndo(withTarget: self) { target in
            target.applyProgrammaticText(oldText, from: newText, actionName: actionName)
        }
        if !actionName.isEmpty {
            undoManager.setActionName(actionName)
        }
        undoManager.endUndoGrouping()
    }

    private func syncTextViewIfNeeded() {
        #if os(macOS)
        guard let textView, textView.string != text else { return }
        textView.string = text
        let length = (text as NSString).length
        let currentSelection = textView.selectedRange()
        if NSMaxRange(currentSelection) > length {
            textView.setSelectedRange(NSRange(location: length, length: 0))
        }
        #endif
    }
}

// MARK: - Document Language Support (#111)

nonisolated enum GrammarLanguageSupport {
    /// Languages supported by the on-device Foundation Models provider.
    static let onDeviceSupportedLanguages: Set<NLLanguage> = [
        .english, .french, .german, .italian, .portuguese, .spanish,
        .japanese, .simplifiedChinese, .traditionalChinese, .korean,
    ]

    /// Languages supported by the Pixerate server provider.
    static let pixerateSupportedLanguages: Set<NLLanguage> = [
        .english, .french, .german, .italian, .portuguese, .spanish, .dutch,
        .japanese, .simplifiedChinese, .traditionalChinese, .korean,
    ]

    private static let englishMarkers: Set<String> = [
        "the", "and", "is", "are", "was", "were", "to", "of", "in", "that", "it",
        "for", "with", "as", "on", "but", "be", "at", "or", "from", "an", "by",
        "not", "have", "has", "had", "this", "they", "you", "we", "she", "he",
        "went", "shop", "results", "shows", "should", "would", "could", "better",
        "walked", "says", "said", "dont", "doesnt", "didnt", "cant", "wont",
    ]

    /// Detects the dominant language of `text`, stripping excluded Markdown blocks first.
    /// Defaults to `.english` when the prose sample is short or undetermined.
    static func detectLanguage(in text: String) -> NLLanguage {
        let stripped = BandleaderContextExtractor.stripExcludedBlocks(text)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard stripped.count >= 12 else { return .english }

        let words = stripped.lowercased()
            .components(separatedBy: CharacterSet.letters.inverted)
            .filter { !$0.isEmpty }
        let isAllASCII = stripped.unicodeScalars.allSatisfy { $0.value < 128 }
        if isAllASCII, words.contains(where: { englishMarkers.contains($0) }) {
            // Check that there aren't strong non-ASCII diacritics; short ASCII texts with English function words are English
            let englishHits = words.filter { englishMarkers.contains($0) }.count
            if englishHits >= 1 && words.count <= 12 {
                return .english
            }
            if Double(englishHits) / Double(max(1, words.count)) >= 0.15 {
                return .english
            }
        }

        let recognizer = NLLanguageRecognizer()
        recognizer.processString(stripped)
        guard let dominant = recognizer.dominantLanguage, dominant != .undetermined else {
            return .english
        }
        return dominant
    }

    static func supportedLanguages(for provider: WritingPartnerProvider) -> Set<NLLanguage> {
        switch provider {
        case .none:
            return []
        case .onDevice:
            return onDeviceSupportedLanguages
        case .pixerate:
            return pixerateSupportedLanguages
        }
    }

    static func isSupported(_ language: NLLanguage, by provider: WritingPartnerProvider) -> Bool {
        supportedLanguages(for: provider).contains(language)
    }

    static func displayName(for language: NLLanguage) -> String {
        Locale(identifier: "en").localizedString(forLanguageCode: language.rawValue) ?? language.rawValue
    }

    static func providerDisplayName(_ provider: WritingPartnerProvider) -> String {
        switch provider {
        case .none: return "local rules"
        case .onDevice: return "Apple Intelligence"
        case .pixerate: return "Pixerate"
        }
    }

    /// Reason shown in Settings › Writing when the document's language is not supported by `provider`.
    /// Returns `nil` when `provider == .none` or when `language` is supported.
    static func unsupportedReason(for language: NLLanguage, provider: WritingPartnerProvider) -> String? {
        guard provider != .none, !isSupported(language, by: provider) else { return nil }
        let langName = displayName(for: language)
        let provName = providerDisplayName(provider)
        return "Off for \(langName) (not supported by \(provName))"
    }
}

// MARK: - Pause-Tier Grammar Evaluation & Local Sentence Analyzer (#111)

nonisolated extension GrammarVoice {
    /// True when the bandleader reads the paragraph as verse, dialogue or a quotation.
    static func isVerseDialogueOrQuotation(
        paragraph: String,
        in documentText: String? = nil,
        paragraphRange: NSRange? = nil,
        genre: JazzTextGenre,
        why: String = ""
    ) -> Bool {
        if genre == .poem || genre == .dialogue || genre == .quote {
            return true
        }
        let lowerWhy = why.lowercased()
        if lowerWhy.contains("verse") || lowerWhy.contains("poem") || lowerWhy.contains("poetry")
            || lowerWhy.contains("dialogue") || lowerWhy.contains("quotation") || lowerWhy.contains("blockquote") {
            return true
        }
        let trimmed = paragraph.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }

        // Block quote ("> ...")
        let lines = trimmed.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        if let first = lines.first, first.hasPrefix(">") {
            return true
        }

        // Check Markdown AST if full document and range are provided
        if let documentText, let paragraphRange, paragraphRange.location < (documentText as NSString).length {
            let doc = MarkdownDocument.parse(documentText)
            var current: MarkdownNode? = node(at: paragraphRange.location, in: doc)
            while let n = current {
                if n.kind == .blockQuote { return true }
                current = n.parent
            }
        }

        // Quoted paragraph or dialogue paragraph (starts and ends with quotation marks, or dialogue lines starting with quotes/em-dash)
        if (trimmed.hasPrefix("\"") && trimmed.hasSuffix("\""))
            || (trimmed.hasPrefix("“") && trimmed.hasSuffix("”"))
            || (trimmed.hasPrefix("‘") && trimmed.hasSuffix("’")) {
            return true
        }
        if lines.allSatisfy({ $0.hasPrefix("\"") || $0.hasPrefix("“") || $0.hasPrefix("—") }) {
            return true
        }
        return false
    }

    /// Word range containing `caret` in `text`, if `caret` is inside or immediately touching a word.
    static func caretWordRange(at caret: Int, in text: NSString) -> NSRange? {
        guard caret >= 0, caret <= text.length else { return nil }
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

    /// Evaluates pause-tier grammar corrections returned by the bandleader in `response.grammar`,
    /// splitting them into `automatic` edits (played through the partner's cursor as undo steps)
    /// and `suggestions` (offered in Suggest mode or when confidence is below `autoConfidenceThreshold`).
    static func pauseEdits(
        from response: JazzTextLeadResponse,
        paragraph: String,
        paragraphRange: NSRange,
        documentText: String,
        caret: Int? = nil,
        flavor: MarkdownFlavor = .github,
        provider: WritingPartnerProvider = .pixerate,
        mode: WritingPartnerMode = .automatic,
        languageOverride: NLLanguage? = nil,
        isActive: (PunctuationRule) -> Bool = { _ in true }
    ) -> (automatic: [PartnerEdit], suggestions: [PartnerEdit]) {
        guard mode != .off, flavor != .slack, !response.grammar.isEmpty else {
            return ([], [])
        }

        // Check document language support
        let language = languageOverride ?? GrammarLanguageSupport.detectLanguage(in: documentText)
        guard GrammarLanguageSupport.isSupported(language, by: provider) else {
            return ([], [])
        }

        // Off for verse, dialogue, or quotation
        guard !isVerseDialogueOrQuotation(
            paragraph: paragraph,
            in: documentText,
            paragraphRange: paragraphRange,
            genre: response.genre,
            why: response.why
        ) else {
            return ([], [])
        }

        let settings = ParagraphVoiceSettings.from(response: response, paragraphRange: paragraphRange, paragraph: paragraph)
        guard !settings.isPunctuateDisabled, !settings.isGrammarDisabled else {
            return ([], [])
        }

        let docNS = documentText as NSString
        let paraNS = paragraph as NSString
        guard paragraphRange.location >= 0,
              NSMaxRange(paragraphRange) <= docNS.length,
              paragraphRange.length == paraNS.length else {
            return ([], [])
        }

        let document = MarkdownDocument.parse(documentText)
        let activeCaretWord = caret.flatMap { caretWordRange(at: $0, in: docNS) }

        let sorted = response.grammar.sorted {
            if $0.range.start != $1.range.start { return $0.range.start < $1.range.start }
            return $0.range.end < $1.range.end
        }

        var automatic: [PartnerEdit] = []
        var suggested: [PartnerEdit] = []
        var lastEnd = 0

        for item in sorted {
            guard item.confidence >= suggestConfidenceThreshold else { continue }
            let start = item.range.start
            let end = item.range.end
            guard start >= 0, end > start, end <= paraNS.length, start >= lastEnd else { continue }

            let rule = item.rule.punctuationRule
            guard isActive(rule), !settings.disabledRules.contains(rule) else { continue }

            let rawRange = NSRange(location: paragraphRange.location + start, length: end - start)
            let original = docNS.substring(with: rawRange)
            let replacement = item.replacement
            guard original != replacement,
                  !replacement.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !replacement.contains("\n") else {
                continue
            }

            // "It corrects, it doesn't rewrite. A correction changes at most a few words and never the meaning."
            let origWords = original.split(whereSeparator: { $0.isWhitespace })
            let repWords = replacement.split(whereSeparator: { $0.isWhitespace })
            guard origWords.count <= maxCorrectionWords,
                  repWords.count <= maxCorrectionWords,
                  abs(repWords.count - origWords.count) <= 2 else {
                continue
            }

            // Never in the word the caret is in
            if let caretWord = activeCaretWord, NSIntersectionRange(rawRange, caretWord).length > 0 {
                continue
            }
            if let c = caret, c >= rawRange.location && c <= NSMaxRange(rawRange) {
                continue
            }

            // Never inside code, math, HTML, front matter, link destinations or tables
            guard isProseRange(rawRange, in: docNS, document: document) else {
                continue
            }

            // Widen to whole words in the document so the cursor selects and types whole words
            let widened = PunctuateVoice.word(around: rawRange, in: docNS)
            guard isProseRange(widened, in: docNS, document: document) else {
                continue
            }
            if let caretWord = activeCaretWord, NSIntersectionRange(widened, caretWord).length > 0 {
                continue
            }
            let prefixLen = rawRange.location - widened.location
            let suffixLen = NSMaxRange(widened) - NSMaxRange(rawRange)
            let prefixStr = prefixLen > 0 ? docNS.substring(with: NSRange(location: widened.location, length: prefixLen)) : ""
            let suffixStr = suffixLen > 0 ? docNS.substring(with: NSRange(location: NSMaxRange(rawRange), length: suffixLen)) : ""
            let widenedOriginal = docNS.substring(with: widened)
            let widenedReplacement = prefixStr + replacement + suffixStr

            let partnerEdit = PartnerEdit(
                range: widened,
                original: widenedOriginal,
                replacement: widenedReplacement,
                rules: [rule],
                spellingWords: []
            )

            lastEnd = end
            if mode == .suggest || item.confidence < autoConfidenceThreshold {
                suggested.append(partnerEdit)
            } else {
                automatic.append(partnerEdit)
            }
        }

        return (automatic, suggested)
    }

    // MARK: Local Deterministic Sentence Grammar Analyzer

    /// Analyzes `paragraph` for high-precision pause-tier grammar fixes (subject-verb agreement,
    /// mid-sentence tense slips, missing small words, and wrong word forms) outside excluded spans.
    static func analyzeParagraph(_ paragraph: String, flavor: MarkdownFlavor = .github) -> [JazzTextGrammarCorrection] {
        guard flavor != .slack else { return [] }
        let ns = paragraph as NSString
        guard ns.length > 0 else { return [] }
        let document = MarkdownDocument.parse(paragraph)
        guard !isVerseDialogueOrQuotation(paragraph: paragraph, in: paragraph, paragraphRange: NSRange(location: 0, length: ns.length), genre: .prose) else {
            return []
        }

        struct PatternRule {
            var regex: NSRegularExpression
            var rule: JazzTextGrammarRule
            var confidence: Double
            var why: String
            var transform: (String, NSTextCheckingResult, NSString) -> (range: NSRange, replacement: String)?
        }

        var patterns: [PatternRule] = []

        func addSimple(
            _ pattern: String,
            rule: JazzTextGrammarRule,
            confidence: Double,
            why: String,
            replacement: @escaping (String) -> String?
        ) {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return }
            patterns.append(PatternRule(regex: regex, rule: rule, confidence: confidence, why: why) { _, match, text in
                let r = match.range(at: 1)
                guard r.location != NSNotFound else { return nil }
                let matched = text.substring(with: r)
                guard let rep = replacement(matched), rep != matched else { return nil }
                return (r, preserveLeadingCase(from: matched, to: rep))
            })
        }

        // 1. Wrong word form: "should of", "could of", "would of", "must of", "might of" (not "of course" / "of all")
        addSimple(
            "\\b((?:should|could|would|must|might|may)\\s+of)\\b(?!\\s+(?:course|all|necessity|itself|theirs|ours|yours))",
            rule: .agreementAndTense,
            confidence: 0.92,
            why: "Use 'have' instead of 'of' after a modal verb"
        ) { matched in
            let parts = matched.split(whereSeparator: { $0.isWhitespace })
            guard parts.count == 2 else { return nil }
            return "\(parts[0]) have"
        }

        // 2. Wrong word form: double comparatives / superlatives ("more better" → "better", "more worse" → "worse")
        let comparatives = "better|worse|faster|slower|easier|harder|clearer|simpler|stronger|smaller|bigger|larger|higher|lower|older|younger|sooner|cleaner|safer|cheaper|shorter|longer"
        addSimple(
            "\\b(more\\s+(?:\(comparatives)))\\b",
            rule: .agreementAndTense,
            confidence: 0.92,
            why: "Avoid double comparative"
        ) { matched in
            let parts = matched.split(whereSeparator: { $0.isWhitespace })
            guard parts.count == 2 else { return nil }
            return String(parts[1])
        }

        let superlatives = "best|worst|fastest|slowest|easiest|hardest|clearest|simplest|strongest|smallest|biggest|largest|highest|lowest|oldest|youngest|soonest|cleanest|safest|cheapest"
        addSimple(
            "\\b(most\\s+(?:\(superlatives)))\\b",
            rule: .agreementAndTense,
            confidence: 0.92,
            why: "Avoid double superlative"
        ) { matched in
            let parts = matched.split(whereSeparator: { $0.isWhitespace })
            guard parts.count == 2 else { return nil }
            return String(parts[1])
        }

        // 3. Subject and verb agreement ("the results shows" → "the results show", etc.)
        let pluralNouns = "results|tests|changes|numbers|files|rules|errors|items|notes|lines|words|checks|steps|updates|options|settings|documents|pages|tables|links|users|servers|clients|events|messages|logs|metrics|values|keys|fields|columns|rows|tasks|issues|fixes"
        let singularVerbsToPlural: [String: String] = [
            "shows": "show", "fails": "fail", "breaks": "break", "tells": "tell",
            "needs": "need", "works": "work", "happens": "happen", "makes": "make",
            "takes": "take", "gives": "give", "keeps": "keep", "comes": "come",
            "goes": "go", "runs": "run", "passes": "pass", "matches": "match",
            "contains": "contain", "includes": "include", "requires": "require",
            "remains": "remain", "appears": "appear", "looks": "look", "seems": "seem",
            "is": "are", "was": "were", "has": "have", "does": "do", "doesn't": "don't",
        ]
        let verbKeys = singularVerbsToPlural.keys.sorted().joined(separator: "|")
        addSimple(
            "\\b(?:the|these|those|our|their|many|several|both|all)\\s+(?:\(pluralNouns))\\s+(\(verbKeys))\\b",
            rule: .agreementAndTense,
            confidence: 0.89,
            why: "Plural subject takes a plural verb"
        ) { matched in
            singularVerbsToPlural[matched.lowercased()]
        }

        // Pronoun-verb agreement ("they was" → "they were", "we was" → "we were", "he don't" → "he doesn't")
        addSimple(
            "\\b(?:they|we|you)\\s+(was|is|has|does)\\b",
            rule: .agreementAndTense,
            confidence: 0.90,
            why: "Subject-verb agreement"
        ) { matched in
            switch matched.lowercased() {
            case "was": return "were"
            case "is": return "are"
            case "has": return "have"
            case "does": return "do"
            default: return nil
            }
        }

        addSimple(
            "\\b(?:he|she|it)\\s+(don't|dont|have)\\b",
            rule: .agreementAndTense,
            confidence: 0.90,
            why: "Singular subject takes a singular verb"
        ) { matched in
            switch matched.lowercased() {
            case "don't", "dont": return "doesn't"
            case "have": return "has"
            default: return nil
            }
        }

        // 4. Tense that slips mid-sentence ("walked in and says" → "walked in and said", etc.)
        let pastVerbs = "walked|opened|sat|looked|ran|finished|clicked|closed|read|took|called|turned|checked|started|stopped|entered|left|wrote|sent|built|pushed|pulled|merged|deployed|typed|pressed|moved|came|went|saw|heard|asked|answered|picked|grabbed|dropped"
        let presentToPast: [String: String] = [
            "says": "said", "writes": "wrote", "starts": "started", "asks": "asked",
            "sees": "saw", "sends": "sent", "waits": "waited", "leaves": "left",
            "replies": "replied", "arrives": "arrived", "tells": "told", "goes": "went",
            "finds": "found", "takes": "took", "makes": "made", "gives": "gave",
            "comes": "came", "runs": "ran", "opens": "opened", "closes": "closed",
            "clicks": "clicked", "turns": "turned", "calls": "called", "checks": "checked",
            "looks": "looked", "walks": "walked", "sits": "sat", "stops": "stopped",
            "drops": "dropped", "picks": "picked", "grabs": "grabbed", "throws": "threw",
        ]
        let presentKeys = presentToPast.keys.sorted().joined(separator: "|")
        addSimple(
            "\\b(?:\(pastVerbs))(?:\\s+[A-Za-z']+){0,4},?\\s+and\\s+(\(presentKeys))\\b",
            rule: .agreementAndTense,
            confidence: 0.86,
            why: "Keep past tense consistent within the sentence"
        ) { matched in
            presentToPast[matched.lowercased()]
        }

        // 5. Missing small word ("went the shop" → "went to the shop", etc.)
        let destinationNouns = "shop|store|office|station|meeting|market|park|airport|room|desk|table|window|door|page|file|line|top|bottom|server| hospital|school|bank|library|gym|hotel|beach|doctor|kitchen|garden|conference|team|group|guide|manual|message|email|music|podcast"
        addSimple(
            "\\b((?:went|walked|drove|returned|headed|ran|flew|moved|replied|listened|talked|spoke|belongs|belonged|happened|refer|referred)\\s+(?:the|a|an|my|our|their|his|her)\\s+(?:\(destinationNouns)))\\b",
            rule: .missingWords,
            confidence: 0.88,
            why: "Insert missing 'to'"
        ) { matched in
            let parts = matched.split(whereSeparator: { $0.isWhitespace })
            guard parts.count == 3 else { return nil }
            return "\(parts[0]) to \(parts[1]) \(parts[2])"
        }

        addSimple(
            "\\b((?:a\\s+lot|a\\s+couple|one|some|none|most|both)\\s+the\\s+[A-Za-z]+)\\b",
            rule: .missingWords,
            confidence: 0.87,
            why: "Insert missing 'of'"
        ) { matched in
            guard let theRange = matched.range(of: "\\s+the\\s+", options: [.regularExpression, .caseInsensitive]) else { return nil }
            var out = matched
            out.replaceSubrange(theRange, with: " of the ")
            return out
        }

        addSimple(
            "\\b(a\\s+lot\\s+(?:people|work|time|money|things|files|changes|errors|items|questions|users))\\b",
            rule: .missingWords,
            confidence: 0.87,
            why: "Insert missing 'of'"
        ) { matched in
            let parts = matched.split(whereSeparator: { $0.isWhitespace })
            guard parts.count == 3 else { return nil }
            return "\(parts[0]) \(parts[1]) of \(parts[2])"
        }

        addSimple(
            "\\b((?:needs|needed|need|has|have|had|ought)\\s+to\\s+(?:fixed|updated|done|checked|removed|added|changed|tested|built|closed|opened|saved))\\b",
            rule: .missingWords,
            confidence: 0.88,
            why: "Insert missing 'be'"
        ) { matched in
            let parts = matched.split(whereSeparator: { $0.isWhitespace })
            guard parts.count == 3 else { return nil }
            return "\(parts[0]) \(parts[1]) be \(parts[2])"
        }

        var rawCorrections: [JazzTextGrammarCorrection] = []
        let fullRange = NSRange(location: 0, length: ns.length)

        for p in patterns {
            let matches = p.regex.matches(in: paragraph, options: [], range: fullRange)
            for match in matches {
                guard let (range, replacement) = p.transform(paragraph, match, ns),
                      isProseRange(range, in: ns, document: document) else {
                    continue
                }
                rawCorrections.append(JazzTextGrammarCorrection(
                    rule: p.rule,
                    range: JazzTextRange(start: range.location, end: NSMaxRange(range)),
                    replacement: replacement,
                    confidence: p.confidence,
                    why: p.why
                ))
            }
        }

        // Sort and deduplicate overlapping corrections
        let sorted = rawCorrections.sorted {
            if $0.range.start != $1.range.start { return $0.range.start < $1.range.start }
            return $0.range.end < $1.range.end
        }
        var accepted: [JazzTextGrammarCorrection] = []
        var lastEnd = 0
        for corr in sorted where corr.range.start >= lastEnd {
            accepted.append(corr)
            lastEnd = corr.range.end
        }
        return accepted
    }

    private static func preserveLeadingCase(from original: String, to replacement: String) -> String {
        guard let firstOrig = original.first, firstOrig.isUppercase,
              !original.dropFirst().contains(where: { $0.isUppercase }),
              let firstRep = replacement.first, firstRep.isLowercase else {
            return replacement
        }
        return replacement.prefix(1).uppercased() + replacement.dropFirst()
    }
}


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
    case list = "list"
    case technical = "technical"
    case heading = "heading"
}

nonisolated enum JazzTextSuggestionKind: String, Codable, Sendable, CaseIterable {
    case list = "list"
    case heading = "heading"
    case math = "math"
    case title = "title"
    case alert = "alert"
    case quote = "quote"

    var title: String {
        switch self {
        case .list: return "Make this a list"
        case .heading: return "Make this a heading"
        case .math: return "Format as math"
        case .title: return "Make this a title"
        case .alert: return "Format as alert"
        case .quote: return "Format as quote"
        }
    }
}

nonisolated enum JazzTextVoiceId: String, Codable, Sendable, CaseIterable {
    case punctuate = "punctuate"
    case smartTypography = "smart-typography"
    case chat = "chat"
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
    var kind: JazzTextSuggestionKind
    var range: JazzTextRange
    var replacement: String
    var why: String

    init(kind: JazzTextSuggestionKind, range: JazzTextRange, replacement: String, why: String) {
        self.kind = kind
        self.range = range
        self.replacement = replacement
        self.why = why
    }
}

/// A word-level spelling or real-word correction from the pause-tier bandleader (#98).
nonisolated struct JazzTextSpellingCorrection: Codable, Sendable, Equatable {
    var range: JazzTextRange
    var original: String?
    var replacement: String
    var confidence: Double
    var why: String?

    init(
        range: JazzTextRange,
        original: String? = nil,
        replacement: String,
        confidence: Double = 1.0,
        why: String? = nil
    ) {
        self.range = range
        self.original = original
        self.replacement = replacement
        self.confidence = confidence
        self.why = why
    }

    enum CodingKeys: String, CodingKey {
        case range
        case original
        case replacement
        case confidence
        case why
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.range = try container.decode(JazzTextRange.self, forKey: .range)
        self.original = try container.decodeIfPresent(String.self, forKey: .original)
        self.replacement = try container.decode(String.self, forKey: .replacement)
        self.confidence = try container.decodeIfPresent(Double.self, forKey: .confidence) ?? 1.0
        self.why = try container.decodeIfPresent(String.self, forKey: .why)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(range, forKey: .range)
        try container.encodeIfPresent(original, forKey: .original)
        try container.encode(replacement, forKey: .replacement)
        try container.encode(confidence, forKey: .confidence)
        try container.encodeIfPresent(why, forKey: .why)
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
    var vocabulary: [String]?
    var teamId: String?

    init(
        paragraph: String,
        before: String? = nil,
        after: String? = nil,
        flavor: JazzTextFlavor = .gfm,
        voices: [JazzTextVoiceState] = [],
        vocabulary: [String]? = nil,
        teamId: String? = nil
    ) {
        self.paragraph = paragraph
        self.before = before
        self.after = after
        self.flavor = flavor
        self.voices = voices
        self.vocabulary = vocabulary
        self.teamId = teamId
    }

    enum CodingKeys: String, CodingKey {
        case paragraph
        case before
        case after
        case flavor
        case voices
        case vocabulary
        case teamId
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.paragraph = try container.decode(String.self, forKey: .paragraph)
        self.before = try container.decodeIfPresent(String.self, forKey: .before)
        self.after = try container.decodeIfPresent(String.self, forKey: .after)
        self.flavor = try container.decodeIfPresent(JazzTextFlavor.self, forKey: .flavor) ?? .gfm
        self.voices = try container.decodeIfPresent([JazzTextVoiceState].self, forKey: .voices) ?? []
        self.vocabulary = try container.decodeIfPresent([String].self, forKey: .vocabulary)
        self.teamId = try container.decodeIfPresent(String.self, forKey: .teamId)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(paragraph, forKey: .paragraph)
        try container.encodeIfPresent(before, forKey: .before)
        try container.encodeIfPresent(after, forKey: .after)
        try container.encode(flavor, forKey: .flavor)
        try container.encode(voices, forKey: .voices)
        if let vocabulary, !vocabulary.isEmpty {
            try container.encode(vocabulary, forKey: .vocabulary)
        }
        try container.encodeIfPresent(teamId, forKey: .teamId)
    }
}

nonisolated struct JazzTextLeadResponse: Codable, Sendable, Equatable {
    var genre: JazzTextGenre
    var palette: [JazzTextVoice]
    var suggestions: [JazzTextSuggestion]
    var spelling: [JazzTextSpellingCorrection]
    var why: String
    var fuelBalance: Int?

    init(
        genre: JazzTextGenre,
        palette: [JazzTextVoice],
        suggestions: [JazzTextSuggestion] = [],
        spelling: [JazzTextSpellingCorrection] = [],
        why: String,
        fuelBalance: Int? = nil
    ) {
        self.genre = genre
        self.palette = palette
        self.suggestions = suggestions
        self.spelling = spelling
        self.why = why
        self.fuelBalance = fuelBalance
    }

    enum CodingKeys: String, CodingKey {
        case genre
        case palette
        case suggestions
        case spelling
        case why
        case fuelBalance
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.genre = try container.decode(JazzTextGenre.self, forKey: .genre)
        self.palette = try container.decode([JazzTextVoice].self, forKey: .palette)
        self.suggestions = try container.decodeIfPresent([JazzTextSuggestion].self, forKey: .suggestions) ?? []
        self.spelling = try container.decodeIfPresent([JazzTextSpellingCorrection].self, forKey: .spelling) ?? []
        self.why = try container.decode(String.self, forKey: .why)
        self.fuelBalance = try container.decodeIfPresent(Int.self, forKey: .fuelBalance)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(genre, forKey: .genre)
        try container.encode(palette, forKey: .palette)
        try container.encode(suggestions, forKey: .suggestions)
        if !spelling.isEmpty {
            try container.encode(spelling, forKey: .spelling)
        }
        try container.encode(why, forKey: .why)
        try container.encodeIfPresent(fuelBalance, forKey: .fuelBalance)
    }
}

// MARK: - WritingBandleader Protocol & Providers

/// Remembers suggestions dismissed during the editing session so the bandleader learns for the session.
nonisolated final class BandleaderSessionMemory: @unchecked Sendable {
    private var dismissedSuggestionKeys: Set<String> = []

    init() {}

    func dismiss(suggestion: JazzTextSuggestion, in paragraph: String) {
        let key = makeKey(suggestion: suggestion, paragraph: paragraph)
        dismissedSuggestionKeys.insert(key)
    }

    func isDismissed(suggestion: JazzTextSuggestion, in paragraph: String) -> Bool {
        let key = makeKey(suggestion: suggestion, paragraph: paragraph)
        return dismissedSuggestionKeys.contains(key)
    }

    private func makeKey(suggestion: JazzTextSuggestion, paragraph: String) -> String {
        "\(suggestion.kind.rawValue):\(suggestion.replacement):\(paragraph.hashValue)"
    }

    func clear() {
        dismissedSuggestionKeys.removeAll()
    }
}

nonisolated protocol WritingBandleader: Sendable {
    func lead(request: JazzTextLeadRequest) async throws -> JazzTextLeadResponse?
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
    var disabledRules: Set<PunctuationRule>
    var paragraphRange: NSRange

    init(
        genre: JazzTextGenre,
        isPunctuateDisabled: Bool = false,
        disabledRules: Set<PunctuationRule> = [],
        paragraphRange: NSRange = NSRange(location: 0, length: 0)
    ) {
        self.genre = genre
        self.isPunctuateDisabled = isPunctuateDisabled
        self.disabledRules = disabledRules
        self.paragraphRange = paragraphRange
    }

    static func from(response: JazzTextLeadResponse, paragraphRange: NSRange) -> ParagraphVoiceSettings {
        var disabled = response.genre == .poem
        var rules = Set<PunctuationRule>()

        for voice in response.palette where voice.voice == .punctuate {
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
        }

        return ParagraphVoiceSettings(
            genre: response.genre,
            isPunctuateDisabled: disabled,
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

extension JazzTextRange {
    nonisolated var nsRange: NSRange { NSRange(location: start, length: end - start) }
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
}

/// A bandleader that answers from a handler, for tests.
nonisolated final class StubWritingBandleader: WritingBandleader, @unchecked Sendable {
    typealias Handler = @Sendable (JazzTextLeadRequest) async throws -> JazzTextLeadResponse?

    private let handler: Handler
    private(set) var requests: [JazzTextLeadRequest] = []

    init(handler: @escaping Handler) {
        self.handler = handler
    }

    func lead(request: JazzTextLeadRequest) async throws -> JazzTextLeadResponse? {
        requests.append(request)
        return try await handler(request)
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

// MARK: - Document Vocabulary & Context-Aware Spelling (#98)

/// Extracts the person's own vocabulary (names, product terms and jargon that recur in the document)
/// so neither the typing-tier spell checker nor the pause-tier bandleader corrects them away (#98).
nonisolated enum DocumentVocabulary {
    /// Lowercased words that appear at least `minimumOccurrences` times in `text`, excluding
    /// common confusables and unambiguous misspellings so real-word errors and typos are still fixed
    /// even if repeated.
    static func recurringWords(in text: String, minimumOccurrences: Int = 2) -> Set<String> {
        guard minimumOccurrences > 1 else { return [] }
        let ns = text as NSString
        let length = ns.length
        guard length > 0 else { return [] }

        var counts: [String: Int] = [:]
        var i = 0
        while i < length {
            if isLetter(ns.character(at: i)) {
                let start = i
                i += 1
                while i < length {
                    let c = ns.character(at: i)
                    if isLetterOrDigit(c) {
                        i += 1
                    } else if (c == 0x27 || c == 0x2019 || c == 0x2D),
                              i + 1 < length,
                              isLetter(ns.character(at: i + 1)) {
                        i += 1
                    } else {
                        break
                    }
                }
                let wordLen = i - start
                if wordLen >= 3 {
                    let word = ns.substring(with: NSRange(location: start, length: wordLen)).lowercased()
                    let normalized = word.replacingOccurrences(of: "\u{2019}", with: "'")
                    if !ContextSpelling.confusableWords.contains(normalized),
                       ContextSpelling.commonMisspellings[normalized] == nil,
                       !ContextSpelling.ambiguousTypos.contains(normalized) {
                        counts[normalized, default: 0] += 1
                    }
                }
            } else {
                i += 1
            }
        }

        var result = Set<String>()
        for (word, count) in counts where count >= minimumOccurrences {
            result.insert(word)
        }
        return result
    }

    /// True when `word` is part of the document's recurring vocabulary or `extraVocabulary`.
    static func isKnown(
        _ word: String,
        in text: String,
        extraVocabulary: Set<String> = [],
        minimumOccurrences: Int = 2
    ) -> Bool {
        let lower = word.lowercased().replacingOccurrences(of: "\u{2019}", with: "'")
        if extraVocabulary.contains(lower) { return true }
        return recurringWords(in: text, minimumOccurrences: minimumOccurrences).contains(lower)
    }

    private static func isLetter(_ c: unichar) -> Bool {
        guard let scalar = Unicode.Scalar(c) else { return false }
        return CharacterSet.letters.contains(scalar)
    }

    private static func isLetterOrDigit(_ c: unichar) -> Bool {
        guard let scalar = Unicode.Scalar(c) else { return false }
        return CharacterSet.alphanumerics.contains(scalar)
    }
}

/// Pause-tier context-aware spelling (#98): resolves ambiguous misspellings (`teh form` → `the form`
/// or `the from`) and real words used wrongly (`form`/`from`, `there`/`their`/`they're`,
/// `loose`/`lose`, `then`/`than`, `its`/`it's`, `your`/`you're`, `whose`/`who's`, `to`/`too`,
/// `weather`/`whether`, `affect`/`effect`, `passed`/`past`, `accept`/`except`,
/// `principal`/`principle`, `lead`/`led`, `piece`/`peace`, `were`/`where`), while respecting
/// confidence thresholds, document vocabulary, ignored words, prose exclusions and the person's caret.
nonisolated enum ContextSpelling {
    /// Minimum confidence required to apply a correction automatically in `.automatic` mode.
    static let confidenceThreshold: Double = 0.80

    /// Minimum confidence required to offer a correction in `.suggest` mode; below this is ignored.
    static let minimumSuggestConfidence: Double = 0.35

    /// Real words that participate in contextual wrong-word checks; never suppressed by recurrence.
    static let confusableWords: Set<String> = [
        "form", "from",
        "there", "their", "they're",
        "loose", "lose",
        "then", "than",
        "its", "it's",
        "your", "you're",
        "whose", "who's",
        "to", "too",
        "weather", "whether",
        "affect", "effect",
        "passed", "past",
        "accept", "except",
        "principal", "principle",
        "lead", "led",
        "piece", "peace",
        "were", "where", "we're"
    ]

    /// Ambiguous short typos resolved by sentence context; never suppressed by recurrence.
    static let ambiguousTypos: Set<String> = [
        "teh", "hte", "tje", "fomr", "rfom", "thier", "ot", "adn", "nad", "cna", "nto",
        "taht", "waht", "wiht", "jsut", "ahve", "knwo", "abotu", "shoudl", "woudl", "coudl",
        "whcih", "thign", "thigns"
    ]

    /// Unambiguous common misspellings; never suppressed by recurrence.
    static let commonMisspellings: [String: String] = [
        "untill": "until",
        "becuase": "because",
        "recieve": "receive",
        "seperate": "separate",
        "definately": "definitely",
        "occured": "occurred",
        "accomodate": "accommodate",
        "wierd": "weird",
        "freind": "friend",
        "beleive": "believe",
        "acheive": "achieve",
        "neccessary": "necessary",
        "occassion": "occasion",
        "enviroment": "environment",
        "goverment": "government",
        "begining": "beginning",
        "tommorow": "tomorrow",
        "calender": "calendar",
        "adress": "address",
        "collegue": "colleague",
        "concious": "conscious",
        "disapoint": "disappoint",
        "embarass": "embarrass",
        "existance": "existence",
        "foriegn": "foreign",
        "fourty": "forty",
        "grammer": "grammar",
        "immediatly": "immediately",
        "independant": "independent",
        "knowlege": "knowledge",
        "maintainance": "maintenance",
        "millenium": "millennium",
        "noticable": "noticeable",
        "occurence": "occurrence",
        "persistant": "persistent",
        "priviledge": "privilege",
        "publically": "publicly",
        "recomend": "recommend",
        "refered": "referred",
        "relevent": "relevant",
        "succesful": "successful",
        "suprise": "surprise",
        "tendancy": "tendency",
        "threshhold": "threshold",
        "truely": "truly",
        "unfortunatly": "unfortunately",
        "prettuy": "pretty",
        "liek": "like"
    ]

    private struct Token {
        var text: String
        var lower: String
        var range: NSRange
        var hasClauseBreakBefore: Bool
        var hasClauseBreakAfter: Bool
        var isCapitalized: Bool
    }

    /// Detects context-dependent spelling and wrong-word corrections in `paragraph`.
    static func detect(
        in paragraph: String,
        flavor: MarkdownFlavor = .github,
        vocabulary: Set<String> = [],
        ignoredWords: Set<String> = []
    ) -> [JazzTextSpellingCorrection] {
        let ns = paragraph as NSString
        guard ns.length > 0 else { return [] }
        let document = MarkdownDocument.parse(paragraph, flavor: flavor)
        let tokens = tokenize(paragraph, ns: ns, document: document)
        guard !tokens.isEmpty else { return [] }

        let knownVocab = Set(vocabulary.map { $0.lowercased().replacingOccurrences(of: "\u{2019}", with: "'") })
        let ignored = Set(ignoredWords.map { $0.lowercased().replacingOccurrences(of: "\u{2019}", with: "'") })
        let localRecurring = DocumentVocabulary.recurringWords(in: paragraph)
        let blockedWords = knownVocab.union(ignored).union(localRecurring)

        var corrections: [JazzTextSpellingCorrection] = []
        var skipIndex: Int?

        for i in tokens.indices {
            if skipIndex == i { continue }
            let token = tokens[i]
            if blockedWords.contains(token.lower) { continue }

            let prev1: Token? = (!token.hasClauseBreakBefore && i >= 1) ? tokens[i - 1] : nil
            let prev2: Token? = (prev1 != nil && !prev1!.hasClauseBreakBefore && i >= 2) ? tokens[i - 2] : nil
            let next1: Token? = (!token.hasClauseBreakAfter && i + 1 < tokens.count) ? tokens[i + 1] : nil
            let next2: Token? = (next1 != nil && !next1!.hasClauseBreakAfter && i + 2 < tokens.count) ? tokens[i + 2] : nil

            // 1. Ambiguous two-word transposition: `teh form` -> `the form` or `the from` depending on context
            if (token.lower == "teh" || token.lower == "hte" || token.lower == "tje"),
               let n1 = next1, n1.lower == "form", !blockedWords.contains(n1.lower) {
                let tehReplacement = matchCase(of: token.text, replacement: "the")
                corrections.append(JazzTextSpellingCorrection(
                    range: JazzTextRange(start: token.range.location, end: NSMaxRange(token.range)),
                    original: token.text,
                    replacement: tehReplacement,
                    confidence: 0.96,
                    why: "Fixed misspelling in context"
                ))
                // If `teh form` follows a verb/adjective/preposition that takes `from` (e.g. "came teh form", "away teh form"),
                // and `form` isn't followed by a noun/preposition that makes `the form` a noun phrase, fix `form` -> `from` too.
                if let p1 = prev1, takesFromPreposition.contains(p1.lower), n1.hasClauseBreakAfter {
                    corrections.append(JazzTextSpellingCorrection(
                        range: JazzTextRange(start: n1.range.location, end: NSMaxRange(n1.range)),
                        original: n1.text,
                        replacement: matchCase(of: n1.text, replacement: "from"),
                        confidence: 0.91,
                        why: "Context indicates 'from'"
                    ))
                }
                skipIndex = i + 1
                continue
            }

            if let match = evaluateToken(
                token,
                prev1: prev1,
                prev2: prev2,
                next1: next1,
                next2: next2
            ) {
                let cased = matchCase(of: token.text, replacement: match.replacement)
                if cased != token.text {
                    corrections.append(JazzTextSpellingCorrection(
                        range: JazzTextRange(start: token.range.location, end: NSMaxRange(token.range)),
                        original: token.text,
                        replacement: cased,
                        confidence: match.confidence,
                        why: match.why
                    ))
                }
            }
        }

        return corrections
    }

    /// Converts pause-tier `JazzTextSpellingCorrection` items into `[PartnerEdit]` ready to play
    /// through the partner's cursor (in `.automatic` mode) or offer as underlined suggestions
    /// (in `.suggest` mode), respecting confidence thresholds, caret position, prose checks,
    /// document vocabulary and ignored words.
    static func partnerEdits(
        from corrections: [JazzTextSpellingCorrection],
        in paragraph: String,
        paragraphRange: NSRange,
        documentText: String,
        flavor: MarkdownFlavor = .github,
        mode: WritingPartnerMode,
        caretRange: NSRange,
        vocabulary: Set<String> = [],
        ignoredWords: Set<String> = []
    ) -> [PartnerEdit] {
        guard mode != .off, !corrections.isEmpty else { return [] }
        let docNS = documentText as NSString
        let paraNS = paragraph as NSString
        guard NSMaxRange(paragraphRange) <= docNS.length,
              docNS.substring(with: paragraphRange) == paragraph else {
            return []
        }

        let minConfidence = mode == .automatic ? confidenceThreshold : minimumSuggestConfidence
        let knownVocab = Set(vocabulary.map { $0.lowercased().replacingOccurrences(of: "\u{2019}", with: "'") })
            .union(DocumentVocabulary.recurringWords(in: documentText))
        let ignored = Set(ignoredWords.map { $0.lowercased().replacingOccurrences(of: "\u{2019}", with: "'") })
        let document = MarkdownDocument.parse(documentText, flavor: flavor)

        let sorted = corrections.sorted {
            if $0.range.start != $1.range.start { return $0.range.start < $1.range.start }
            return $0.range.end < $1.range.end
        }

        var edits: [PartnerEdit] = []
        var lastEnd = 0

        for item in sorted {
            guard item.confidence >= minConfidence else { continue }
            let start = item.range.start
            let end = item.range.end
            guard start >= 0, end > start, end <= paraNS.length, start >= lastEnd else { continue }

            let localRange = NSRange(location: start, length: end - start)
            let actualWord = paraNS.substring(with: localRange)
            if let expectedOriginal = item.original, !expectedOriginal.isEmpty, expectedOriginal != actualWord {
                continue
            }
            guard item.replacement != actualWord, !item.replacement.isEmpty else { continue }

            let lowerWord = actualWord.lowercased().replacingOccurrences(of: "\u{2019}", with: "'")
            if knownVocab.contains(lowerWord) || ignored.contains(lowerWord) {
                continue
            }

            let docRange = NSRange(location: paragraphRange.location + start, length: localRange.length)
            // Never edit the word containing the person's active selection/caret if the caret is inside the word
            if caretRange.length > 0 {
                if NSIntersectionRange(docRange, caretRange).length > 0 { continue }
            } else if caretRange.location > docRange.location && caretRange.location < NSMaxRange(docRange) {
                continue
            }

            // Must be prose (never code, math, HTML, link addresses, front matter, or tables)
            guard TextMechanics.isProse(at: docRange.location, in: documentText, document: document) else {
                continue
            }

            edits.append(PartnerEdit(
                range: docRange,
                replacement: item.replacement,
                rule: .spelling
            ))
            lastEnd = end
        }

        return edits
    }

    // MARK: - Tokenization & Context Rules

    private static func tokenize(
        _ paragraph: String,
        ns: NSString,
        document: MarkdownDocument
    ) -> [Token] {
        var rawRanges: [NSRange] = []
        let length = ns.length
        var i = 0
        while i < length {
            if isLetter(ns.character(at: i)) {
                let start = i
                i += 1
                while i < length {
                    let c = ns.character(at: i)
                    if isLetterOrDigit(c) {
                        i += 1
                    } else if (c == 0x27 || c == 0x2019),
                              i + 1 < length,
                              isLetter(ns.character(at: i + 1)) {
                        i += 1
                    } else {
                        break
                    }
                }
                let r = NSRange(location: start, length: i - start)
                // Skip tokens preceded or followed by URL/path/email/identifier punctuation (`/`, `@`, `.`, `_`, `:`, `#`)
                let precededByTech = start > 0 && isTechPunctuation(ns.character(at: start - 1))
                let followedByTech = i < length && isTechInfixPunctuation(ns.character(at: i))
                if !precededByTech && !followedByTech && TextMechanics.isProse(at: start, in: paragraph, document: document) {
                    rawRanges.append(r)
                }
            } else {
                i += 1
            }
        }

        var tokens: [Token] = []
        tokens.reserveCapacity(rawRanges.count)

        for idx in rawRanges.indices {
            let r = rawRanges[idx]
            let rawText = ns.substring(with: r)
            let normalizedLower = rawText.lowercased().replacingOccurrences(of: "\u{2019}", with: "'")

            let hasBreakBefore: Bool
            if idx == 0 {
                hasBreakBefore = true
            } else {
                let prevEnd = NSMaxRange(rawRanges[idx - 1])
                let gap = ns.substring(with: NSRange(location: prevEnd, length: r.location - prevEnd))
                hasBreakBefore = containsClauseBreak(gap)
            }

            let hasBreakAfter: Bool
            if idx + 1 >= rawRanges.count {
                hasBreakAfter = true
            } else {
                let nextStart = rawRanges[idx + 1].location
                let gap = ns.substring(with: NSRange(location: NSMaxRange(r), length: nextStart - NSMaxRange(r)))
                hasBreakAfter = containsClauseBreak(gap)
            }

            let isCap: Bool
            if let firstScalar = rawText.unicodeScalars.first {
                isCap = CharacterSet.uppercaseLetters.contains(firstScalar)
            } else {
                isCap = false
            }

            tokens.append(Token(
                text: rawText,
                lower: normalizedLower,
                range: r,
                hasClauseBreakBefore: hasBreakBefore,
                hasClauseBreakAfter: hasBreakAfter,
                isCapitalized: isCap
            ))
        }

        return tokens
    }

    private static func containsClauseBreak(_ gap: String) -> Bool {
        for scalar in gap.unicodeScalars {
            switch scalar {
            case ".", "!", "?", ";", ":", "\n", "\r", "(", ")", "[", "]", "—", "–":
                return true
            default:
                break
            }
        }
        return false
    }

    private static func isLetter(_ c: unichar) -> Bool {
        guard let scalar = Unicode.Scalar(c) else { return false }
        return CharacterSet.letters.contains(scalar)
    }

    private static func isLetterOrDigit(_ c: unichar) -> Bool {
        guard let scalar = Unicode.Scalar(c) else { return false }
        return CharacterSet.alphanumerics.contains(scalar)
    }

    private static func isTechPunctuation(_ c: unichar) -> Bool {
        c == 0x2F || c == 0x40 || c == 0x5F || c == 0x23 || c == 0x7E || c == 0x5C // / @ _ # ~ \
    }

    private static func isTechInfixPunctuation(_ c: unichar) -> Bool {
        c == 0x2F || c == 0x40 || c == 0x5F || c == 0x5C // / @ _ \
    }

    private static func matchCase(of original: String, replacement: String) -> String {
        let usesCurlyApostrophe = original.contains("\u{2019}")
        let adjustedReplacement = usesCurlyApostrophe
            ? replacement.replacingOccurrences(of: "'", with: "\u{2019}")
            : replacement

        let letters = original.unicodeScalars.filter { CharacterSet.letters.contains($0) }
        guard !letters.isEmpty else { return adjustedReplacement }

        let allUpper = letters.count > 1 && letters.allSatisfy { CharacterSet.uppercaseLetters.contains($0) }
        if allUpper {
            return adjustedReplacement.uppercased()
        }
        if let first = letters.first, CharacterSet.uppercaseLetters.contains(first) {
            return adjustedReplacement.prefix(1).uppercased() + adjustedReplacement.dropFirst()
        }
        return adjustedReplacement
    }

    private static func evaluateToken(
        _ token: Token,
        prev1: Token?,
        prev2: Token?,
        next1: Token?,
        next2: Token?
    ) -> (replacement: String, confidence: Double, why: String)? {
        let w = token.lower
        let p1 = prev1?.lower
        let p2 = prev2?.lower
        let n1 = next1?.lower
        let n2 = next2?.lower

        // Unambiguous typos & transpositions
        if w == "teh" || w == "hte" || w == "tje" {
            return ("the", 0.96, "Fixed misspelling of 'the'")
        }
        if w == "taht" { return ("that", 0.95, "Fixed misspelling of 'that'") }
        if w == "waht" { return ("what", 0.95, "Fixed misspelling of 'what'") }
        if w == "wiht" { return ("with", 0.95, "Fixed misspelling of 'with'") }
        if w == "jsut" { return ("just", 0.95, "Fixed misspelling of 'just'") }
        if w == "ahve" { return ("have", 0.95, "Fixed misspelling of 'have'") }
        if w == "knwo" { return ("know", 0.95, "Fixed misspelling of 'know'") }
        if w == "abotu" { return ("about", 0.95, "Fixed misspelling of 'about'") }
        if w == "adn" || w == "nad" { return ("and", 0.94, "Fixed misspelling of 'and'") }
        if w == "cna" { return ("can", 0.94, "Fixed misspelling of 'can'") }
        if w == "nto" { return ("not", 0.94, "Fixed misspelling of 'not'") }
        if w == "shoudl" { return ("should", 0.95, "Fixed misspelling of 'should'") }
        if w == "woudl" { return ("would", 0.95, "Fixed misspelling of 'would'") }
        if w == "coudl" { return ("could", 0.95, "Fixed misspelling of 'could'") }
        if w == "whcih" { return ("which", 0.95, "Fixed misspelling of 'which'") }
        if w == "thign" { return ("thing", 0.95, "Fixed misspelling of 'thing'") }
        if w == "thigns" { return ("things", 0.95, "Fixed misspelling of 'things'") }

        if let fixed = commonMisspellings[w] {
            return (fixed, 0.95, "Fixed misspelling")
        }

        // Ambiguous misspelling `thier` -> `there`, `they're`, or `their` from context
        if w == "thier" {
            if let n1, existentialBeVerbs.contains(n1) {
                return ("there", 0.93, "Context indicates existential 'there'")
            }
            if let n1, (theyAreFollowers.contains(n1) || isPresentParticipleVerb(n1, next: n2)) {
                return ("they're", 0.92, "Context indicates contraction 'they're'")
            }
            return ("their", 0.94, "Fixed misspelling of 'their'")
        }

        // Ambiguous misspelling `fomr` / `rfom` -> `form` or `from` from context
        if w == "fomr" || w == "rfom" {
            if let p1, formNounModifiers.contains(p1), (n1 == nil || n1 == "of" || n1 == "is" || n1 == "was" || n1 == "to" || n1 == "for") {
                return ("form", 0.91, "Context indicates noun 'form'")
            }
            if p1 == "to", let n1, (n1 == "a" || n1 == "an" || n1 == "the") {
                return ("form", 0.90, "Context indicates verb 'form'")
            }
            return ("from", 0.92, "Context indicates preposition 'from'")
        }

        // Short ambiguous typo `ot` -> `to`
        if w == "ot" {
            if let n1, (toInfinitiveVerbs.contains(n1) || determinersAndPronounsForFrom.contains(n1)) {
                return ("to", 0.90, "Context indicates 'to'")
            }
        }

        // 1. `form` <-> `from`
        if w == "form" {
            if let n1 {
                // Idiomatic `from X to Y` / `from now on` / `from scratch` / `from afar` / `from within`
                if (n1 == "now" && n2 == "on") ||
                   (n1 == "time" && n2 == "to") ||
                   (n1 == "day" && n2 == "one") ||
                   (n1 == "start" && n2 == "to") ||
                   (n1 == "top" && n2 == "to") ||
                   (n1 == "beginning" && n2 == "to") ||
                   (n1 == "side" && n2 == "to") ||
                   (n1 == "place" && n2 == "to") ||
                   fromOnlyObjects.contains(n1) {
                    return ("from", 0.93, "Use 'from' in this phrase")
                }
                // Preceded by a word that takes `from` (e.g. `far form`, `came form`, `work form home`, `different form`, `heard form`)
                if let p1, takesFromPreposition.contains(p1),
                   (determinersAndPronounsForFrom.contains(n1) || (next1?.isCapitalized == true) || isParticipleOrGerund(n1)) {
                    return ("from", 0.92, "Use 'from' after '\(p1)'")
                }
                // `prevent/keep/stop/save/protect <object> form <gerund>`
                if let p2, preventVerbs.contains(p2), isParticipleOrGerund(n1) {
                    return ("from", 0.92, "Use 'from' after '\(p2)'")
                }
                // Sentence-initial `Form the beginning`, `Form my perspective`, `Form that point`, `Form here`, `Form there`
                if token.hasClauseBreakBefore, token.isCapitalized {
                    if n1 == "here" || n1 == "there" || n1 == "my" || n1 == "our" || n1 == "their" ||
                       n1 == "your" || n1 == "his" || n1 == "her" || n1 == "what" || n1 == "where" ||
                       n1 == "this" || n1 == "that" || n1 == "these" || n1 == "those" ||
                       (n1 == "the" && (n2 == "beginning" || n2 == "start" || n2 == "outset" || n2 == "moment" || n2 == "look" || n2 == "sound" || n2 == "outside" || n2 == "inside" || n2 == "top" || n2 == "bottom" || n2 == "very")) {
                        return ("from", 0.90, "Use 'From' to introduce the prepositional phrase")
                    }
                }
            }
        } else if w == "from" {
            // `the from` / `application from` / `in the from of` / `fill out the from`
            if let p1, formNounModifiers.contains(p1) {
                if n1 == "of" {
                    return ("form", 0.93, "Use 'form' in 'form of'")
                }
                if token.hasClauseBreakAfter || n1 == "is" || n1 == "was" || n1 == "has" || n1 == "had" ||
                   n1 == "will" || n1 == "can" || n1 == "should" || n1 == "must" || n1 == "to" ||
                   n1 == "for" || n1 == "in" || n1 == "on" || n1 == "with" || n1 == "and" || n1 == "or" ||
                   n1 == "but" || n1 == "that" || n1 == "which" || n1 == "fields" || n1 == "field" ||
                   n1 == "below" || n1 == "above" {
                    // Only when preceded by a noun-phrase modifier (`the`, `this`, `that`, `a`, `an`, `application`, `registration`, `contact`, `order`, `feedback`, `tax`, `entry`, `consent`, `web`, `short`, `long`, `good`, `bad`, `new`)
                    if definiteFormPreceders.contains(p1) || (p2 == "fill" && (p1 == "out" || p1 == "in")) {
                        return ("form", 0.91, "Use the noun 'form' here")
                    }
                }
            }
            // Infinitive or modal + `from` + determiner: `to from a`, `can from a`, `will from a`
            if let p1, (p1 == "to" || modalAuxiliaries.contains(p1)),
               let n1, (n1 == "a" || n1 == "an" || n1 == "the" || n1 == "their" || n1 == "our" || n1 == "new" || n1 == "two") {
                return ("form", 0.90, "Use the verb 'form' after '\(p1)'")
            }
        }

        // 2. `there` <-> `their` <-> `they're`
        if w == "their" {
            if let n1 {
                if existentialBeVerbs.contains(n1) {
                    return ("there", 0.94, "Use 'there' before '\(n1)'")
                }
                if theyAreFollowers.contains(n1) && !(n1 == "all" && n2 != nil && possessedNouns.contains(n2!)) &&
                   !(n1 == "both" && n2 != nil && possessedNouns.contains(n2!)) &&
                   !(n1 == "very" && n2 == "own") &&
                   !(n1 == "own") {
                    return ("they're", 0.91, "Use 'they're' (they are) before '\(n1)'")
                }
                if isPresentParticipleVerb(n1, next: n2) {
                    return ("they're", 0.92, "Use 'they're' (they are) before '\(n1)'")
                }
            }
            if let p1, locativeTherePreceders.contains(p1),
               (token.hasClauseBreakAfter || (n1 != nil && clauseContinuationFollowers.contains(n1!))) {
                return ("there", 0.92, "Use locative 'there' after '\(p1)'")
            }
        } else if w == "there" {
            if let n1 {
                if n1 == "own" {
                    return ("their", 0.95, "Use possessive 'their' before 'own'")
                }
                if isPresentParticipleVerb(n1, next: n2),
                   !(p1 != nil && existentialBeVerbs.contains(p1!)),
                   !(p1 != nil && locativeTherePreceders.contains(p1!)) {
                    return ("they're", 0.91, "Use 'they're' (they are) before '\(n1)'")
                }
                if theyAreAdjectiveFollowers.contains(n1),
                   !(p1 != nil && existentialBeVerbs.contains(p1!)),
                   !(p1 != nil && locativeTherePreceders.contains(p1!)) {
                    return ("they're", 0.90, "Use 'they're' (they are) before '\(n1)'")
                }
                if possessedNouns.contains(n1) {
                    if let p1, possessiveContextPreceders.contains(p1) {
                        return ("their", 0.93, "Use possessive 'their' before '\(n1)'")
                    }
                    if token.hasClauseBreakBefore, let n2, nounPhraseFollowingVerbs.contains(n2) {
                        return ("their", 0.92, "Use possessive 'Their' before '\(n1)'")
                    }
                }
            }
        } else if w == "they're" {
            if let n1 {
                if existentialBeVerbs.contains(n1) {
                    return ("there", 0.94, "Use 'there' before '\(n1)'")
                }
                if n1 == "own" || singularPossessedNouns.contains(n1) {
                    return ("their", 0.94, "Use possessive 'their' before '\(n1)'")
                }
                if possessedNouns.contains(n1), let n2, nounPhraseFollowingVerbs.contains(n2) {
                    return ("their", 0.92, "Use possessive 'their' before '\(n1)'")
                }
            }
        }

        // 3. `loose` <-> `lose`
        if w == "loose" {
            if let p1, losePreceders.contains(p1),
               !(p2 != nil && looseIdiomaticVerbs.contains(p2!)) {
                return ("lose", 0.94, "Use the verb 'lose' after '\(p1)'")
            }
            if let n1, loseDirectObjects.contains(n1),
               !(p1 != nil && looseAdjectivePreceders.contains(p1!)),
               !(p1 != nil && looseIdiomaticVerbs.contains(p1!)) {
                return ("lose", 0.93, "Use the verb 'lose' before '\(n1)'")
            }
        } else if w == "lose" {
            if let p1, looseIdiomaticVerbs.contains(p1),
               (token.hasClauseBreakAfter || (n1 != nil && (looseModifiableNouns.contains(n1!) || clauseContinuationFollowers.contains(n1!)))) {
                return ("loose", 0.92, "Use the adjective 'loose' after '\(p1)'")
            }
            if let p1, looseAdjectivePreceders.contains(p1),
               (token.hasClauseBreakAfter || (n1 != nil && (looseModifiableNouns.contains(n1!) || clauseContinuationFollowers.contains(n1!)))) {
                return ("loose", 0.93, "Use the adjective 'loose' here")
            }
            if let n1, looseModifiableNouns.contains(n1),
               let p1, (determinersForAdjective.contains(p1) || p1 == "of" || p1 == "with" || p1 == "in") {
                return ("loose", 0.93, "Use the adjective 'loose' before '\(n1)'")
            }
        }

        // 4. `then` <-> `than`
        if w == "then" {
            if let p1, comparativeWords.contains(p1) {
                return ("than", 0.94, "Use 'than' for comparisons after '\(p1)'")
            }
            if let p2, (p2 == "more" || p2 == "less"), let p1, !nonComparativeInterveners.contains(p1) {
                return ("than", 0.91, "Use 'than' after 'more/less ...'")
            }
        } else if w == "than" {
            if token.hasClauseBreakBefore, token.isCapitalized,
               let n1, subjectStartersAfterThen.contains(n1) {
                return ("then", 0.92, "Use 'Then' for time/sequence at the start of a clause")
            }
            if let p1, temporalThenPreceders.contains(p1),
               (token.hasClauseBreakAfter || (n1 != nil && subjectStartersAfterThen.contains(n1!))) {
                return ("then", 0.92, "Use 'then' for time/sequence after '\(p1)'")
            }
        }

        // 5. `its` <-> `it's` (beyond NLTagger)
        if w == "its" {
            if let n1 {
                if unconditionalItIsFollowers.contains(n1) {
                    return ("it's", 0.94, "Use 'it's' (it is / it has) before '\(n1)'")
                }
                if predicativeItIsFollowers.contains(n1),
                   (token.hasClauseBreakBefore || (p1 != nil && clauseIntroducersBeforeItIs.contains(p1!))),
                   (next1?.hasClauseBreakAfter == true || (n2 != nil && nonNounAfterPredicativeAdjective.contains(n2!))) {
                    return ("it's", 0.91, "Use 'it's' (it is) in this clause")
                }
            }
        } else if w == "it's" {
            if let n1 {
                if n1 == "own" {
                    return ("its", 0.96, "Use possessive 'its' before 'own'")
                }
                if itsPossessedNouns.contains(n1),
                   let p1, possessiveContextPreceders.contains(p1) {
                    return ("its", 0.93, "Use possessive 'its' before '\(n1)'")
                }
            }
        }

        // 6. `your` <-> `you're`
        if w == "your" {
            if let n1 {
                if youAreUnconditionalFollowers.contains(n1),
                   !(n1 == "welcome" && (n2 == "kit" || n2 == "packet" || n2 == "email" || n2 == "message" || n2 == "gift")),
                   !(n1 == "right" && (n2 == "hand" || n2 == "arm" || n2 == "leg" || n2 == "foot" || n2 == "eye" || n2 == "ear" || n2 == "side" || n2 == "to")) {
                    return ("you're", 0.93, "Use 'you're' (you are) before '\(n1)'")
                }
                if isPresentParticipleVerb(n1, next: n2) {
                    return ("you're", 0.92, "Use 'you're' (you are) before '\(n1)'")
                }
            }
        } else if w == "you're" {
            if let n1 {
                if n1 == "own" || singularPossessedNouns.contains(n1) || yourOnlyPossessedNouns.contains(n1) {
                    return ("your", 0.94, "Use possessive 'your' before '\(n1)'")
                }
                if possessedNouns.contains(n1), let n2, nounPhraseFollowingVerbs.contains(n2) {
                    return ("your", 0.92, "Use possessive 'your' before '\(n1)'")
                }
            }
        }

        // 7. `whose` <-> `who's`
        if w == "whose" {
            if let n1, (whoIsFollowers.contains(n1) || isPresentParticipleVerb(n1, next: n2)) {
                return ("who's", 0.92, "Use 'who's' (who is / who has) before '\(n1)'")
            }
        } else if w == "who's" {
            if let n1, (n1 == "own" || singularPossessedNouns.contains(n1) || yourOnlyPossessedNouns.contains(n1)) {
                return ("whose", 0.93, "Use possessive 'whose' before '\(n1)'")
            }
        }

        // 8. `to` <-> `too`
        if w == "to" {
            if let n1, (n1 == "many" || n1 == "much"),
               !(p1 == "up" || p1 == "due" || p1 == "lead" || p1 == "led" || p1 == "amount") {
                return ("too", 0.92, "Use 'too' meaning excessively before '\(n1)'")
            }
            if let n1, tooDegreeAdjectives.contains(n1),
               let p1, copularAndDegreePrecedersForToo.contains(p1),
               (next1?.hasClauseBreakAfter == true || n2 == "to" || n2 == "for" || n2 == "and" || n2 == "but" || n2 == "so" || n2 == "because" || n2 == "that") {
                return ("too", 0.91, "Use 'too' meaning excessively before '\(n1)'")
            }
        } else if w == "too" {
            if let p1, infinitiveOrPrepositionToPreceders.contains(p1),
               let n1, (toInfinitiveVerbs.contains(n1) || n1 == "the" || n1 == "a" || n1 == "an" || n1 == "my" || n1 == "your" || n1 == "our" || n1 == "their" || n1 == "his" || n1 == "her" || n1 == "its" || n1 == "me" || n1 == "you" || n1 == "him" || n1 == "us" || n1 == "them" || n1 == "this" || n1 == "that" || n1 == "work" || n1 == "home" || n1 == "school" || n1 == "bed") {
                return ("to", 0.92, "Use 'to' here instead of 'too'")
            }
        }

        // 9. `weather` <-> `whether`
        if w == "weather" {
            if let n1 {
                if n1 == "or" || n1 == "it" || n1 == "it's" || n1 == "we" || n1 == "we're" ||
                   n1 == "you" || n1 == "you're" || n1 == "they" || n1 == "they're" ||
                   n1 == "he" || n1 == "she" || n1 == "there" || n1 == "that" || n1 == "not" ||
                   (n1 == "to" && n2 != nil && toInfinitiveVerbs.contains(n2!)) {
                    if !(p1 != nil && weatherNounModifiers.contains(p1!)) {
                        return ("whether", 0.93, "Use the conjunction 'whether' here")
                    }
                }
            }
        } else if w == "whether" {
            if let p1, weatherNounModifiers.contains(p1),
               !(n1 == "or" || n1 == "to" || n1 == "it" || n1 == "we" || n1 == "they" || n1 == "you" || n1 == "he" || n1 == "she") {
                return ("weather", 0.93, "Use the noun 'weather' after '\(p1)'")
            }
            if let n1, weatherCompoundNouns.contains(n1) {
                return ("weather", 0.93, "Use the noun 'weather' before '\(n1)'")
            }
        }

        // 10. `affect` <-> `effect`
        if w == "affect" {
            if let p1, effectNounPreceders.contains(p1),
               (token.hasClauseBreakAfter || n1 == "of" || n1 == "on" || n1 == "upon" || n1 == "is" || n1 == "was" || n1 == "will" || n1 == "in" || n1 == "and" || n1 == "or" || n1 == "but" || n1 == "that") {
                return ("effect", 0.92, "Use the noun 'effect' after '\(p1)'")
            }
        } else if w == "effect" {
            if let p1, affectVerbPreceders.contains(p1),
               let n1, affectVerbObjects.contains(n1),
               !(n1 == "a" && (n2 == "change" || n2 == "settlement" || n2 == "cure" || n2 == "repair" || n2 == "transfer")) {
                return ("affect", 0.91, "Use the verb 'affect' after '\(p1)'")
            }
        }

        // 11. `passed` <-> `past`
        if w == "passed" {
            if let p1, motionVerbsBeforePast.contains(p1),
               let n1, (determinersAndPronounsForFrom.contains(n1) || n1 == "each") {
                return ("past", 0.93, "Use the preposition 'past' after '\(p1)'")
            }
            if let p1, (p1 == "the" || p1 == "this"),
               let n1, pastTimeNouns.contains(n1) {
                return ("past", 0.93, "Use the adjective 'past' before '\(n1)'")
            }
            if let p1, (p1 == "half" || p1 == "quarter"),
               let n1, clockNumbers.contains(n1) {
                return ("past", 0.94, "Use 'past' for telling time")
            }
        } else if w == "past" {
            if let p1, passedAuxiliariesAndSubjects.contains(p1),
               let n1, (n1 == "away" || n1 == "out" || (n1 == "the" && (n2 == "test" || n2 == "exam" || n2 == "check" || n2 == "bill" || n2 == "law" || n2 == "ball" || n2 == "salt" || n2 == "bar" || n2 == "course" || n2 == "class" || n2 == "inspection" || n2 == "audit"))) {
                return ("passed", 0.92, "Use the past-tense verb 'passed' here")
            }
            if let p1, (p1 == "has" || p1 == "have" || p1 == "had"),
               (token.hasClauseBreakAfter || n1 == "since" || n1 == "by" || n1 == "on" || n1 == "down" || n1 == "through") {
                return ("passed", 0.93, "Use the past participle 'passed' after '\(p1)'")
            }
        }

        // 12. `accept` <-> `except`
        if w == "accept" {
            if n1 == "for" || n1 == "when" || n1 == "if" || n1 == "maybe" || n1 == "perhaps" {
                return ("except", 0.92, "Use 'except' meaning 'other than'")
            }
            if let p1, exceptPreceders.contains(p1) {
                return ("except", 0.92, "Use 'except' after '\(p1)'")
            }
        } else if w == "except" {
            if let p1, acceptVerbPreceders.contains(p1),
               let n1, acceptVerbObjects.contains(n1) {
                return ("accept", 0.92, "Use the verb 'accept' after '\(p1)'")
            }
        }

        // 13. `principal` <-> `principle`
        if w == "principal" {
            if p1 == "in" && (token.hasClauseBreakAfter || n1 == "and" || n1 == "but" || n1 == "we" || n1 == "I" || n1 == "it" || n1 == "they") {
                return ("principle", 0.94, "Use 'principle' in 'in principle'")
            }
            if let p1, principleModifiers.contains(p1) {
                return ("principle", 0.92, "Use 'principle' meaning a rule or belief")
            }
        } else if w == "principle" {
            if let n1, principalFollowedNouns.contains(n1) {
                return ("principal", 0.92, "Use 'principal' meaning main or primary before '\(n1)'")
            }
            if let p1, (p1 == "school" || p1 == "assistant" || p1 == "vice" || p1 == "deputy"),
               (token.hasClauseBreakAfter || (n1 != nil && nounPhraseFollowingVerbs.contains(n1!))) {
                return ("principal", 0.92, "Use 'principal' for the head of a school")
            }
        }

        // 14. `lead` <-> `led`
        if w == "lead" {
            if let p1, (p1 == "has" || p1 == "have" || p1 == "had" || p1 == "having" || p1 == "was" || p1 == "were" || p1 == "been"),
               let n1, (n1 == "to" || n1 == "by" || n1 == "the" || n1 == "a" || n1 == "an" || n1 == "us" || n1 == "them" || n1 == "me" || n1 == "him" || n1 == "her" || n1 == "in") {
                return ("led", 0.93, "Use past participle 'led' after '\(p1)'")
            }
        }

        // 15. `piece` <-> `peace`
        if w == "peace" {
            if n1 == "of", let n2, pieceOfNouns.contains(n2) {
                return ("piece", 0.94, "Use 'piece' in 'piece of \(n2)'")
            }
        } else if w == "piece" {
            if (n1 == "of" && n2 == "mind") || (n1 == "and" && n2 == "quiet") ||
               (p1 == "in" && token.hasClauseBreakAfter) || (p1 == "at" && token.hasClauseBreakAfter) ||
               (p1 == "world" || p1 == "inner" || p1 == "make") && (token.hasClauseBreakAfter || n1 == "with" || n1 == "and" || n1 == "in") {
                return ("peace", 0.94, "Use 'peace' meaning calm or harmony")
            }
        }

        // 16. `were` <-> `where`
        if w == "were" {
            if token.hasClauseBreakBefore, token.isCapitalized,
               let n1, (n1 == "is" || n1 == "are" || n1 == "was" || n1 == "can" || n1 == "could" || n1 == "do" || n1 == "does" || n1 == "did" || n1 == "will" || n1 == "should") {
                return ("where", 0.93, "Use 'Where' to start a location question")
            }
            if let p1, wherePrecedingNounsAndVerbs.contains(p1),
               let n1, (n1 == "I" || n1 == "i" || n1 == "you" || n1 == "he" || n1 == "she" || n1 == "it" || n1 == "we" || n1 == "they" || n1 == "the" || n1 == "to") {
                return ("where", 0.91, "Use 'where' after '\(p1)'")
            }
        } else if w == "where" {
            if let p1, (p1 == "we" || p1 == "you" || p1 == "they" || p1 == "there"),
               let n1, (n1 == "not" || n1 == "never" || n1 == "able" || n1 == "unable" || n1 == "ready" || n1 == "late" || n1 == "right" || n1 == "wrong" || n1 == "happy" || n1 == "glad" || n1 == "sorry" || n1 == "supposed" || n1 == "going" || n1 == "working" || n1 == "waiting" || n1 == "looking" || n1 == "trying" || n1 == "made" || n1 == "built" || n1 == "born" || n1 == "sent" || n1 == "taken" || n1 == "given" || n1 == "found" || n1 == "no" || n1 == "many" || n1 == "several" || n1 == "two" || n1 == "three") {
                return ("were", 0.92, "Use the verb 'were' after '\(p1)'")
            }
        }

        return nil
    }

    // MARK: - Word Sets for Context Disambiguation

    private static func isParticipleOrGerund(_ word: String) -> Bool {
        word.count >= 5 && word.hasSuffix("ing") && word != "thing" && word != "things" && word != "bring" && word != "spring" && word != "string" && word != "ring" && word != "king" && word != "wing" && word != "sing" && word != "swing"
    }

    private static func isPresentParticipleVerb(_ word: String, next: String?) -> Bool {
        guard participleVerbsAfterPronounBe.contains(word) else { return false }
        // Avoid turning `their writing is` / `their building was` / `their working hours` into `they're`
        if let next {
            if next == "is" || next == "was" || next == "has" || next == "had" ||
               next == "hours" || next == "room" || next == "day" || next == "session" ||
               next == "style" || next == "skills" || next == "habits" || next == "process" ||
               next == "system" || next == "environment" || next == "conditions" || next == "group" ||
               next == "team" || next == "material" || next == "materials" || next == "list" ||
               next == "space" || next == "area" || next == "table" || next == "desk" ||
               next == "clothes" || next == "shoes" || next == "gear" || next == "plan" ||
               next == "plans" || next == "costs" || next == "expenses" || next == "point" {
                return false
            }
        }
        return true
    }

    private static let takesFromPreposition: Set<String> = [
        "far", "away", "apart", "aside", "different", "differ", "differs", "differed",
        "separate", "separated", "free", "safe", "hidden", "absent", "exempt", "distinct",
        "remote", "isolated", "detached", "disconnected", "derived", "adapted", "translated",
        "borrowed", "copied", "stole", "stolen", "taken", "removed", "withdrawn", "excluded",
        "banned", "barred", "expelled", "fired", "resigned", "retired", "graduated",
        "recovered", "recovering", "escaped", "escaping", "fled", "fleeing", "returned",
        "returning", "departed", "departing", "arrived", "arriving", "came", "come", "comes",
        "coming", "went", "go", "going", "sent", "heard", "hear", "hearing", "learned",
        "learn", "learning", "got", "get", "getting", "received", "receive", "receiving",
        "bought", "buy", "buying", "downloaded", "download", "downloading", "imported",
        "import", "importing", "exported", "export", "exporting", "fetched", "fetch",
        "fetching", "pulled", "pull", "pulling", "extracted", "extract", "extracting",
        "selected", "chosen", "picked", "made", "built", "constructed", "created", "grown",
        "born", "emerged", "arose", "stem", "stems", "stemmed", "stemming", "result",
        "results", "resulted", "resulting", "suffer", "suffers", "suffered", "suffering",
        "die", "died", "dying", "benefit", "benefits", "benefited", "benefiting",
        "prevent", "prevents", "prevented", "preventing", "stop", "stops", "stopped",
        "stopping", "keep", "keeps", "kept", "keeping", "protect", "protects", "protected",
        "protecting", "save", "saves", "saved", "saving", "rescue", "rescued", "hide", "hid",
        "hiding", "shield", "shielded", "refrain", "abstain", "discourage", "discouraged",
        "deter", "deterred", "prohibit", "prohibited", "forbid", "forbidden", "range",
        "ranges", "ranged", "ranging", "vary", "varies", "varied", "varying", "switch",
        "switched", "switching", "move", "moved", "moving", "shift", "shifted", "shifting",
        "walk", "walked", "walking", "run", "ran", "running", "drive", "drove", "driving",
        "fly", "flew", "flying", "travel", "traveled", "travelled", "work", "worked",
        "working", "fall", "fell", "falling", "drop", "dropped", "dropping", "jump",
        "jumped", "jumping", "rise", "rose", "rising", "start", "starts", "started",
        "starting", "begin", "begins", "began", "beginning", "straight", "directly",
        "fresh", "back", "out", "down", "up", "across", "letter", "letters", "message",
        "messages", "email", "emails", "call", "calls", "note", "notes", "news", "gift",
        "gifts", "package", "packages", "quote", "quotes", "excerpt", "excerpts", "sample",
        "samples", "distance", "miles", "kilometers", "kilometres", "meters", "metres",
        "feet", "steps", "minutes", "hours", "days", "blocks"
    ]

    private static let preventVerbs: Set<String> = [
        "prevent", "prevents", "prevented", "preventing",
        "stop", "stops", "stopped", "stopping",
        "keep", "keeps", "kept", "keeping",
        "save", "saves", "saved", "saving",
        "protect", "protects", "protected", "protecting",
        "hide", "hid", "hiding",
        "discourage", "discourages", "discouraged",
        "deter", "deters", "deterred",
        "bar", "bars", "barred",
        "ban", "bans", "banned",
        "block", "blocks", "blocked"
    ]

    private static let fromOnlyObjects: Set<String> = [
        "scratch", "afar", "abroad", "overseas", "within", "behind", "beneath", "underneath",
        "outside", "inside", "nowhere", "somewhere", "anywhere", "everywhere"
    ]

    private static let determinersAndPronounsForFrom: Set<String> = [
        "the", "a", "an", "this", "that", "these", "those",
        "my", "your", "his", "her", "its", "our", "their",
        "me", "you", "him", "us", "them", "whom", "which", "what", "where",
        "here", "there", "home", "work", "school", "memory", "experience", "context",
        "above", "below", "under", "time", "day", "start", "beginning", "end",
        "top", "bottom", "left", "right", "side", "one", "two", "three", "first", "last",
        "all", "any", "some", "many", "most", "several", "both", "each", "every", "another", "other"
    ]

    private static let formNounModifiers: Set<String> = [
        "the", "a", "an", "this", "that", "each", "every", "another", "any", "which", "what",
        "registration", "application", "contact", "order", "feedback", "consent", "release",
        "tax", "entry", "intake", "signup", "login", "web", "html", "input", "search",
        "payment", "booking", "request", "claim", "enrollment", "enrolment", "survey",
        "short", "long", "good", "bad", "poor", "great", "fine", "pure", "human", "art",
        "physical", "written", "spoken", "musical", "literary", "poetic", "narrative",
        "standard", "normal", "canonical", "simplest", "basic", "original", "final",
        "current", "new", "old", "different", "same", "similar"
    ]

    private static let definiteFormPreceders: Set<String> = [
        "the", "this", "that", "a", "an",
        "registration", "application", "contact", "order", "feedback", "consent", "release",
        "tax", "entry", "intake", "signup", "login", "web", "html", "input", "search",
        "payment", "booking", "request", "claim", "enrollment", "enrolment", "survey"
    ]

    private static let modalAuxiliaries: Set<String> = [
        "will", "won't", "would", "wouldn't", "can", "can't", "cannot", "could", "couldn't",
        "should", "shouldn't", "must", "may", "might", "shall", "do", "don't", "does",
        "doesn't", "did", "didn't", "help", "helped", "helps"
    ]

    private static let existentialBeVerbs: Set<String> = [
        "is", "isn't", "are", "aren't", "was", "wasn't", "were", "weren't",
        "has", "hasn't", "have", "haven't", "had", "hadn't",
        "will", "won't", "would", "wouldn't", "can", "can't", "could", "couldn't",
        "should", "shouldn't", "must", "may", "might",
        "seems", "seem", "seemed", "appears", "appear", "appeared",
        "exists", "exist", "existed", "remains", "remain", "remained"
    ]

    private static let participleVerbsAfterPronounBe: Set<String> = [
        "going", "coming", "working", "trying", "looking", "waiting", "making", "doing",
        "getting", "taking", "giving", "using", "running", "walking", "talking", "saying",
        "thinking", "feeling", "having", "being", "leaving", "staying", "playing", "watching",
        "reading", "writing", "building", "shipping", "testing", "fixing", "moving",
        "starting", "stopping", "calling", "asking", "helping", "sending", "bringing",
        "buying", "selling", "paying", "living", "sleeping", "eating", "drinking",
        "driving", "flying", "traveling", "travelling", "planning", "hoping", "expecting",
        "wondering", "worrying", "smiling", "laughing", "crying", "fighting", "winning",
        "losing", "sitting", "standing", "holding", "carrying", "wearing", "studying",
        "learning", "teaching", "cooking", "cleaning", "washing", "packing", "opening",
        "closing", "finishing", "changing", "growing", "falling", "rising", "breaking"
    ]

    private static let theyAreFollowers: Set<String> = [
        "not", "never", "always", "already", "still", "just", "only", "also", "even",
        "almost", "nearly", "quite", "very", "too", "so", "really", "pretty", "fairly",
        "rather", "probably", "definitely", "certainly", "surely", "likely", "unlikely",
        "here", "there", "back", "away", "out", "up", "down", "in", "off", "on", "over",
        "done", "finished", "ready", "sure", "right", "wrong", "late", "early",
        "happy", "glad", "sad", "sorry", "afraid", "scared", "tired", "sick", "busy",
        "free", "available", "welcome", "able", "unable", "supposed", "meant", "allowed",
        "expected", "required", "invited", "married", "engaged", "related", "a", "an", "the"
    ]

    private static let theyAreAdjectiveFollowers: Set<String> = [
        "not", "never", "always", "already", "still", "probably", "definitely", "certainly",
        "ready", "sure", "right", "wrong", "late", "early", "happy", "glad", "sorry",
        "afraid", "scared", "tired", "sick", "busy", "welcome", "able", "unable",
        "supposed", "meant", "allowed", "expected", "required", "invited"
    ]

    private static let locativeTherePreceders: Set<String> = [
        "over", "out", "right", "up", "down", "back", "go", "goes", "went", "gone",
        "going", "stay", "stayed", "staying", "live", "lived", "living", "sit", "sat",
        "sitting", "stand", "stood", "standing", "been", "arrive", "arrived"
    ]

    private static let clauseContinuationFollowers: Set<String> = [
        "in", "on", "at", "for", "with", "by", "to", "from", "since", "until", "before",
        "after", "when", "while", "if", "because", "and", "or", "but", "so", "yet",
        "too", "either", "instead", "now", "then", "today", "tomorrow", "yesterday",
        "soon", "already", "still", "again", "once", "twice"
    ]

    private static let possessedNouns: Set<String> = [
        "own", "house", "home", "homes", "car", "cars", "dog", "dogs", "cat", "cats",
        "pet", "pets", "team", "teams", "work", "job", "jobs", "office", "room", "rooms",
        "desk", "desks", "table", "chair", "bed", "door", "window", "phone", "phones",
        "computer", "computers", "laptop", "bag", "bags", "keys", "key", "wallet", "money",
        "clothes", "coat", "shoes", "hat", "book", "books", "notes", "note", "paper",
        "papers", "files", "file", "data", "code", "app", "project", "projects", "plan",
        "plans", "idea", "ideas", "goal", "goals", "name", "names", "way", "ways", "life",
        "lives", "time", "turn", "place", "seat", "seats", "hands", "hand", "eyes", "head",
        "heads", "mind", "minds", "heart", "hearts", "voice", "voices", "words", "word",
        "story", "stories", "family", "families", "parents", "mother", "father", "mom",
        "dad", "brother", "sister", "child", "children", "kids", "kid", "son", "daughter",
        "friend", "friends", "neighbor", "neighbors", "neighbour", "neighbours", "boss",
        "manager", "client", "clients", "customer", "customers", "user", "users", "member",
        "members", "partner", "partners", "wife", "husband", "best", "first", "last",
        "new", "old", "next", "previous", "current", "final", "original", "favorite", "favourite"
    ]

    private static let singularPossessedNouns: Set<String> = [
        "house", "home", "car", "dog", "cat", "pet", "team", "work", "job", "office",
        "room", "desk", "table", "chair", "bed", "door", "window", "phone", "computer",
        "laptop", "bag", "key", "wallet", "money", "coat", "hat", "book", "note", "paper",
        "file", "data", "code", "app", "project", "plan", "idea", "goal", "name", "way",
        "life", "turn", "place", "seat", "hand", "head", "mind", "heart", "voice", "word",
        "story", "family", "mother", "father", "mom", "dad", "brother", "sister", "child",
        "kid", "son", "daughter", "friend", "neighbor", "neighbour", "boss", "manager",
        "wife", "husband", "favorite", "favourite"
    ]

    private static let yourOnlyPossessedNouns: Set<String> = [
        "account", "password", "email", "address", "number", "order", "request", "message",
        "letter", "question", "answer", "help", "support", "attention", "patience",
        "feedback", "opinion", "thoughts", "fault", "problem", "choice", "decision",
        "responsibility", "side"
    ]

    private static let itsPossessedNouns: Set<String> = [
        "own", "tail", "head", "wings", "paws", "legs", "eyes", "ears", "mouth", "nose",
        "fur", "feathers", "shell", "skin", "bark", "leaves", "roots", "branches",
        "flowers", "fruit", "seeds", "color", "colour", "shape", "size", "weight",
        "height", "length", "width", "depth", "speed", "power", "strength", "value",
        "price", "cost", "worth", "name", "title", "purpose", "function", "role", "place",
        "position", "location", "origin", "source", "history", "future", "past", "fate",
        "nature", "character", "style", "design", "structure", "form", "content",
        "contents", "meaning", "sense", "effect", "impact", "influence", "result",
        "results", "owner", "creator", "author", "maker", "users", "members", "citizens",
        "residents", "inhabitants", "population", "neighbors", "neighbours", "borders",
        "limits", "boundaries", "edges", "surface", "center", "centre", "core", "heart",
        "top", "bottom", "side", "sides", "front", "back", "inside", "outside", "door",
        "doors", "windows", "roof", "walls", "floor", "wheels", "engine", "battery",
        "screen", "keyboard", "case", "cover", "lid", "cap", "handle", "peak", "summit",
        "base", "foot", "course", "path", "way", "track", "orbit", "flight", "journey",
        "destination", "goal", "target", "end", "beginning", "start", "launch", "release",
        "version", "state", "status", "condition", "quality", "performance", "capacity",
        "potential", "ability", "flaws", "faults", "merits", "benefits", "advantages",
        "disadvantages", "drawbacks", "risks", "costs", "rules", "laws", "policies",
        "terms", "first", "last", "current", "original", "final", "previous", "next",
        "main", "primary", "entire", "whole", "full", "best", "worst", "highest", "lowest"
    ]

    private static let possessiveContextPreceders: Set<String> = [
        "in", "on", "at", "to", "for", "with", "by", "from", "into", "onto", "upon",
        "about", "around", "through", "across", "behind", "under", "over", "between",
        "among", "without", "within", "despite", "during", "before", "after", "since",
        "until", "like", "as", "of", "and", "or", "but",
        "lost", "lose", "losing", "found", "find", "finding", "took", "take", "taking",
        "brought", "bring", "bringing", "forgot", "forget", "forgetting", "left", "leave",
        "leaving", "kept", "keep", "keeping", "gave", "give", "giving", "sent", "send",
        "sending", "sold", "sell", "selling", "bought", "buy", "buying", "built", "build",
        "building", "made", "make", "making", "used", "use", "using", "changed", "change",
        "changing", "fixed", "fix", "fixing", "broke", "break", "breaking", "packed",
        "pack", "packing", "washed", "wash", "washing", "cleaned", "clean", "cleaning",
        "opened", "open", "opening", "closed", "close", "closing", "finished", "finish",
        "finishing", "started", "start", "starting", "loved", "love", "loving", "liked",
        "helped", "help", "helping", "visited", "visit", "visiting", "met", "meet",
        "meeting", "saw", "see", "seeing", "heard", "hear", "hearing", "asked", "ask",
        "asking", "told", "tell", "telling", "showed", "show", "showing", "called",
        "call", "calling", "wagged", "wag", "wagging", "chased", "chase", "chasing",
        "reached", "reach", "reaching", "dropped", "drop", "dropping", "held", "hold",
        "holding", "checked", "check", "checking", "updated", "update", "updating",
        "raised", "raise", "raising", "lowered", "lower", "lowering"
    ]

    private static let nounPhraseFollowingVerbs: Set<String> = [
        "is", "isn't", "are", "aren't", "was", "wasn't", "were", "weren't",
        "has", "hasn't", "have", "haven't", "had", "hadn't",
        "will", "won't", "would", "wouldn't", "can", "can't", "could", "couldn't",
        "should", "shouldn't", "must", "may", "might",
        "won", "lost", "broke", "worked", "works", "arrived", "left", "came", "went",
        "started", "ended", "changed", "helped", "cost", "costs", "took", "takes",
        "looks", "looked", "seems", "seemed", "needs", "needed", "wants", "wanted",
        "said", "says", "told", "asked", "called", "barked", "ran", "fell", "grew"
    ]

    private static let losePreceders: Set<String> = [
        "to", "will", "won't", "would", "wouldn't", "can", "can't", "cannot", "could",
        "couldn't", "should", "shouldn't", "must", "mustn't", "may", "might", "shall",
        "do", "don't", "does", "doesn't", "did", "didn't", "never", "always", "often",
        "sometimes", "almost", "nearly", "easily", "soon", "eventually", "finally",
        "not", "you", "we", "they", "i"
    ]

    private static let loseDirectObjects: Set<String> = [
        "weight", "track", "sight", "hope", "patience", "interest", "focus", "control",
        "sleep", "money", "time", "touch", "count", "faith", "confidence", "momentum",
        "ground", "steam", "traction", "heart", "courage", "temper", "cool", "face",
        "altitude", "speed", "power", "signal", "connection", "data", "files", "work",
        "progress", "points", "games", "matches", "elections", "customers", "users",
        "clients", "followers", "subscribers", "jobs", "lives", "blood", "water", "heat",
        "value", "meaning", "my", "your", "his", "her", "its", "our", "their", "the",
        "a", "an", "this", "that", "these", "those", "any", "some", "all", "most",
        "half", "both", "everything", "nothing", "something", "anything", "it", "them",
        "him", "us", "you", "me"
    ]

    private static let looseIdiomaticVerbs: Set<String> = [
        "break", "breaks", "broke", "broken", "breaking",
        "cut", "cuts", "cutting",
        "let", "lets", "letting",
        "set", "sets", "setting",
        "hang", "hangs", "hung", "hanging",
        "come", "comes", "came", "coming",
        "get", "gets", "got", "getting",
        "turn", "turns", "turned", "turning",
        "run", "runs", "ran", "running",
        "slip", "slipped", "work", "worked",
        "tear", "tore", "torn", "shake", "shook", "shaken",
        "knock", "knocked", "pry", "pried", "pull", "pulled",
        "wrench", "wrenched", "tie", "tied", "wear", "wore", "worn",
        "keep", "kept", "leave", "left"
    ]

    private static let looseAdjectivePreceders: Set<String> = [
        "is", "isn't", "are", "aren't", "was", "wasn't", "were", "weren't",
        "be", "been", "being", "become", "became", "feel", "feels", "felt",
        "look", "looks", "looked", "seem", "seems", "seemed", "stay", "stayed",
        "remain", "remained", "very", "too", "so", "quite", "rather", "pretty",
        "fairly", "on"
    ]

    private static let determinersForAdjective: Set<String> = [
        "a", "an", "the", "this", "that", "these", "those", "some", "any", "no",
        "every", "each", "another", "two", "three", "several", "many", "few"
    ]

    private static let looseModifiableNouns: Set<String> = [
        "end", "ends", "screw", "screws", "tooth", "teeth", "knot", "knots", "thread",
        "threads", "fit", "fitting", "cannon", "cannons", "change", "coins", "leaf",
        "pages", "sheets", "papers", "skin", "clothing", "clothes", "shirt", "pants",
        "trousers", "dress", "jacket", "coat", "shoes", "belt", "collar", "grip", "hold",
        "handle", "wheel", "wire", "wires", "cable", "cables", "connection", "joint",
        "bolt", "bolts", "nail", "nails", "hinge", "hinges", "stone", "stones", "gravel",
        "sand", "soil", "dirt", "rock", "rocks", "tea", "powder", "flour", "hair",
        "curls", "translation", "interpretation", "definition", "sense", "term", "terms",
        "alliance", "coalition", "federation", "network", "collection", "group", "structure"
    ]

    private static let comparativeWords: Set<String> = [
        "more", "less", "fewer", "better", "worse", "rather", "other", "faster", "slower",
        "bigger", "smaller", "larger", "shorter", "longer", "higher", "lower", "older",
        "younger", "easier", "harder", "stronger", "weaker", "closer", "further", "farther",
        "cheaper", "safer", "louder", "quieter", "simpler", "greater", "heavier", "lighter",
        "wider", "narrower", "deeper", "shallower", "richer", "poorer", "smarter", "nicer",
        "clearer", "cleaner", "happier", "quicker", "sooner", "earlier", "later", "brighter",
        "darker", "warmer", "cooler", "colder", "hotter", "thicker", "thinner", "sharper",
        "softer", "smoother", "rougher", "tighter", "looser", "sweeter", "taller", "broader",
        "steeper", "fresher", "stranger", "rarer", "finer", "purer", "truer", "healthier",
        "wealthier", "busier", "lazier", "luckier", "prettier", "uglier", "angrier",
        "hungrier", "noisier", "friendlier", "likelier", "deadlier", "costlier", "different",
        "else"
    ]

    private static let nonComparativeInterveners: Set<String> = [
        "and", "or", "but", "to", "in", "on", "at", "from", "with", "for", "of", "by",
        "is", "are", "was", "were", "have", "has", "had", "will", "would", "can", "could",
        "should", "do", "does", "did"
    ]

    private static let subjectStartersAfterThen: Set<String> = [
        "i", "you", "he", "she", "it", "we", "they", "there", "the", "a", "an",
        "this", "that", "my", "our", "your", "his", "her", "their", "again",
        "maybe", "perhaps", "suddenly", "finally", "eventually", "came", "went"
    ]

    private static let temporalThenPreceders: Set<String> = [
        "and", "but", "until", "till", "since", "by", "before", "after", "back",
        "right", "just", "even", "only"
    ]

    private static let unconditionalItIsFollowers: Set<String> = [
        "a", "an", "the", "not", "never", "always", "already", "still", "almost", "nearly",
        "quite", "very", "too", "so", "really", "pretty", "fairly", "rather", "been",
        "being", "going", "coming", "getting", "making", "doing", "having", "raining",
        "snowing", "happening", "becoming", "called", "named", "known", "meant", "supposed",
        "expected", "located", "based", "important", "impossible", "unlikely", "obvious",
        "necessary", "essential", "crucial", "worth", "fine", "okay", "ok", "alright",
        "here", "there", "where", "when", "why", "how", "because", "what", "who",
        "my", "your", "his", "her", "our", "their", "nothing", "something", "anything",
        "everything", "someone", "nobody", "everyone"
    ]

    private static let predicativeItIsFollowers: Set<String> = [
        "easy", "easier", "hard", "harder", "difficult", "simple", "simpler", "possible",
        "likely", "certain", "sure", "clear", "true", "false", "right", "wrong", "fair",
        "unfair", "safe", "unsafe", "dangerous", "useful", "useless", "helpful", "common",
        "rare", "normal", "strange", "weird", "odd", "funny", "interesting", "amazing",
        "wonderful", "terrible", "awful", "horrible", "sad", "happy", "cold", "hot",
        "warm", "cool", "dark", "bright", "quiet", "loud", "fast", "slow", "ready",
        "done", "finished", "over", "late", "early", "broken", "fixed", "working",
        "running", "starting", "stopping", "growing", "changing", "moving", "looking",
        "feeling", "sounding", "turning", "made", "built", "designed", "written", "used",
        "allowed", "included", "needed", "good", "great", "nice", "better", "bad", "worse",
        "time", "much", "far", "just", "only", "also", "even"
    ]

    private static let clauseIntroducersBeforeItIs: Set<String> = [
        "that", "because", "since", "as", "if", "when", "while", "though", "although",
        "unless", "until", "whether", "and", "but", "or", "so", "yet",
        "think", "thought", "know", "knew", "say", "said", "says", "believe", "hope",
        "see", "saw", "find", "found", "feel", "felt", "guess", "suppose", "mean",
        "means", "meant", "show", "shows", "showed", "prove", "proves", "proved",
        "ensure", "realize", "realized", "realise", "realised", "notice", "noticed",
        "hear", "heard", "tell", "told", "sure", "certain", "glad", "happy", "sorry",
        "afraid", "clear", "obvious", "true"
    ]

    private static let nonNounAfterPredicativeAdjective: Set<String> = [
        "to", "that", "for", "in", "on", "at", "with", "from", "by", "about", "as",
        "if", "when", "while", "because", "since", "though", "although", "unless",
        "until", "and", "or", "but", "so", "yet", "enough", "too", "now", "today",
        "here", "there", "again", "better", "worse", "faster", "slower", "easier",
        "harder", "more", "less"
    ]

    private static let youAreUnconditionalFollowers: Set<String> = [
        "welcome", "right", "wrong", "sure", "ready", "late", "early", "done", "finished",
        "invited", "allowed", "supposed", "meant", "expected", "required", "able", "unable",
        "not", "never", "always", "already", "still", "probably", "definitely", "certainly",
        "here", "there", "back", "out", "up", "down", "in", "on", "off", "over", "under",
        "a", "an", "the", "so", "too", "quite", "really", "pretty"
    ]

    private static let whoIsFollowers: Set<String> = [
        "there", "here", "ready", "next", "first", "last", "in", "on", "at", "up", "out",
        "back", "with", "for", "against", "behind", "responsible", "available", "free",
        "busy", "late", "early", "right", "wrong", "sure", "afraid", "happy", "glad",
        "sorry", "tired", "sick", "been", "got", "a", "an", "the", "not", "never",
        "always", "already", "still"
    ]

    private static let tooDegreeAdjectives: Set<String> = [
        "late", "early", "soon", "long", "short", "far", "close", "high", "low", "fast",
        "slow", "big", "small", "large", "hard", "easy", "difficult", "heavy", "light",
        "hot", "cold", "warm", "cool", "old", "young", "expensive", "cheap", "busy",
        "tired", "weak", "strong", "loud", "quiet", "dark", "bright", "tight", "loose",
        "deep", "shallow", "wide", "narrow", "thick", "thin", "sweet", "salty", "bitter",
        "sour", "spicy", "good", "bad"
    ]

    private static let copularAndDegreePrecedersForToo: Set<String> = [
        "is", "isn't", "are", "aren't", "was", "wasn't", "were", "weren't", "be", "been",
        "being", "seem", "seems", "seemed", "look", "looks", "looked", "feel", "feels",
        "felt", "sound", "sounds", "sounded", "become", "became", "get", "gets", "got",
        "getting", "way", "far", "much", "all", "not", "it's", "that's", "there's",
        "he's", "she's", "you're", "we're", "they're", "i'm"
    ]

    private static let infinitiveOrPrepositionToPreceders: Set<String> = [
        "want", "wants", "wanted", "need", "needs", "needed", "have", "has", "had",
        "used", "ought", "supposed", "going", "try", "tries", "tried", "trying",
        "start", "starts", "started", "begin", "begins", "began", "continue", "continued",
        "decide", "decided", "plan", "planned", "hope", "hoped", "expect", "expected",
        "learn", "learned", "like", "liked", "love", "loved", "prefer", "preferred",
        "agree", "agreed", "refuse", "refused", "fail", "failed", "manage", "managed",
        "offer", "offered", "promise", "promised", "seem", "seemed", "appear", "appeared",
        "tend", "tended", "able", "unable", "ready", "willing", "eager", "happy", "glad",
        "sorry", "afraid", "easy", "hard", "difficult", "possible", "impossible",
        "important", "necessary", "time", "way", "place", "chance", "opportunity",
        "decision", "effort", "attempt", "order", "according", "due", "prior", "similar",
        "close", "next", "go", "goes", "went", "gone", "come", "comes", "came", "get",
        "got", "give", "gave", "send", "sent", "talk", "talked", "speak", "spoke",
        "listen", "listened", "write", "wrote", "move", "moved", "walk", "walked", "run",
        "ran", "drive", "drove", "fly", "flew", "return", "returned", "belong", "belongs",
        "belonged", "lead", "leads", "led", "refer", "refers", "referred", "apply",
        "applies", "applied", "respond", "responded", "reply", "replied", "look", "looked",
        "forward"
    ]

    private static let toInfinitiveVerbs: Set<String> = [
        "be", "do", "have", "make", "get", "go", "see", "know", "take", "find", "give",
        "tell", "work", "call", "try", "ask", "need", "feel", "become", "leave", "put",
        "mean", "keep", "let", "begin", "seem", "help", "talk", "turn", "start", "show",
        "hear", "play", "run", "move", "like", "live", "believe", "hold", "bring",
        "happen", "write", "provide", "sit", "stand", "lose", "pay", "meet", "include",
        "continue", "set", "learn", "change", "lead", "understand", "watch", "follow",
        "stop", "create", "speak", "read", "allow", "add", "spend", "grow", "open",
        "walk", "win", "offer", "remember", "love", "consider", "appear", "buy", "wait",
        "serve", "die", "send", "expect", "build", "stay", "fall", "cut", "reach",
        "remain", "suggest", "raise", "pass", "sell", "require", "report", "decide",
        "pull", "fix", "ship", "test", "use", "say", "check", "update", "save", "close"
    ]

    private static let weatherNounModifiers: Set<String> = [
        "the", "good", "bad", "nice", "great", "lovely", "beautiful", "awful", "terrible",
        "horrible", "warm", "cold", "hot", "cool", "wet", "dry", "stormy", "sunny",
        "rainy", "windy", "cloudy", "clear", "fair", "foul", "mild", "severe", "extreme",
        "inclement", "harsh", "winter", "summer", "spring", "autumn", "fall", "local",
        "today's", "tomorrow's"
    ]

    private static let weatherCompoundNouns: Set<String> = [
        "forecast", "report", "station", "conditions", "patterns", "radar", "channel",
        "warning", "alert", "advisory", "vane", "balloon"
    ]

    private static let effectNounPreceders: Set<String> = [
        "the", "an", "this", "that", "these", "those", "any", "no", "some", "every",
        "each", "little", "much", "positive", "negative", "side", "ripple", "butterfly",
        "greenhouse", "domino", "halo", "placebo", "network", "sound", "visual", "special",
        "net", "overall", "desired", "intended", "opposite", "same", "similar", "immediate",
        "lasting", "profound", "significant", "major", "minor", "direct", "indirect",
        "cumulative", "combined", "into", "take", "takes", "took", "taken", "taking"
    ]

    private static let affectVerbPreceders: Set<String> = [
        "will", "won't", "would", "wouldn't", "can", "can't", "cannot", "could", "couldn't",
        "should", "shouldn't", "must", "may", "might", "shall", "do", "don't", "does",
        "doesn't", "did", "didn't", "not", "never", "always", "often", "directly",
        "indirectly", "negatively", "positively", "adversely", "strongly", "deeply",
        "greatly", "significantly", "seriously", "badly", "hardly", "barely", "to"
    ]

    private static let affectVerbObjects: Set<String> = [
        "the", "a", "an", "this", "that", "these", "those", "my", "your", "his", "her",
        "its", "our", "their", "me", "you", "him", "us", "them", "how", "what", "whether",
        "who", "where", "when", "people", "users", "customers", "patients", "students",
        "workers", "everyone", "anybody", "someone", "nobody", "something", "nothing",
        "everything", "performance", "results", "sales", "health", "growth", "quality",
        "speed", "memory", "battery", "prices", "costs", "outcomes", "decisions",
        "behavior", "behaviour", "mood", "sleep", "traffic"
    ]

    private static let motionVerbsBeforePast: Set<String> = [
        "walked", "walk", "walking", "ran", "run", "running", "drove", "drive", "driving",
        "went", "go", "going", "came", "come", "coming", "flew", "fly", "flying",
        "moved", "move", "moving", "slipped", "slip", "rushed", "rush", "strolled",
        "stepped", "looked", "look", "looking", "got", "get", "getting"
    ]

    private static let pastTimeNouns: Set<String> = [
        "few", "several", "two", "three", "four", "five", "six", "seven", "eight", "nine",
        "ten", "couple", "week", "weeks", "month", "months", "year", "years", "day",
        "days", "hour", "hours", "minute", "minutes", "decade", "decades", "century",
        "night", "summer", "winter", "spring", "autumn", "fall", "weekend", "experience",
        "performance", "events", "mistakes", "history", "life"
    ]

    private static let clockNumbers: Set<String> = [
        "one", "two", "three", "four", "five", "six", "seven", "eight", "nine", "ten",
        "eleven", "twelve", "midnight", "noon"
    ]

    private static let passedAuxiliariesAndSubjects: Set<String> = [
        "i", "you", "he", "she", "it", "we", "they", "who",
        "has", "have", "had", "having", "was", "were", "been",
        "just", "already", "finally", "barely", "easily", "quickly", "slowly", "quietly"
    ]

    private static let exceptPreceders: Set<String> = [
        "all", "everyone", "everybody", "everything", "anyone", "anybody", "anything",
        "nobody", "nothing", "none", "nowhere"
    ]

    private static let acceptVerbPreceders: Set<String> = [
        "to", "will", "won't", "would", "wouldn't", "can", "can't", "cannot", "could",
        "couldn't", "should", "shouldn't", "must", "may", "might", "shall", "do", "don't",
        "does", "doesn't", "did", "didn't", "please", "gladly", "happily", "willingly",
        "reluctantly", "never", "always", "not", "i", "we", "they", "you"
    ]

    private static let acceptVerbObjects: Set<String> = [
        "the", "a", "an", "this", "that", "these", "those", "my", "your", "his", "her",
        "its", "our", "their", "any", "some", "no", "all", "full", "responsibility",
        "blame", "credit", "payment", "payments", "cards", "cash", "checks", "cheques",
        "returns", "applications", "offers", "invitations", "apologies", "terms",
        "conditions", "cookies", "changes", "input", "feedback", "deliveries", "orders",
        "donations", "gifts", "awards", "defeat", "reality", "it", "them"
    ]

    private static let principleModifiers: Set<String> = [
        "guiding", "moral", "ethical", "basic", "fundamental", "core", "general", "first",
        "underlying", "working", "operating", "organizing", "organising", "legal",
        "scientific", "mathematical", "design", "accounting", "economic", "political", "of"
    ]

    private static let principalFollowedNouns: Set<String> = [
        "investigator", "engineer", "architect", "designer", "scientist", "researcher",
        "developer", "author", "owner", "partner", "shareholder", "director", "officer",
        "dancer", "singer", "actor", "character", "component", "components", "reason",
        "reasons", "cause", "causes", "source", "sources", "factor", "factors", "purpose",
        "goal", "objective", "concern", "focus", "office", "residence", "amount", "balance"
    ]

    private static let pieceOfNouns: Set<String> = [
        "cake", "paper", "advice", "work", "code", "news", "information", "evidence",
        "art", "music", "writing", "hardware", "software", "equipment", "furniture",
        "clothing", "cloth", "wood", "metal", "glass", "plastic", "stone", "land",
        "meat", "bread", "cheese", "fruit", "pie", "pizza", "chocolate", "puzzle"
    ]

    private static let wherePrecedingNounsAndVerbs: Set<String> = [
        "know", "knew", "wonder", "wondered", "ask", "asked", "tell", "told", "see",
        "saw", "find", "found", "remember", "forgot", "forget", "show", "showed",
        "point", "place", "places", "area", "room", "house", "city", "town", "country",
        "world", "situation", "case", "cases"
    ]
}



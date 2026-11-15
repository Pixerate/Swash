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
import PixerateMarkdown

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

    init(
        paragraph: String,
        before: String? = nil,
        after: String? = nil,
        flavor: JazzTextFlavor = .gfm,
        voices: [JazzTextVoiceState] = [],
        teamId: String? = nil
    ) {
        self.paragraph = paragraph
        self.before = before
        self.after = after
        self.flavor = flavor
        self.voices = voices
        self.teamId = teamId
    }

    enum CodingKeys: String, CodingKey {
        case paragraph
        case before
        case after
        case flavor
        case voices
        case teamId
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.paragraph = try container.decode(String.self, forKey: .paragraph)
        self.before = try container.decodeIfPresent(String.self, forKey: .before)
        self.after = try container.decodeIfPresent(String.self, forKey: .after)
        self.flavor = try container.decodeIfPresent(JazzTextFlavor.self, forKey: .flavor) ?? .gfm
        self.voices = try container.decodeIfPresent([JazzTextVoiceState].self, forKey: .voices) ?? []
        self.teamId = try container.decodeIfPresent(String.self, forKey: .teamId)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(paragraph, forKey: .paragraph)
        try container.encodeIfPresent(before, forKey: .before)
        try container.encodeIfPresent(after, forKey: .after)
        try container.encode(flavor, forKey: .flavor)
        try container.encode(voices, forKey: .voices)
        try container.encodeIfPresent(teamId, forKey: .teamId)
    }
}

nonisolated struct JazzTextLeadResponse: Codable, Sendable, Equatable {
    var genre: JazzTextGenre
    var palette: [JazzTextVoice]
    var suggestions: [JazzTextSuggestion]
    var why: String
    var fuelBalance: Int?

    init(
        genre: JazzTextGenre,
        palette: [JazzTextVoice],
        suggestions: [JazzTextSuggestion] = [],
        why: String,
        fuelBalance: Int? = nil
    ) {
        self.genre = genre
        self.palette = palette
        self.suggestions = suggestions
        self.why = why
        self.fuelBalance = fuelBalance
    }

    enum CodingKeys: String, CodingKey {
        case genre
        case palette
        case suggestions
        case why
        case fuelBalance
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.genre = try container.decode(JazzTextGenre.self, forKey: .genre)
        self.palette = try container.decode([JazzTextVoice].self, forKey: .palette)
        self.suggestions = try container.decodeIfPresent([JazzTextSuggestion].self, forKey: .suggestions) ?? []
        self.why = try container.decode(String.self, forKey: .why)
        self.fuelBalance = try container.decodeIfPresent(Int.self, forKey: .fuelBalance)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(genre, forKey: .genre)
        try container.encode(palette, forKey: .palette)
        try container.encode(suggestions, forKey: .suggestions)
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

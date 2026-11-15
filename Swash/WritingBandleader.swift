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


// MARK: - Quick Note tidy-up (#108)
//
// A subscription feature: the tidy-up comes from jazz on the Pixerate server (Swash#61's boundary).
// Swash proposes it on pause or save, previews it, and applies it as one undo step. There are no
// local tidy rules: without Pixerate (signed in with Pro), Quick Notes aren't tidied.

extension JazzTextRange {
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


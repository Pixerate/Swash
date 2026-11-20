//
//  OnDeviceWritingBandleader.swift
//  Swash
//
//  The writing partner's on-device bandleader provider (macOS 26+, #102):
//  runs Apple's Foundation Models on-device with no account and no network.
//  Uses guided generation (`@Generable` types matching the schema) to guarantee
//  well-formed replies.
//

import Foundation

#if canImport(FoundationModels)
import FoundationModels

// MARK: - Guided Generation Types (@Generable)

@available(macOS 26.0, *)
@Generable
nonisolated enum OnDeviceGenre: String, Codable, Sendable, CaseIterable {
    case prose
    case notes
    case chat
    case poem
    case list
    case technical
    case heading

    var toJazzTextGenre: JazzTextGenre {
        JazzTextGenre(rawValue: rawValue) ?? .prose
    }
}

@available(macOS 26.0, *)
@Generable
nonisolated enum OnDeviceSuggestionKind: String, Codable, Sendable, CaseIterable {
    // Simple structure hints only (#102's limit); math, titles, alerts and quotes are the
    // subscription's, through jazz on the server
    case list
    case heading

    var toJazzTextSuggestionKind: JazzTextSuggestionKind {
        JazzTextSuggestionKind(rawValue: rawValue) ?? .list
    }
}

@available(macOS 26.0, *)
@Generable
nonisolated enum OnDeviceVoiceId: String, Codable, Sendable, CaseIterable {
    case punctuate
    case chat

    var toJazzTextVoiceId: JazzTextVoiceId {
        JazzTextVoiceId(rawValue: rawValue) ?? .punctuate
    }
}

@available(macOS 26.0, *)
@Generable
nonisolated struct OnDeviceRange: Codable, Sendable, Equatable {
    var start: Int
    var end: Int

    var toJazzTextRange: JazzTextRange {
        JazzTextRange(start: start, end: end)
    }
}

@available(macOS 26.0, *)
@Generable
nonisolated struct OnDeviceSuggestion: Codable, Sendable, Equatable {
    var kind: OnDeviceSuggestionKind
    var range: OnDeviceRange
    var replacement: String
    var why: String

    var toJazzTextSuggestion: JazzTextSuggestion {
        JazzTextSuggestion(
            kind: kind.toJazzTextSuggestionKind,
            range: range.toJazzTextRange,
            replacement: replacement,
            why: why
        )
    }
}

@available(macOS 26.0, *)
@Generable
nonisolated struct OnDeviceVoice: Codable, Sendable, Equatable {
    var voice: OnDeviceVoiceId
    var strength: Double
    var disabledRules: [String]?

    var toJazzTextVoice: JazzTextVoice {
        JazzTextVoice(
            voice: voice.toJazzTextVoiceId,
            strength: strength,
            disabledRules: disabledRules
        )
    }
}

@available(macOS 26.0, *)
@Generable
nonisolated enum OnDeviceGrammarRule: String, Codable, Sendable, CaseIterable {
    case agreementAndTense = "agreement-and-tense"
    case missingWords = "missing-words"

    var toJazzTextGrammarRule: JazzTextGrammarRule {
        JazzTextGrammarRule(rawValue: rawValue) ?? .agreementAndTense
    }
}

@available(macOS 26.0, *)
@Generable
nonisolated struct OnDeviceGrammarCorrection: Codable, Sendable, Equatable {
    var rule: OnDeviceGrammarRule
    var range: OnDeviceRange
    var replacement: String
    var confidence: Double
    var why: String?

    var toJazzTextGrammarCorrection: JazzTextGrammarCorrection {
        JazzTextGrammarCorrection(
            rule: rule.toJazzTextGrammarRule,
            range: range.toJazzTextRange,
            replacement: replacement,
            confidence: confidence,
            why: why
        )
    }
}

@available(macOS 26.0, *)
@Generable
nonisolated enum OnDeviceSpellingKind: String, Codable, Sendable, CaseIterable {
    /// A misspelling the sentence decides between.
    case spelling
    /// A real word used wrongly: form/from, there/their, loose/lose, then/than.
    case wrongWord

    var toJazzTextSuggestionKind: JazzTextSuggestionKind {
        self == .spelling ? .spelling : .wrongWord
    }
}

/// Context-aware spelling (#98): the word as written (the model's offsets aren't trusted), its
/// correction and the model's confidence.
@available(macOS 26.0, *)
@Generable
nonisolated struct OnDeviceSpellingCorrection: Codable, Sendable, Equatable {
    var kind: OnDeviceSpellingKind
    var original: String
    var replacement: String
    var confidence: Double

    var candidate: ContextSpellingCandidate {
        ContextSpellingCandidate(kind: kind.toJazzTextSuggestionKind, original: original, replacement: replacement,
                                 confidence: confidence)
    }
}

@available(macOS 26.0, *)
@Generable
nonisolated struct OnDeviceLeadResponse: Codable, Sendable, Equatable {
    var genre: OnDeviceGenre
    var palette: [OnDeviceVoice]
    var suggestions: [OnDeviceSuggestion]
    var grammar: [OnDeviceGrammarCorrection]
    var spelling: [OnDeviceSpellingCorrection]
    var why: String

    init(
        genre: OnDeviceGenre,
        palette: [OnDeviceVoice],
        suggestions: [OnDeviceSuggestion] = [],
        grammar: [OnDeviceGrammarCorrection] = [],
        spelling: [OnDeviceSpellingCorrection] = [],
        why: String
    ) {
        self.genre = genre
        self.palette = palette
        self.suggestions = suggestions
        self.grammar = grammar
        self.spelling = spelling
        self.why = why
    }

    /// The reply for `paragraph`, with its spelling corrections found in it and judged (#98).
    func toJazzTextLeadResponse(paragraph: String) -> JazzTextLeadResponse {
        var response = toJazzTextLeadResponse
        response.suggestions += ContextSpelling.suggestions(from: spelling.map(\.candidate), paragraph: paragraph)
        return response
    }

    var toJazzTextLeadResponse: JazzTextLeadResponse {
        JazzTextLeadResponse(
            genre: genre.toJazzTextGenre,
            palette: palette.map(\.toJazzTextVoice),
            suggestions: suggestions.map(\.toJazzTextSuggestion),
            grammar: grammar.map(\.toJazzTextGrammarCorrection),
            why: why,
            fuelBalance: nil
        )
    }
}

// MARK: - Availability Helper

/// Checks availability of on-device Foundation Models for Apple Intelligence.
@MainActor
final class OnDeviceBandleaderAvailability: Sendable {
    enum Status: Equatable, Sendable {
        case available
        case notAvailable(String)
        case unsupportedOS
    }

    static var currentStatus: Status {
        if #available(macOS 26.0, *) {
            let model = SystemLanguageModel.default
            switch model.availability {
            case .available:
                return .available
            case .unavailable(let reason):
                switch reason {
                case .deviceNotEligible:
                    return .notAvailable("Apple Intelligence is not supported on this Mac.")
                case .appleIntelligenceNotEnabled:
                    return .notAvailable("Apple Intelligence is turned off in System Settings.")
                case .modelNotReady:
                    return .notAvailable("Apple Intelligence model is downloading or preparing.")
                @unknown default:
                    return .notAvailable("Apple Intelligence is currently unavailable.")
                }
            }
        } else {
            return .unsupportedOS
        }
    }

    static var isAvailable: Bool {
        currentStatus == .available
    }

    static var statusMessage: String? {
        switch currentStatus {
        case .available:
            return "Ready (on-device Apple Intelligence)"
        case .notAvailable(let reason):
            return reason
        case .unsupportedOS:
            return "Requires macOS 26 or later with Apple Intelligence."
        }
    }
}

// MARK: - OnDeviceWritingBandleader

nonisolated final class OnDeviceWritingBandleader: WritingBandleader, @unchecked Sendable {
    var provider: WritingPartnerProvider { .onDevice }

    typealias Generator = @MainActor @Sendable (JazzTextLeadRequest) async throws -> JazzTextLeadResponse?

    private let customGenerator: Generator?
    private let timeoutNanoseconds: UInt64
    private let sessionLock = NSLock()
    private var sessionBox: Any? = nil

    /// System instructions for bandleader guidance.
    static let instructions = """
    You are Swash's writing partner on this Mac. Read only the paragraph you are given, with its \
    immediate context, and do four things. First, say what kind of text it is (prose, notes, chat, \
    poem, list, technical or heading), and hold back punctuation and grammar rules where they'd be \
    wrong, such as in a poem, dialogue or a quotation. Second, return word-level grammar corrections \
    with a confidence (0.0 to 1.0) for subject and verb agreement, tense that slips mid-sentence, \
    missing small words, and wrong word forms ("should of", "more better") — correct only a few words \
    and never rewrite for style, tone or length. Third, only if you are sure, suggest one simple \
    structure change: these lines are a list, or this line is a heading. Return no suggestions when \
    in doubt. Fourth, find spelling the system spell checker misses: a misspelt word whose fix \
    depends on the sentence, and a real word used wrongly (form for from, their or they're for \
    there, loose for lose, then for than). For each, give the word exactly as written in the \
    paragraph, the word it should be, whether it is a misspelling or a wrong word, and your \
    confidence (0.0 to 1.0). Never change names, product names, code, capitals or a word the \
    writer uses more than once. Give a short reason. Do nothing else.
    """

    init(
        customGenerator: Generator? = nil,
        timeoutSeconds: TimeInterval = 3.0
    ) {
        self.customGenerator = customGenerator
        self.timeoutNanoseconds = UInt64(max(0.1, timeoutSeconds) * 1_000_000_000)
    }

    /// Whether a cached session instance is currently stored.
    var hasActiveSession: Bool {
        sessionLock.lock()
        defer { sessionLock.unlock() }
        return sessionBox != nil
    }

    /// Resets the on-device session, clearing session memory and cached context.
    func resetSession() {
        sessionLock.lock()
        defer { sessionLock.unlock() }
        sessionBox = nil
        sessionTurns = 0
    }

    /// How many exchanges a shared session keeps before it starts again. The on-device model's
    /// context window is small (about 4,096 tokens) and every pause adds a paragraph with its
    /// context, so a long-lived session would otherwise grow until it overflows (SWA-30).
    static let maxTurnsPerSession = 6

    private var sessionTurns = 0

    /// The shared session for this document, or a new one. Returns `isShared == false` for a
    /// one-off session when the shared one is still answering an earlier pause (a timed-out or
    /// cancelled request that hasn't unwound yet): `LanguageModelSession` refuses overlapping
    /// requests, so the new pause must not wait on, or collide with, the old one.
    @available(macOS 26.0, iOS 26.0, *)
    private func currentOrNewSession() -> (session: LanguageModelSession, isShared: Bool) {
        sessionLock.lock()
        defer { sessionLock.unlock() }
        if let existing = sessionBox as? LanguageModelSession {
            if existing.isResponding {
                return (Self.makeSession(), false)
            }
            if sessionTurns < Self.maxTurnsPerSession {
                sessionTurns += 1
                return (existing, true)
            }
        }
        let newSession = Self.makeSession()
        sessionBox = newSession
        sessionTurns = 1
        return (newSession, true)
    }

    @available(macOS 26.0, iOS 26.0, *)
    private static func makeSession() -> LanguageModelSession {
        LanguageModelSession(model: .default, instructions: instructions)
    }

    /// Drops the shared session if it's still `session` (not one a later pause already replaced).
    @available(macOS 26.0, iOS 26.0, *)
    private func discardSession(_ session: LanguageModelSession) {
        sessionLock.lock()
        defer { sessionLock.unlock() }
        if let existing = sessionBox as? LanguageModelSession, existing === session {
            sessionBox = nil
            sessionTurns = 0
        }
    }

    func lead(request: JazzTextLeadRequest) async throws -> JazzTextLeadResponse? {
        // If a test or mock generator is provided, use it directly.
        if let customGenerator {
            return try await customGenerator(request)
        }

        if #available(macOS 26.0, *) {
            return try await leadOnDevice(request: request)
        } else {
            return nil
        }
    }

    @available(macOS 26.0, *)
    private func leadOnDevice(request: JazzTextLeadRequest) async throws -> JazzTextLeadResponse? {
        // Confirm model availability first
        guard case .available = SystemLanguageModel.default.availability else {
            return nil
        }

        // Run with timeout so slow responses skip this pause
        return try await withThrowingTaskGroup(of: JazzTextLeadResponse?.self) { group in
            group.addTask {
                try await self.performGeneration(request: request)
            }

            group.addTask {
                try await Task.sleep(nanoseconds: self.timeoutNanoseconds)
                return nil
            }

            // Return the first task to finish (either completion or timeout)
            let result = try await group.next() ?? nil
            group.cancelAll()
            return result
        }
    }

    @available(macOS 26.0, iOS 26.0, *)
    private func performGeneration(request: JazzTextLeadRequest, isRetry: Bool = false) async throws -> JazzTextLeadResponse? {
        let (session, isShared) = currentOrNewSession()
        do {
            let prompt = buildPrompt(for: request)
            let response = try await session.respond(
                to: prompt,
                generating: OnDeviceLeadResponse.self
            )

            return response.content.toJazzTextLeadResponse(paragraph: request.paragraph)
        } catch let error as LanguageModelSession.GenerationError {
            // A failed exchange can leave a refused or partial turn in the transcript, which would
            // colour every later pause: start the next one on a fresh session.
            if isShared { discardSession(session) }
            // Context window exceeded: the shared transcript filled up, so try this pause once more
            // on a fresh session rather than dropping it (SWA-30). Other errors (guardrail
            // refusals, rate limits, missing assets) quietly skip the pause.
            if case .exceededContextWindowSize = error, isShared, !isRetry, !Task.isCancelled {
                return try await performGeneration(request: request, isRetry: true)
            }
            return nil
        } catch {
            // Timed out, cancelled or another system error: skip this pause quietly.
            if isShared { discardSession(session) }
            return nil
        }
    }

    private func buildPrompt(for request: JazzTextLeadRequest) -> String {
        var parts: [String] = []

        if let before = request.before, !before.isEmpty {
            parts.append("Context before:\n\(before)")
        }

        parts.append("Current paragraph:\n\(request.paragraph)")

        if let after = request.after, !after.isEmpty {
            parts.append("Context after:\n\(after)")
        }

        parts.append("Markdown flavor: \(request.flavor.rawValue)")

        return parts.joined(separator: "\n\n")
    }
}

#else

// Fallback when FoundationModels cannot be imported (e.g. older SDKs)

nonisolated final class OnDeviceBandleaderAvailability: Sendable {
    enum Status: Equatable, Sendable {
        case available
        case notAvailable(String)
        case unsupportedOS
    }

    static var currentStatus: Status {
        .unsupportedOS
    }

    static var isAvailable: Bool {
        false
    }

    static var statusMessage: String? {
        "Requires macOS 26 or later with Apple Intelligence."
    }
}

nonisolated final class OnDeviceWritingBandleader: WritingBandleader, @unchecked Sendable {
    var provider: WritingPartnerProvider { .onDevice }

    typealias Generator = @MainActor @Sendable (JazzTextLeadRequest) async throws -> JazzTextLeadResponse?

    init(customGenerator: Generator? = nil, timeoutSeconds: TimeInterval = 3.0) {}

    var hasActiveSession: Bool { false }
    func resetSession() {}

    func lead(request: JazzTextLeadRequest) async throws -> JazzTextLeadResponse? {
        return nil
    }
}

#endif

extension WritingBandleaderFactory {
    static func installOnDeviceBandleader() {
        makeOnDeviceBandleader = { OnDeviceWritingBandleader() }
        isOnDeviceAvailable = { MainActor.assumeIsolated { OnDeviceBandleaderAvailability.isAvailable } }
    }
}

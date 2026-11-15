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
nonisolated struct OnDeviceLeadResponse: Codable, Sendable, Equatable {
    var genre: OnDeviceGenre
    var palette: [OnDeviceVoice]
    var suggestions: [OnDeviceSuggestion]
    var why: String

    var toJazzTextLeadResponse: JazzTextLeadResponse {
        JazzTextLeadResponse(
            genre: genre.toJazzTextGenre,
            palette: palette.map(\.toJazzTextVoice),
            suggestions: suggestions.map(\.toJazzTextSuggestion),
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
    typealias Generator = @MainActor @Sendable (JazzTextLeadRequest) async throws -> JazzTextLeadResponse?

    private let customGenerator: Generator?
    private let timeoutNanoseconds: UInt64

    /// System instructions for bandleader guidance.
    static let instructions = """
    You are Swash's writing partner on this Mac. Read only the paragraph you are given, with its \
    immediate context, and do two things. First, say what kind of text it is (prose, notes, chat, \
    poem, list, technical or heading), and hold back punctuation rules where they'd be wrong, such \
    as full stops in a poem or a list of fragments. Second, only if you are sure, suggest one simple \
    structure change: these lines are a list, or this line is a heading. Return no suggestions when \
    in doubt. Give a short reason. Do nothing else.
    """

    init(
        customGenerator: Generator? = nil,
        timeoutSeconds: TimeInterval = 3.0
    ) {
        self.customGenerator = customGenerator
        self.timeoutNanoseconds = UInt64(max(0.1, timeoutSeconds) * 1_000_000_000)
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

    @available(macOS 26.0, *)
    private func performGeneration(request: JazzTextLeadRequest) async throws -> JazzTextLeadResponse? {
        do {
            let session = LanguageModelSession(
                model: .default,
                instructions: Self.instructions
            )

            let prompt = buildPrompt(for: request)
            let response = try await session.respond(
                to: prompt,
                generating: OnDeviceLeadResponse.self
            )

            return response.content.toJazzTextLeadResponse
        } catch let error as LanguageModelSession.GenerationError {
            // Guardrail refusals, context window limits, rate limits handled quietly -> skip pause
            switch error {
            case .exceededContextWindowSize, .guardrailViolation, .refusal, .rateLimited, .assetsUnavailable:
                return nil
            default:
                return nil
            }
        } catch is CancellationError {
            // Timed out or cancelled
            return nil
        } catch {
            // Other system errors handled quietly
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
    typealias Generator = @MainActor @Sendable (JazzTextLeadRequest) async throws -> JazzTextLeadResponse?

    init(customGenerator: Generator? = nil, timeoutSeconds: TimeInterval = 3.0) {}

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

//
//  PixerateWritingBandleader.swift
//  Swash
//
//  The Pixerate bandleader provider (#101): calls `POST /api/agent/text-lead` through `PixerateAccess.post`
//  (GOTCHAS #77) when the person pauses while writing.
//
//  Handles a Basic plan (Pro required), `429` (rate-limited) and sign-out quietly, falling back to None.
//  Testable with a mock network layer so contributors don't need an account.
//

import Foundation
import PixerateAccount

nonisolated final class PixerateWritingBandleader: WritingBandleader, @unchecked Sendable {
    typealias PostHandler = @Sendable (_ path: String, _ body: Data) async throws -> Data
    typealias TeamIdProvider = @Sendable () -> String?

    private let postHandler: PostHandler?
    private let teamIdProvider: TeamIdProvider?

    init(
        postHandler: PostHandler? = nil,
        teamIdProvider: TeamIdProvider? = nil
    ) {
        self.postHandler = postHandler
        self.teamIdProvider = teamIdProvider
    }

    func lead(request: JazzTextLeadRequest) async throws -> JazzTextLeadResponse? {
        var req = request
        if req.teamId == nil {
            if let teamId = teamIdProvider?() {
                req.teamId = teamId
            } else if postHandler == nil {
                req.teamId = await MainActor.run { PixerateAccess.shared.account.activeTeam?.id }
            }
        }

        let body: Data
        do {
            let encoder = JSONEncoder()
            body = try encoder.encode(req)
        } catch {
            return nil
        }

        let responseData: Data
        do {
            if let postHandler {
                responseData = try await postHandler("/api/agent/text-lead", body)
            } else {
                responseData = try await PixerateAccess.shared.post(path: "/api/agent/text-lead", body: body)
            }
        } catch PixerateRefusal.subscriptionRequired {
            // Needs Pixerate Pro: handled quietly, falling back to None
            return nil
        } catch PixerateRefusal.rateLimited {
            // 429: handled quietly, falling back to None
            return nil
        } catch PixerateRefusal.signedOut {
            // Signed out (401 or not signed in): handled quietly, falling back to None
            return nil
        } catch PixerateRefusal.featureOff {
            // Feature disabled: handled quietly
            return nil
        } catch {
            // Any other server or connection failure: fall back quietly to None
            return nil
        }

        do {
            let decoder = JSONDecoder()
            return try decoder.decode(JazzTextLeadResponse.self, from: responseData)
        } catch {
            return nil
        }
    }

    func reportFeedback(_ request: JazzTextFeedbackRequest) async {
        guard !request.items.isEmpty else { return }
        var req = request
        if req.teamId == nil {
            if let teamId = teamIdProvider?() {
                req.teamId = teamId
            } else if postHandler == nil {
                req.teamId = await MainActor.run { PixerateAccess.shared.account.activeTeam?.id }
            }
        }

        let body: Data
        do {
            let encoder = JSONEncoder()
            body = try encoder.encode(req)
        } catch {
            return
        }

        do {
            if let postHandler {
                _ = try await postHandler("/api/agent/text-feedback", body)
            } else {
                _ = try await PixerateAccess.shared.post(path: "/api/agent/text-feedback", body: body)
            }
        } catch {
            // Feedback is best-effort; ignore refusal or offline errors quietly.
        }
    }
}

extension WritingBandleaderFactory {
    static func installPixerateBandleader() {
        makePixerateBandleader = { PixerateWritingBandleader() }
        isPixerateAvailable = { MainActor.assumeIsolated { !PixerateAccess.shared.isSignedOut && PixerateAccess.shared.isSubscribed } }
    }
}

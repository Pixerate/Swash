//
//  PixerateAccess.swift
//  Swash
//
//  The opt-in Pixerate account (#60). Swash works fully without it; signing in only enables the
//  writing partner's server features (#61), which call the Pixerate server when the writer pauses.
//  Every request to the server goes through `PixerateAccess.post`, which refuses before anything
//  is sent unless the person is signed in and the feature that asks has been turned on.
//

import Foundation
import Observation
import PixerateAccount
#if canImport(UIKit)
import UIKit
#endif

nonisolated enum PixerateDefaults {
    /// Overrides the server address (for a local Pixerate server). `PIXERATE_URL` in the
    /// environment wins over it.
    static let baseURL = "pixerateBaseURL"
    static let defaultBaseURL = URL(string: "https://pixerate.com")!
}

/// Why `PixerateAccess.post` sent nothing, or what the server refused.
nonisolated enum PixerateRefusal: Error, Equatable {
    /// Not signed in.
    case signedOut
    /// Signed in, but the feature that asked is off.
    case featureOff
    /// The account's team has no Fuel left. Nothing more is sent until the account is refreshed.
    case outOfFuel
    /// The server asked Swash to wait. Nothing is sent before this time.
    case rateLimited(until: Date)
    /// Any other failure, with the server's message when it gave one.
    case failed(status: Int, message: String?)
}

@MainActor
@Observable
final class PixerateAccess {
    static let clientId = "swash"
    static let callbackScheme = "swash"

    static let shared = PixerateAccess.make()

    let account: PixerateAccountClient

    /// Whether a feature that uses the server is on. Off until the writing partner (#61) sets it,
    /// so nothing can be sent by default.
    @ObservationIgnored var isFeatureEnabled: () -> Bool = { false }

    /// Set after the server reports no Fuel. Cleared by `refresh()` or a request that succeeds.
    private(set) var isOutOfFuel = false
    /// Set after the server asks Swash to wait (HTTP 429).
    private(set) var pausedUntil: Date?

    @ObservationIgnored private let session: URLSession
    @ObservationIgnored private let now: () -> Date

    init(account: PixerateAccountClient, session: URLSession = .shared, now: @escaping () -> Date = Date.init) {
        self.account = account
        self.session = session
        self.now = now
    }

    // MARK: Server address

    /// `PIXERATE_URL` from the environment, else the `pixerateBaseURL` default, else pixerate.com.
    nonisolated static func baseURL(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        defaults: UserDefaults = .standard
    ) -> URL {
        for candidate in [environment["PIXERATE_URL"], defaults.string(forKey: PixerateDefaults.baseURL)] {
            if let candidate, let url = URL(string: candidate.trimmingCharacters(in: .whitespaces)),
               let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http", url.host != nil {
                return url
            }
        }
        return PixerateDefaults.defaultBaseURL
    }

    /// The app's instance. Debug builds accept `--demo-auth` (signed in to a fake server, for
    /// working on the UI without an account) and `--demo-unauth` (signed out, nothing stored).
    static func make(arguments: [String] = ProcessInfo.processInfo.arguments) -> PixerateAccess {
        #if DEBUG
        if arguments.contains("--demo-auth") {
            let config = URLSessionConfiguration.ephemeral
            config.protocolClasses = [DemoPixerateURLProtocol.self]
            let session = URLSession(configuration: config)
            let account = PixerateAccountClient(
                baseURL: PixerateDefaults.defaultBaseURL,
                tokenStore: InMemoryTokenStore(token: "pix_live_demo_swash", selectedTeamId: "team_demo"),
                session: session
            )
            return PixerateAccess(account: account, session: session)
        }
        if arguments.contains("--demo-unauth") {
            return PixerateAccess(account: PixerateAccountClient(baseURL: PixerateDefaults.defaultBaseURL, tokenStore: InMemoryTokenStore()))
        }
        #endif
        return PixerateAccess(account: PixerateAccountClient(baseURL: baseURL()))
    }

    // MARK: Account

    /// Shows Pixerate's sign-in sheet. Cancelling sets no error.
    func signIn(presenter: (any PixerateWebAuthPresenter)? = nil) async {
        await account.signInWithApp(
            clientId: Self.clientId,
            callbackScheme: Self.callbackScheme,
            deviceName: Self.deviceName,
            presenter: presenter
        )
        if account.isAuthenticated { resetRefusals() }
    }

    /// Reloads the person and their teams, if a key is stored. Signed out, it sends nothing.
    func refresh() async {
        guard account.token != nil else { return }
        await account.restoreSession()
        resetRefusals()
    }

    func signOut() {
        account.signOut()
        resetRefusals()
    }

    /// Labels the key on the person's Pixerate account. Only the kind of device, never its name.
    static var deviceName: String {
        #if os(macOS)
        return "Swash (Mac)"
        #else
        return UIDevice.current.userInterfaceIdiom == .pad ? "Swash (iPad)" : "Swash (iPhone)"
        #endif
    }

    private func resetRefusals() {
        isOutOfFuel = false
        pausedUntil = nil
    }

    // MARK: Requests

    /// POSTs `body` (JSON) to `path` on the Pixerate server as the signed-in person, and returns the
    /// response body. Throws `PixerateRefusal`, without sending anything, when signed out, when the
    /// feature is off, after the server reported no Fuel, or while it has asked Swash to wait.
    func post(path: String, body: Data) async throws -> Data {
        guard isFeatureEnabled() else { throw PixerateRefusal.featureOff }
        guard account.token != nil else { throw PixerateRefusal.signedOut }
        if !account.isAuthenticated {
            await account.restoreSession()
            guard account.isAuthenticated else { throw PixerateRefusal.signedOut }
        }
        if isOutOfFuel { throw PixerateRefusal.outOfFuel }
        if let pausedUntil {
            if now() < pausedUntil { throw PixerateRefusal.rateLimited(until: pausedUntil) }
            self.pausedUntil = nil
        }

        // Callers put the active team (`account.activeTeam?.id`) in the body as `teamId`.
        let request = try account.authorizedRequest(path: path, method: "POST", body: body)
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw PixerateRefusal.failed(status: 0, message: nil)
        }
        switch http.statusCode {
        case 200..<300:
            isOutOfFuel = false
            return data
        case 401:
            // The key was revoked or has expired: the account is signed out.
            account.signOut()
            throw PixerateRefusal.signedOut
        case 402:
            isOutOfFuel = true
            throw PixerateRefusal.outOfFuel
        case 429:
            let seconds = http.value(forHTTPHeaderField: "Retry-After").flatMap(TimeInterval.init) ?? 30
            let until = now().addingTimeInterval(max(1, seconds))
            pausedUntil = until
            throw PixerateRefusal.rateLimited(until: until)
        default:
            let message = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error"] as? String
            throw PixerateRefusal.failed(status: http.statusCode, message: message)
        }
    }
}

#if DEBUG
/// The fake server behind `--demo-auth`: one person, two teams, some Fuel.
final class DemoPixerateURLProtocol: URLProtocol {
    override nonisolated class func canInit(with request: URLRequest) -> Bool { true }
    override nonisolated class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override nonisolated func stopLoading() {}

    override nonisolated func startLoading() {
        let url = request.url ?? PixerateDefaults.defaultBaseURL
        let (status, body): (Int, String)
        switch url.path {
        case "/api/teams":
            status = 200
            body = """
            {"user":{"id":"user_demo","email":"writer@example.com","displayName":"Demo Writer"},
             "defaultTeamId":"team_demo",
             "teams":[{"id":"team_demo","name":"Personal","ownerId":"user_demo","fuelBalance":42},
                      {"id":"team_studio","name":"Studio","ownerId":"user_other","fuelBalance":0}]}
            """
        default:
            status = 404
            body = #"{"error":"Not in the demo server."}"#
        }
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
}
#endif

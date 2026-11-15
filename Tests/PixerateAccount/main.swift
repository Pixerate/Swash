// Checks the Pixerate account gate (Swash/PixerateAccess.swift, #60) against a fake server.
// Run with scripts/run_account_tests.sh.

import Foundation
import PixerateAccount

// MARK: - Fake server

final class FakeServer: URLProtocol {
    struct Seen { let method: String; let path: String; let authorization: String?; let body: Data }
    nonisolated(unsafe) static var seen: [Seen] = []
    nonisolated(unsafe) static var reply: (URLRequest) -> (Int, [String: String], String) = { _ in (404, [:], "{}") }

    override nonisolated class func canInit(with request: URLRequest) -> Bool { true }
    override nonisolated class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override nonisolated func stopLoading() {}

    override nonisolated func startLoading() {
        var body = request.httpBody ?? Data()
        if body.isEmpty, let stream = request.httpBodyStream {
            stream.open()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let n = stream.read(&buffer, maxLength: buffer.count)
                if n <= 0 { break }
                body.append(buffer, count: n)
            }
            stream.close()
        }
        let url = request.url!
        Self.seen.append(Seen(method: request.httpMethod ?? "GET", path: url.path,
                              authorization: request.value(forHTTPHeaderField: "Authorization"), body: body))
        let (status, headers, text) = Self.reply(request)
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(text.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    static let proTeam = #"{"id":"t1","name":"Personal","ownerId":"u1","planId":"pro"}"#

    static func reset(
        team: String = proTeam,
        textLead: @escaping () -> (Int, [String: String], String) = { (200, [:], #"{"ok":true}"#) }
    ) {
        seen = []
        reply = { request in
            switch request.url!.path {
            case "/api/teams":
                return (200, [:], #"{"user":{"id":"u1","email":"a@example.com"},"defaultTeamId":"t1","teams":["# + team + "]}")
            case "/api/auth/app/token":
                return (200, [:], #"{"token":"pix_live_signed_in"}"#)
            case "/api/agent/text-lead":
                return textLead()
            default:
                return (404, [:], "{}")
            }
        }
    }
}

let session: URLSession = {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [FakeServer.self]
    return URLSession(configuration: config)
}()

final class Clock { var now = Date(timeIntervalSince1970: 1_000_000) }

func makeAccess(token: String?, featureOn: Bool, clock: Clock = Clock()) -> PixerateAccess {
    let account = PixerateAccountClient(
        baseURL: URL(string: "https://pixerate.test")!,
        tokenStore: InMemoryTokenStore(token: token),
        session: session
    )
    let access = PixerateAccess(account: account, session: session, now: { clock.now })
    if featureOn { access.isFeatureEnabled = { true } }
    return access
}

// MARK: - Checks

var failures = 0
var passes = 0
func check(_ condition: Bool, _ message: String, line: Int = #line) {
    if condition { passes += 1 } else { failures += 1; print("FAIL (line \(line)): \(message)") }
}

func refusal(_ access: PixerateAccess, path: String = "/api/agent/text-lead", body: Data = Data(#"{"paragraph":"hi"}"#.utf8)) async -> PixerateRefusal? {
    do {
        _ = try await access.post(path: path, body: body)
        return nil
    } catch let refusal as PixerateRefusal {
        return refusal
    } catch {
        print("unexpected error: \(error)")
        return .failed(status: -1, message: nil)
    }
}

// Signed out: nothing is ever sent, whether or not the feature is on.
do {
    FakeServer.reset()
    let access = makeAccess(token: nil, featureOn: true)
    await access.refresh()
    check(await refusal(access) == .signedOut, "signed out refuses")
    let off = makeAccess(token: nil, featureOn: false)
    check(await refusal(off) == .featureOff, "signed out with the feature off refuses")
    check(FakeServer.seen.isEmpty, "signed out sends nothing (sent \(FakeServer.seen.map(\.path)))")
}

// Signed in but the feature is off (the default): nothing is sent.
do {
    FakeServer.reset()
    let access = makeAccess(token: "pix_live_k", featureOn: false)
    check(await refusal(access) == .featureOff, "the feature is off by default")
    check(FakeServer.seen.isEmpty, "feature off sends nothing")
}

// Signed in and on: the session is restored, then the request goes out with the key.
do {
    FakeServer.reset()
    let access = makeAccess(token: "pix_live_k", featureOn: true)
    let data = try await access.post(path: "/api/agent/text-lead", body: Data(#"{"paragraph":"hi"}"#.utf8))
    check(String(decoding: data, as: UTF8.self) == #"{"ok":true}"#, "returns the response body")
    check(FakeServer.seen.map(\.path) == ["/api/teams", "/api/agent/text-lead"], "restores, then posts (\(FakeServer.seen.map(\.path)))")
    check(FakeServer.seen.last?.authorization == "Bearer pix_live_k", "sends the key")
    check(FakeServer.seen.last?.method == "POST", "posts")
    check(String(decoding: FakeServer.seen.last?.body ?? Data(), as: UTF8.self) == #"{"paragraph":"hi"}"#, "sends the body unchanged")
}

// The server says the plan needs Pro (402): refused, and nothing more is sent until a refresh.
do {
    FakeServer.reset(textLead: { (402, [:], #"{"error":"AI features are part of Pixerate Pro.","code":"subscription_required"}"#) })
    let access = makeAccess(token: "pix_live_k", featureOn: true)
    check(await refusal(access) == .subscriptionRequired, "402 needs Pro")
    check(access.needsSubscription && !access.isSubscribed, "needing Pro is remembered")
    let sent = FakeServer.seen.count
    check(await refusal(access) == .subscriptionRequired, "still needs Pro")
    check(FakeServer.seen.count == sent, "needing Pro sends nothing more")
    FakeServer.reset()
    await access.refresh()
    check(!access.needsSubscription && access.isSubscribed, "refresh clears it")
    check(await refusal(access) == nil, "sends again after a refresh")
}

// On the Basic plan: refused before anything is sent to the feature.
do {
    FakeServer.reset(team: #"{"id":"t1","name":"Personal","ownerId":"u1","planId":"free"}"#)
    let access = makeAccess(token: "pix_live_k", featureOn: true)
    check(await refusal(access) == .subscriptionRequired, "Basic is refused")
    check(FakeServer.seen.map(\.path) == ["/api/teams"], "Basic sends nothing to the feature (\(FakeServer.seen.map(\.path)))")
    check(access.planName == "Basic", "Basic plan name")
}

// A complimentary grant counts as Pro until it expires.
do {
    let clock = Clock()
    clock.now = Date(timeIntervalSince1970: 1_800_000_000)
    FakeServer.reset(team: #"{"id":"t1","name":"Personal","ownerId":"u1","planId":"free","complimentary":{"planId":"pro","expiresAt":"2030-01-01T00:00:00.000Z"}}"#)
    let access = makeAccess(token: "pix_live_k", featureOn: true, clock: clock)
    check(await refusal(access) == nil, "comped account is served")
    check(access.planName == "Pro (complimentary)", "comp plan name")
    clock.now = Date(timeIntervalSince1970: 1_900_000_000)
    check(!access.isSubscribed && access.planName == "Basic", "an expired comp is Basic")
    check(PixerateAccess.planSource(of: nil) == nil, "no team has no plan")
}

// Rate limited (429): wait for Retry-After before sending again.
do {
    let clock = Clock()
    FakeServer.reset(textLead: { (429, ["Retry-After": "30"], #"{"error":"Rate limit exceeded."}"#) })
    let access = makeAccess(token: "pix_live_k", featureOn: true, clock: clock)
    let until = clock.now.addingTimeInterval(30)
    check(await refusal(access) == .rateLimited(until: until), "429 waits for Retry-After")
    let sent = FakeServer.seen.count
    clock.now = clock.now.addingTimeInterval(10)
    check(await refusal(access) == .rateLimited(until: until), "still waiting after 10 s")
    check(FakeServer.seen.count == sent, "waiting sends nothing")
    clock.now = clock.now.addingTimeInterval(21)
    FakeServer.reset()
    check(await refusal(access) == nil, "sends again after Retry-After")
    check(access.pausedUntil == nil, "the wait is cleared")
}

// A revoked key (401): signed out.
do {
    FakeServer.reset(textLead: { (401, [:], #"{"error":"Sign in to use the Swash writing partner."}"#) })
    let access = makeAccess(token: "pix_live_k", featureOn: true)
    check(await refusal(access) == .signedOut, "401 is signed out")
    check(access.account.token == nil && !access.account.isAuthenticated, "401 removes the key")
}

// Other failures carry the server's message.
do {
    FakeServer.reset(textLead: { (502, [:], #"{"error":"Writing partner failed to respond."}"#) })
    let access = makeAccess(token: "pix_live_k", featureOn: true)
    check(await refusal(access) == .failed(status: 502, message: "Writing partner failed to respond."), "502 carries the message")
}

// Sign-in uses Swash's app client and redirect, and labels the key with the kind of device only.
@MainActor final class FakePresenter: PixerateWebAuthPresenter {
    var shown: URL?
    var scheme: String?
    func authenticate(url: URL, callbackScheme: String) async throws -> URL {
        shown = url
        scheme = callbackScheme
        let state = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "state" }?.value ?? ""
        return URL(string: "swash://auth?code=c1&state=\(state)")!
    }
}
do {
    FakeServer.reset()
    let access = makeAccess(token: nil, featureOn: false)
    let presenter = FakePresenter()
    await access.signIn(presenter: presenter)
    let query = URLComponents(url: presenter.shown!, resolvingAgainstBaseURL: false)?.queryItems ?? []
    check(query.first { $0.name == "client_id" }?.value == "swash", "client_id is swash")
    check(query.first { $0.name == "redirect_uri" }?.value == "swash://auth", "redirect is swash://auth")
    check(presenter.scheme == "swash", "callback scheme is swash")
    let exchange = FakeServer.seen.first { $0.path == "/api/auth/app/token" }
    let fields = (try? JSONSerialization.jsonObject(with: exchange?.body ?? Data())) as? [String: String] ?? [:]
    check(fields["device_name"] == "Swash (Mac)", "device name is the kind of device (\(fields["device_name"] ?? "nil"))")
    check(access.account.isAuthenticated, "signed in")
    check(access.planName == "Pro", "plan loaded")
}

// Server address: PIXERATE_URL, then the default, then pixerate.com.
do {
    let defaults = UserDefaults(suiteName: "swash-account-tests")!
    defaults.removePersistentDomain(forName: "swash-account-tests")
    check(PixerateAccess.baseURL(environment: [:], defaults: defaults).absoluteString == "https://pixerate.com", "defaults to pixerate.com")
    defaults.set("http://localhost:5173", forKey: PixerateDefaults.baseURL)
    check(PixerateAccess.baseURL(environment: [:], defaults: defaults).absoluteString == "http://localhost:5173", "the user default")
    check(PixerateAccess.baseURL(environment: ["PIXERATE_URL": "https://staging.pixerate.test"], defaults: defaults).absoluteString == "https://staging.pixerate.test", "the environment wins")
    check(PixerateAccess.baseURL(environment: ["PIXERATE_URL": "not a url"], defaults: defaults).absoluteString == "http://localhost:5173", "an invalid value is skipped")
    defaults.set("ftp://example.com", forKey: PixerateDefaults.baseURL)
    check(PixerateAccess.baseURL(environment: [:], defaults: defaults).absoluteString == "https://pixerate.com", "only http and https")
    defaults.removePersistentDomain(forName: "swash-account-tests")
}

// Server address validation and mutation (Settings › Account).
do {
    check(PixerateAccess.validateServerAddress("https://example.com")?.absoluteString == "https://example.com", "valid https url")
    check(PixerateAccess.validateServerAddress("http://localhost:8787")?.absoluteString == "http://localhost:8787", "valid http url with port")
    check(PixerateAccess.validateServerAddress("ftp://example.com") == nil, "ftp scheme is rejected")
    check(PixerateAccess.validateServerAddress("   ") == nil, "whitespace is rejected")
    check(PixerateAccess.validateServerAddress("not a url") == nil, "malformed string is rejected")

    let defaults = UserDefaults(suiteName: "swash-account-tests-settings")!
    defaults.removePersistentDomain(forName: "swash-account-tests-settings")
    let client = PixerateAccountClient(baseURL: PixerateDefaults.defaultBaseURL, tokenStore: InMemoryTokenStore())
    let access = PixerateAccess(account: client)
    check(client.baseURL.absoluteString == "https://pixerate.com", "initial default")
    access.setBaseURL(URL(string: "http://localhost:8787")!, defaults: defaults)
    check(client.baseURL.absoluteString == "http://localhost:8787", "custom base url applied to account client")
    check(defaults.string(forKey: PixerateDefaults.baseURL) == "http://localhost:8787", "saved in defaults")
    access.resetServerAddress(defaults: defaults)
    check(client.baseURL.absoluteString == "https://pixerate.com", "resetServerAddress restores default")
    check(defaults.string(forKey: PixerateDefaults.baseURL) == nil, "resetServerAddress clears defaults")
    defaults.removePersistentDomain(forName: "swash-account-tests-settings")
}

// Live integration tests against the writing-partner reference server.
if let serverURLString = ProcessInfo.processInfo.environment["SWASH_TEST_SERVER_URL"],
   let serverURL = URL(string: serverURLString) {
    let realSession = URLSession(configuration: .ephemeral)
    let tokenStore = InMemoryTokenStore(token: "test_local_token")
    let client = PixerateAccountClient(baseURL: serverURL, tokenStore: tokenStore, session: realSession)
    let access = PixerateAccess(account: client, session: realSession)
    access.isFeatureEnabled = { true }

    // Session restore via GET /api/teams
    await access.refresh()
    check(client.isAuthenticated, "reference server: session restored from /api/teams")
    check(client.user?.displayName == "Self-Hosted Writer", "reference server: user loaded")
    check(client.fuelBalance == 99999, "reference server: fuel loaded")

    // Successful POST /api/agent/text-lead
    do {
        let requestBody = Data(#"{"paragraph":"apples\npears\nplums","flavor":"gfm"}"#.utf8)
        let responseData = try await access.post(path: "/api/agent/text-lead", body: requestBody)
        let json = (try? JSONSerialization.jsonObject(with: responseData)) as? [String: Any] ?? [:]
        check(json["genre"] as? String == "notes", "reference server: detected notes genre")
        let palette = json["palette"] as? [[String: Any]] ?? []
        check(palette.first?["voice"] as? String == "punctuate", "reference server: returned palette")
        let suggestions = json["suggestions"] as? [[String: Any]] ?? []
        check(!suggestions.isEmpty, "reference server: generated list suggestion")
        check(suggestions.first?["kind"] as? String == "list", "reference server: suggestion kind is list")
    } catch {
        check(false, "reference server: post failed with error: \(error)")
    }

    // Limits enforcement: paragraph > 4000 UTF-16 units is rejected with 400
    do {
        let hugeParagraph = String(repeating: "a", count: 4001)
        let requestBody = try JSONSerialization.data(withJSONObject: ["paragraph": hugeParagraph])
        let outcome = await refusal(access, path: "/api/agent/text-lead", body: requestBody)
        if case .failed(let status, _) = outcome {
            check(status == 400, "reference server: rejects paragraph over 4000 chars with 400")
        } else {
            check(false, "reference server: did not reject huge paragraph with 400 (\(String(describing: outcome)))")
        }
    } catch {
        check(false, "unexpected error in limit test: \(error)")
    }

    // Error simulation: 402 returns outOfFuel
    do {
        let outcome = await refusal(access, path: "/api/agent/text-lead?status=402")
        check(outcome == .outOfFuel, "reference server: 402 simulated error returns outOfFuel")
        await access.refresh() // clear out of fuel
    }

    // Error simulation: 429 returns rateLimited
    do {
        let outcome = await refusal(access, path: "/api/agent/text-lead?status=429")
        if case .rateLimited = outcome {
            check(true, "reference server: 429 simulated error returns rateLimited")
        } else {
            check(false, "reference server: 429 did not return rateLimited (\(String(describing: outcome)))")
        }
    }

    // Error simulation: 401 signs out
    do {
        // Clear rate limit pause from previous test
        await access.refresh()
        let outcome = await refusal(access, path: "/api/agent/text-lead?status=401")
        check(outcome == .signedOut, "reference server: 401 simulated error returns signedOut")
        check(!client.isAuthenticated, "reference server: 401 revokes authentication")
    }
}

// --demo-auth signs in to the fake demo server.
do {
    let access = PixerateAccess.make(arguments: ["Swash", "--demo-auth"])
    await access.refresh()
    check(access.account.isAuthenticated, "demo is signed in")
    check(access.account.teams.count == 2 && access.isSubscribed, "demo teams, on Pro")
    let unauth = PixerateAccess.make(arguments: ["Swash", "--demo-unauth"])
    check(!unauth.account.isAuthenticated && unauth.account.token == nil, "demo-unauth is signed out")
}

// Purchases carry the token the server derives for the team (deriveAppAccountToken in @pixerate/teams).
check(PixerateAccountToken.uuid(teamId: "t1").uuidString.lowercased() == "cc207aed-d9f0-5d15-a499-f892bbf9390e",
      "purchase token matches the server's")

print("\(passes) passed, \(failures) failed")
exit(failures == 0 ? 0 : 1)

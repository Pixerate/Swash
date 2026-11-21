// Checks the Pixerate account & store gate (Swash/PixerateAccess.swift, #60, #149) against a fake
// server. Run with scripts/run_account_tests.sh.

import Foundation
import PixerateAccount
import PixerateStore

// MARK: - Fake server & StoreKit

final class FakeServer: URLProtocol {
    struct Seen {
        let method: String
        let path: String
        let authorization: String?
        let customerHeader: String?
        let body: Data
    }
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
        Self.seen.append(
            Seen(
                method: request.httpMethod ?? "GET",
                path: url.path,
                authorization: request.value(forHTTPHeaderField: "Authorization"),
                customerHeader: request.value(forHTTPHeaderField: "X-Pixerate-App-Store-Customer"),
                body: body
            )
        )
        let (status, headers, text) = Self.reply(request)
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(text.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    static let proTeam = #"{"id":"t1","name":"Personal","ownerId":"u1","planId":"pro"}"#
    static let proEntitlements = """
    {"entitlements":["pixerate_pro","swash_pro"],
     "grants":[{"entitlement":"pixerate_pro","source":"plan","via":"team","teamId":"t1"}],
     "supportId":"SUP-TEAM1"}
    """
    static let appStoreEntitlements = """
    {"entitlements":["swash_pro"],
     "grants":[{"entitlement":"swash_pro","source":"app_store","via":"customer","productId":"com.pixerate.swash.pro.monthly","ownership":"PURCHASED"}],
     "supportId":"SUP-APPL1",
     "customer":{"id":"cust_1","supportId":"SUP-APPL1"}}
    """
    static let freeEntitlements = """
    {"entitlements":[],"grants":[],"supportId":"SUP-FREE1"}
    """

    static func reset(
        team: String = proTeam,
        entitlements: String = proEntitlements,
        textLead: @escaping () -> (Int, [String: String], String) = { (200, [:], #"{"ok":true}"#) }
    ) {
        seen = []
        reply = { request in
            switch request.url!.path {
            case "/api/teams":
                return (200, [:], #"{"user":{"id":"u1","email":"a@example.com"},"defaultTeamId":"t1","teams":["# + team + "]}")
            case "/api/auth/app/token":
                return (200, [:], #"{"token":"pix_live_signed_in"}"#)
            case "/api/auth/app-store":
                return (200, [:], #"{"token":"cust_tok_1","customer":{"id":"cust_1","supportId":"SUP-APPL1"}}"#)
            case "/api/me/entitlements":
                return (200, [:], entitlements)
            case "/api/billing/apple/verify":
                return (200, [:], appStoreEntitlements)
            case "/api/agent/text-lead":
                return textLead()
            default:
                return (404, [:], "{}")
            }
        }
    }
}

struct FakeStoreKitClient: PixerateStoreKitClient {
    var appTransaction: String? = nil
    var activeTransactions: [PixerateStoreTransaction] = []

    func appTransactionJWS() async -> String? { appTransaction }
    func products(for ids: [String]) async throws -> [PixerateStoreProduct] {
        PixerateAccess.previewProducts.filter { ids.contains($0.id) }
    }
    func purchase(productId: String) async throws -> PixeratePurchaseOutcome {
        .purchased(
            PixerateStoreTransaction(
                id: 100,
                originalId: 100,
                productId: productId,
                jwsRepresentation: "jws_tx_\(productId)"
            )
        )
    }
    func sync() async throws {}
    func currentEntitlements() async -> [PixerateStoreTransaction] { activeTransactions }
    func unfinishedTransactions() async -> [PixerateStoreTransaction] { [] }
    func transactionUpdates() -> AsyncStream<PixerateStoreTransaction> {
        AsyncStream { $0.finish() }
    }
}

let session: URLSession = {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [FakeServer.self]
    return URLSession(configuration: config)
}()

nonisolated final class Clock: @unchecked Sendable { var now = Date(timeIntervalSince1970: 1_000_000) }

func makeAccess(
    token: String?,
    customerSession: PixerateCustomerSession? = nil,
    distributionMode: PixerateDistributionMode = .fixed(.direct),
    storeKit: FakeStoreKitClient = FakeStoreKitClient(),
    featureOn: Bool,
    clock: Clock = Clock()
) -> PixerateAccess {
    let account = PixerateAccountClient(
        baseURL: URL(string: "https://pixerate.test")!,
        tokenStore: InMemoryTokenStore(token: token),
        session: session
    )
    let access = PixerateAccess(
        account: account,
        session: session,
        distributionMode: distributionMode,
        storeKit: storeKit,
        sessionStore: InMemoryCustomerSessionStore(customerSession),
        now: { clock.now }
    )
    if featureOn { access.isFeatureEnabled = { true } }
    return access
}

// MARK: - Checks

var failures = 0
var passes = 0
func check(_ condition: Bool, _ message: String, line: Int = #line) {
    if condition { passes += 1 } else { failures += 1; print("FAIL (line \(line)): \(message)") }
}

func refusal(_ access: PixerateAccess, path: String = "/api/agent/text-lead") async -> PixerateRefusal? {
    do {
        _ = try await access.post(path: path, body: Data(#"{"paragraph":"hi"}"#.utf8))
        return nil
    } catch let refusal as PixerateRefusal {
        return refusal
    } catch {
        print("unexpected error: \(error)")
        return .failed(status: -1, message: nil)
    }
}

// Unauthenticated (no account token and no App Store customer session): nothing is ever sent.
do {
    FakeServer.reset()
    let access = makeAccess(token: nil, featureOn: true)
    await access.refresh()
    check(await refusal(access) == .signedOut, "unauthenticated refuses")
    let off = makeAccess(token: nil, featureOn: false)
    check(await refusal(off) == .featureOff, "unauthenticated with the feature off refuses")
    check(FakeServer.seen.isEmpty, "unauthenticated sends nothing (sent \(FakeServer.seen.map(\.path)))")
}

// Signed-out App Store customer with Swash Pro: works without a Pixerate account and sends
// X-Pixerate-App-Store-Customer with no Authorization header.
do {
    FakeServer.reset(entitlements: FakeServer.appStoreEntitlements)
    let custSession = PixerateCustomerSession(
        token: "cust_tok_1",
        expiresAt: nil,
        customer: PixerateAppStoreCustomer(id: "cust_1", supportId: "SUP-APPL1")
    )
    let access = makeAccess(
        token: nil,
        customerSession: custSession,
        distributionMode: .fixed(.appStore),
        featureOn: true
    )
    await access.refresh()
    check(access.isSignedOut, "no Pixerate account signed in")
    check(access.isSubscribed, "subscribed through the App Store without an account")
    check(access.store.supportId == "SUP-APPL1", "Support ID is populated for signed-out App Store customer")
    check(access.store.proSource == .appStore(familyShared: false), "proSource is appStore(familyShared: false)")
    let data = try await access.post(path: "/api/agent/text-lead", body: Data(#"{"paragraph":"hi"}"#.utf8))
    check(String(decoding: data, as: UTF8.self) == #"{"ok":true}"#, "signed-out Pro customer receives response")
    check(FakeServer.seen.last?.customerHeader == "cust_tok_1", "sends X-Pixerate-App-Store-Customer header")
    check(FakeServer.seen.last?.authorization == nil, "does not send Authorization header when signed out")
}

// Signed-out App Store customer without Pro: refused before sending to the feature.
do {
    FakeServer.reset(entitlements: FakeServer.freeEntitlements)
    let custSession = PixerateCustomerSession(
        token: "cust_tok_free",
        expiresAt: nil,
        customer: PixerateAppStoreCustomer(id: "cust_free", supportId: "SUP-FREE1")
    )
    let access = makeAccess(
        token: nil,
        customerSession: custSession,
        distributionMode: .fixed(.appStore),
        featureOn: true
    )
    check(await refusal(access) == .subscriptionRequired, "signed-out free App Store customer is refused")
    check(!FakeServer.seen.map(\.path).contains("/api/agent/text-lead"), "sends nothing to /api/agent/text-lead")
    check(access.store.supportId == "SUP-FREE1", "Support ID is still available for free App Store customer")
}

// Signed in with both App Store customer session and Pixerate account: sends both headers.
do {
    FakeServer.reset(entitlements: FakeServer.appStoreEntitlements)
    let custSession = PixerateCustomerSession(
        token: "cust_tok_1",
        expiresAt: nil,
        customer: PixerateAppStoreCustomer(id: "cust_1", supportId: "SUP-APPL1")
    )
    let access = makeAccess(
        token: "pix_live_k",
        customerSession: custSession,
        distributionMode: .fixed(.appStore),
        featureOn: true
    )
    _ = try await access.post(path: "/api/agent/text-lead", body: Data(#"{"paragraph":"hi"}"#.utf8))
    check(FakeServer.seen.last?.customerHeader == "cust_tok_1", "sends customer header when both exist")
    check(FakeServer.seen.last?.authorization == "Bearer pix_live_k", "sends bearer token when both exist")
}

// Signed in but the feature is off (the default): nothing is sent.
do {
    FakeServer.reset()
    let access = makeAccess(token: "pix_live_k", featureOn: false)
    check(await refusal(access) == .featureOff, "the feature is off by default")
    check(FakeServer.seen.isEmpty, "feature off sends nothing")
}

// Signed in and on: the session and entitlements are loaded, then the request goes out with the key.
do {
    FakeServer.reset()
    let access = makeAccess(token: "pix_live_k", featureOn: true)
    let data = try await access.post(path: "/api/agent/text-lead", body: Data(#"{"paragraph":"hi"}"#.utf8))
    check(String(decoding: data, as: UTF8.self) == #"{"ok":true}"#, "returns the response body")
    check(FakeServer.seen.map(\.path) == ["/api/teams", "/api/me/entitlements", "/api/agent/text-lead"],
          "restores session and entitlements, then posts (\(FakeServer.seen.map(\.path)))")
    check(FakeServer.seen.last?.authorization == "Bearer pix_live_k", "sends the key")
    check(FakeServer.seen.last?.method == "POST", "posts")
    check(String(decoding: FakeServer.seen.last?.body ?? Data(), as: UTF8.self) == #"{"paragraph":"hi"}"#, "sends the body unchanged")
}

// The server says the plan needs Pro (402): refused, and nothing more is sent until a refresh.
do {
    FakeServer.reset(textLead: { (402, [:], #"{"error":"AI features are part of Swash Pro.","code":"subscription_required"}"#) })
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

// Without Pro entitlement: refused before anything is sent to the feature.
do {
    FakeServer.reset(
        team: #"{"id":"t1","name":"Personal","ownerId":"u1","planId":"free"}"#,
        entitlements: FakeServer.freeEntitlements
    )
    let access = makeAccess(token: "pix_live_k", featureOn: true)
    check(await refusal(access) == .subscriptionRequired, "Basic is refused")
    check(FakeServer.seen.map(\.path) == ["/api/teams", "/api/me/entitlements"],
          "Basic sends nothing to the feature (\(FakeServer.seen.map(\.path)))")
    check(access.planName == "Basic", "Basic plan name")
}

// A complimentary grant counts as Pro until it expires, including in a direct-download build.
do {
    let clock = Clock()
    clock.now = Date(timeIntervalSince1970: 1_800_000_000)
    let compEntitlements = """
    {"entitlements":["swash_pro"],
     "grants":[{"entitlement":"swash_pro","source":"complimentary","via":"team","teamId":"t1","expiresAt":"2030-01-01T00:00:00.000Z"}]}
    """
    FakeServer.reset(
        team: #"{"id":"t1","name":"Personal","ownerId":"u1","planId":"free","complimentary":{"planId":"pro","expiresAt":"2030-01-01T00:00:00.000Z"}}"#,
        entitlements: compEntitlements
    )
    let access = makeAccess(token: "pix_live_k", distributionMode: .fixed(.direct), featureOn: true, clock: clock)
    check(await refusal(access) == nil, "comped account is served in direct build")
    check(access.planName == "Pro (complimentary)", "comp plan name")
    check(access.store.proSource == .complimentary, "proSource is complimentary")
    clock.now = Date(timeIntervalSince1970: 1_950_000_000)
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

// Sign-in uses Swash's app client and redirect, labels the key with the kind of device only,
// and refreshes store entitlements.
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
    check(access.isSubscribed && access.planName == "Pro", "entitlements loaded after sign-in")
}

// StoreKit purchase in the App Store build unlocks Swash Pro without a Pixerate account.
do {
    FakeServer.reset(entitlements: FakeServer.freeEntitlements)
    let access = makeAccess(
        token: nil,
        distributionMode: .fixed(.appStore),
        storeKit: FakeStoreKitClient(appTransaction: "jws_app_tx"),
        featureOn: true
    )
    await access.start()
    check(access.store.distribution == .appStore && access.store.canPurchase, "App Store distribution can purchase")
    check(!access.isSubscribed, "not subscribed before purchase")
    let bought = await access.store.buy("com.pixerate.swash.pro.monthly")
    check(bought && access.isSubscribed, "buying Swash Pro unlocks isSubscribed without a Pixerate account")
    check(access.store.supportId == "SUP-APPL1", "Support ID set after App Store session")
}

// Direct-download build offers no purchase UI and refuses buy().
do {
    FakeServer.reset(entitlements: FakeServer.freeEntitlements)
    let access = makeAccess(
        token: nil,
        distributionMode: .fixed(.direct),
        storeKit: FakeStoreKitClient(appTransaction: "jws_app_tx"),
        featureOn: true
    )
    await access.start()
    check(access.store.distribution == .direct && !access.store.canPurchase, "direct build cannot purchase")
    check(access.store.products.isEmpty, "direct build loads no StoreKit products")
    let bought = await access.store.buy("com.pixerate.swash.pro.monthly")
    check(!bought && access.store.lastError == .notAppStoreBuild, "direct build refuses purchase")
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

// --demo-auth, --demo-pro, and --demo-unauth launch arguments.
do {
    let access = PixerateAccess.make(arguments: ["Swash", "--demo-auth"])
    await access.refresh()
    check(access.account.isAuthenticated, "demo-auth is signed in")
    check(access.account.teams.count == 2 && access.isSubscribed, "demo-auth has teams and Pro")
    let unauth = PixerateAccess.make(arguments: ["Swash", "--demo-unauth"])
    await unauth.refresh()
    check(!unauth.account.isAuthenticated && unauth.account.token == nil && !unauth.isSubscribed, "demo-unauth is signed out without Pro")
    let pro = PixerateAccess.make(arguments: ["Swash", "--demo-pro"])
    await pro.refresh()
    check(!pro.account.isAuthenticated && pro.isSubscribed, "demo-pro is subscribed without a Pixerate account")
    check(pro.store.supportId == "DEMO-SWSH", "demo-pro has Support ID")
}

print("\(passes) passed, \(failures) failed")
exit(failures == 0 ? 0 : 1)

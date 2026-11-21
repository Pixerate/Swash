//
//  PixerateAccess.swift
//  Swash
//
//  Swash Pro and the optional Pixerate account (#60, #149). Basic features work without an account
//  or subscription. Buying Swash Pro in the App Store (or sharing it through Family Sharing)
//  unlocks the writing partner's server features (#61) with no Pixerate account required; signing
//  in to a Pixerate account is optional and also unlocks Pro for people with Pixerate Pro or a
//  complimentary grant (including in the direct-download Mac build). Every request to the server
//  goes through `PixerateAccess.post`, which refuses before anything is sent unless Pro is
//  unlocked (or being verified) and the feature that asks has been turned on.
//

import Foundation
import Observation
import PixerateAccount
import PixerateStore
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
    /// Neither an App Store customer session nor a signed-in Pixerate account is available.
    case signedOut
    /// The feature that asked is off.
    case featureOff
    /// Swash Pro is not unlocked. Nothing is sent until entitlements are refreshed or Pro is bought.
    case subscriptionRequired
    /// The server asked Swash to wait. Nothing is sent before this time.
    case rateLimited(until: Date)
    /// Any other failure, with the server's message when it gave one.
    case failed(status: Int, message: String?)
}

extension PixerateStore {
    static var shared: PixerateStore { PixerateAccess.shared.store }
}

@MainActor
@Observable
final class PixerateAccess {
    nonisolated static let clientId = "swash"
    nonisolated static let callbackScheme = "swash"
    nonisolated static let proProductIds = [
        "com.pixerate.swash.pro.monthly",
        "com.pixerate.swash.pro.yearly"
    ]
    nonisolated static let termsURL = URL(string: "https://pixerate.com/terms")!
    nonisolated static let privacyURL = URL(string: "https://pixerate.com/privacy")!
    nonisolated static let manageSubscriptionsURL = URL(string: "https://apps.apple.com/account/subscriptions")!
    nonisolated static let manageAccountURL = URL(string: "https://pixerate.com/settings/account")!
    nonisolated static let deleteAccountURL = URL(string: "https://pixerate.com/settings/account/delete")!

    nonisolated static var defaultDistributionMode: PixerateDistributionMode {
        #if APP_STORE || DEBUG
        return .fixed(.appStore)
        #else
        return .automatic
        #endif
    }

    static let shared = PixerateAccess.make()

    let account: PixerateAccountClient
    let store: PixerateStore
    let isPreview: Bool

    /// Whether a feature that uses the server is on. Off until the writing partner (#61) sets it,
    /// so nothing can be sent by default.
    @ObservationIgnored var isFeatureEnabled: () -> Bool = { false }

    /// Set after the server reports the customer or account needs Pro. Cleared by `refresh()` or a
    /// request that succeeds.
    private(set) var needsSubscription = false
    /// Set after the server asks Swash to wait (HTTP 429).
    private(set) var pausedUntil: Date?

    var isSignedOut: Bool {
        account.token == nil || !account.isAuthenticated
    }

    var isRateLimited: Bool {
        guard let pausedUntil else { return false }
        return now() < pausedUntil
    }

    var fuelBalance: Int {
        account.fuelBalance
    }

    @ObservationIgnored private let session: URLSession
    @ObservationIgnored private let now: @Sendable () -> Date
    @ObservationIgnored private var hasLoadedEntitlements = false

    init(
        account: PixerateAccountClient,
        store: PixerateStore? = nil,
        session: URLSession = .shared,
        distributionMode: PixerateDistributionMode = PixerateAccess.defaultDistributionMode,
        storeKit: (any PixerateStoreKitClient)? = nil,
        sessionStore: (any PixerateCustomerSessionStore)? = nil,
        isPreview: Bool = false,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.account = account
        self.session = session
        self.isPreview = isPreview
        self.now = now
        if let store {
            self.store = store
            self.hasLoadedEntitlements = isPreview || store.hasPro || !store.grants.isEmpty
        } else {
            let config = PixerateStoreConfiguration(
                baseURL: account.baseURL,
                productIds: Self.proProductIds,
                appEntitlement: PixerateEntitlement.swashPro,
                bundleIdentifier: Bundle.main.bundleIdentifier ?? "com.pixerate.swash",
                distributionMode: distributionMode
            )
            self.store = PixerateStore(
                configuration: config,
                account: account,
                storeKit: storeKit ?? LiveStoreKitClient(),
                transport: URLSessionTransport(session: session),
                sessionStore: sessionStore,
                now: now
            )
        }
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

    /// The app's instance. Debug builds accept `--demo-auth` (signed in to a fake server),
    /// `--demo-pro` (signed-out App Store customer with Swash Pro), and `--demo-unauth`
    /// (signed out, no Pro).
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
            let customerSession = PixerateCustomerSession(
                token: "appstore_demo_auth",
                expiresAt: nil,
                customer: PixerateAppStoreCustomer(id: "cust_demo", supportId: "DEMO-SWSH", linkedUserId: "user_demo")
            )
            return PixerateAccess(
                account: account,
                session: session,
                distributionMode: .fixed(.appStore),
                storeKit: DemoStoreKitClient(),
                sessionStore: InMemoryCustomerSessionStore(customerSession)
            )
        } else if arguments.contains("--demo-pro") {
            let config = URLSessionConfiguration.ephemeral
            config.protocolClasses = [DemoPixerateURLProtocol.self]
            let session = URLSession(configuration: config)
            let account = PixerateAccountClient(
                baseURL: PixerateDefaults.defaultBaseURL,
                tokenStore: InMemoryTokenStore(),
                session: session
            )
            let customerSession = PixerateCustomerSession(
                token: "appstore_demo_pro",
                expiresAt: nil,
                customer: PixerateAppStoreCustomer(id: "cust_demo_pro", supportId: "DEMO-SWSH")
            )
            let storeConfig = PixerateStoreConfiguration(
                baseURL: PixerateDefaults.defaultBaseURL,
                productIds: proProductIds,
                appEntitlement: PixerateEntitlement.swashPro,
                bundleIdentifier: "com.pixerate.swash.demo-pro",
                distributionMode: .fixed(.appStore)
            )
            let store = PixerateStore(
                configuration: storeConfig,
                account: account,
                storeKit: DemoStoreKitClient(hasActiveSubscription: true),
                transport: URLSessionTransport(session: session),
                sessionStore: InMemoryCustomerSessionStore(customerSession)
            )
            let access = PixerateAccess(
                account: account,
                store: store,
                session: session,
                distributionMode: .fixed(.appStore)
            )
            Task { await access.refresh() }
            return access
        } else if arguments.contains("--demo-unauth") {
            let account = PixerateAccountClient(
                baseURL: PixerateDefaults.defaultBaseURL,
                tokenStore: InMemoryTokenStore()
            )
            return PixerateAccess(
                account: account,
                distributionMode: .fixed(.appStore),
                storeKit: DemoStoreKitClient(),
                sessionStore: InMemoryCustomerSessionStore()
            )
        }
        #endif
        let url = baseURL()
        return PixerateAccess(account: PixerateAccountClient(baseURL: url))
    }

    // MARK: Launch & Account

    /// Restores any saved Pixerate account session, starts `PixerateStore` (resolving distribution,
    /// minting the App Store customer session, loading StoreKit products, and fetching entitlements).
    func start() async {
        guard !isPreview else { return }
        if account.token != nil {
            await account.restoreSession()
        }
        resetRefusals()
        await store.start()
        hasLoadedEntitlements = true
    }

    /// Starts the shared store and refreshes entitlements at app launch.
    static func startAtLaunch() {
        Task { @MainActor in
            await shared.start()
        }
    }

    /// Shows Pixerate's sign-in sheet. Cancelling sets no error.
    func signIn(presenter: (any PixerateWebAuthPresenter)? = nil) async {
        guard !isPreview else { return }
        await account.signInWithApp(
            clientId: Self.clientId,
            callbackScheme: Self.callbackScheme,
            deviceName: Self.deviceName,
            presenter: presenter
        )
        if account.isAuthenticated {
            resetRefusals()
            await store.accountDidChange()
            hasLoadedEntitlements = true
        }
    }

    /// Reloads the person and their teams (if signed in) and refreshes entitlements.
    /// When neither an account token nor an App Store customer session is stored, it sends nothing.
    func refresh() async {
        guard !isPreview else { return }
        if account.token != nil {
            await account.restoreSession()
        }
        resetRefusals()
        await store.refreshEntitlements()
        hasLoadedEntitlements = true
    }

    func signOut() {
        account.signOut()
        resetRefusals()
        guard !isPreview else { return }
        Task {
            await store.accountDidChange()
        }
    }

    func selectTeam(_ teamId: String) {
        account.selectTeam(teamId)
        resetRefusals()
        guard !isPreview else { return }
        Task {
            await store.accountDidChange()
        }
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
        needsSubscription = false
        pausedUntil = nil
    }

    // MARK: Plan & Entitlements

    /// Plans that never count as Pixerate Pro.
    nonisolated static let freePlanIds: Set<String> = ["free", ""]

    /// Where a team's plan comes from: `.billing` (paid plan), `.complimentary` (granted by Pixerate),
    /// or `nil` on the Basic plan or without a team.
    nonisolated enum PlanSource: Equatable { case billing, complimentary }

    nonisolated static func planSource(of team: Team?, at date: Date = Date()) -> PlanSource? {
        guard let team else { return nil }
        if !freePlanIds.contains(team.planId) { return .billing }
        if let grant = team.complimentary, !freePlanIds.contains(grant.planId), grant.isActive(at: date) {
            return .complimentary
        }
        return nil
    }

    private var hasActiveStoreGrant: Bool {
        guard store.hasPro else { return false }
        let current = now()
        let relevant = store.grants.filter {
            $0.entitlement == PixerateEntitlement.swashPro || $0.entitlement == PixerateEntitlement.pixeratePro
        }
        if !relevant.isEmpty, relevant.allSatisfy({ $0.expiresAt != nil && $0.expiresAt! <= current }) {
            return false
        }
        if let team = account.activeTeam,
           store.grants.isEmpty,
           team.complimentary != nil,
           Self.planSource(of: team, at: current) == nil {
            return false
        }
        return true
    }

    /// Whether Swash Pro is unlocked (via the App Store, Family Sharing, Pixerate Pro, or a
    /// complimentary grant).
    var isSubscribed: Bool {
        hasActiveStoreGrant && !needsSubscription
    }

    /// "Pro", "Pro (complimentary)" or "Basic".
    var planName: String {
        if isSubscribed {
            if store.proSource == .complimentary || Self.planSource(of: account.activeTeam, at: now()) == .complimentary {
                return "Pro (complimentary)"
            }
            return "Pro"
        }
        return "Basic"
    }

    // MARK: Requests

    /// POSTs `body` (JSON) to `path` on the Pixerate server carrying the App Store customer header
    /// (when available) and the Pixerate account bearer key (when signed in), and returns the
    /// response body. Throws `PixerateRefusal`, without sending anything to `path`, when
    /// unauthenticated, when the feature is off, without Swash Pro, or while rate-limited.
    /// `timeout` caps how long the request may take (default: the session's). The writing partner's
    /// pause tier passes a short one so a dropped connection falls back to the on-device partner
    /// at once rather than after a minute (#109).
    func post(path: String, body: Data, timeout: TimeInterval? = nil) async throws -> Data {
        guard isFeatureEnabled() else { throw PixerateRefusal.featureOff }
        guard (try? store.authorizedRequest(path: path, method: "POST", body: body)) != nil else {
            throw PixerateRefusal.signedOut
        }
        if account.token != nil && !account.isAuthenticated {
            await account.restoreSession()
            if !account.isAuthenticated && store.customer == nil {
                throw PixerateRefusal.signedOut
            }
        }
        if !hasLoadedEntitlements {
            await store.refreshEntitlements()
            hasLoadedEntitlements = true
        }
        if !isSubscribed { throw PixerateRefusal.subscriptionRequired }
        if let pausedUntil {
            if now() < pausedUntil { throw PixerateRefusal.rateLimited(until: pausedUntil) }
            self.pausedUntil = nil
        }

        var request: URLRequest
        do {
            request = try store.authorizedRequest(path: path, method: "POST", body: body)
        } catch {
            throw PixerateRefusal.signedOut
        }
        if let timeout { request.timeoutInterval = timeout }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw PixerateRefusal.failed(status: 0, message: nil)
        }
        switch http.statusCode {
        case 200..<300:
            needsSubscription = false
            return data
        case 401:
            // The key or customer session was rejected: sign out any stored account key.
            account.signOut()
            hasLoadedEntitlements = false
            await store.accountDidChange()
            throw PixerateRefusal.signedOut
        case 402:
            // `subscription_required`: the server's view of the entitlement wins until the next refresh.
            needsSubscription = true
            throw PixerateRefusal.subscriptionRequired
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

    // MARK: Previews

    /// Creates a preview `PixerateAccess` and `PixerateStore` that never touch StoreKit or the network.
    static func preview(
        distribution: PixerateDistribution = .appStore,
        products: [PixerateStoreProduct] = previewProducts,
        entitlements: PixerateEntitlements = PixerateEntitlements(supportId: "SWSH-4X9Q"),
        signedIn: Bool = false
    ) -> PixerateAccess {
        let account = PixerateAccountClient(
            baseURL: PixerateDefaults.defaultBaseURL,
            tokenStore: InMemoryTokenStore(
                token: signedIn ? "pix_live_preview" : nil,
                selectedTeamId: signedIn ? "team_preview" : nil
            )
        )
        let config = PixerateStoreConfiguration(
            baseURL: PixerateDefaults.defaultBaseURL,
            productIds: proProductIds,
            appEntitlement: PixerateEntitlement.swashPro,
            bundleIdentifier: "com.pixerate.swash.preview",
            distributionMode: .fixed(distribution)
        )
        let store = PixerateStore.preview(
            configuration: config,
            distribution: distribution,
            products: distribution == .appStore ? products : [],
            entitlements: entitlements
        )
        return PixerateAccess(
            account: account,
            store: store,
            distributionMode: .fixed(distribution),
            isPreview: true
        )
    }

    nonisolated static let previewProducts: [PixerateStoreProduct] = [
        PixerateStoreProduct(
            id: "com.pixerate.swash.pro.monthly",
            displayName: "Swash Pro Monthly",
            description: "Writing partner suggestions on pause, billed monthly",
            displayPrice: "$3.99",
            price: 3.99,
            periodDescription: "month",
            isFamilyShareable: true
        ),
        PixerateStoreProduct(
            id: "com.pixerate.swash.pro.yearly",
            displayName: "Swash Pro Yearly",
            description: "Writing partner suggestions on pause, billed yearly",
            displayPrice: "$29.99",
            price: 29.99,
            periodDescription: "year",
            isFamilyShareable: true
        )
    ]
}

#if DEBUG
/// Stubbed StoreKit client used by `--demo-auth`, `--demo-pro`, and `--demo-unauth`.
private struct DemoStoreKitClient: PixerateStoreKitClient {
    var hasActiveSubscription = false

    func appTransactionJWS() async -> String? { "jws_demo_app_transaction" }

    func products(for ids: [String]) async throws -> [PixerateStoreProduct] {
        PixerateAccess.previewProducts.filter { ids.contains($0.id) }
    }

    func purchase(productId: String) async throws -> PixeratePurchaseOutcome {
        .purchased(
            PixerateStoreTransaction(
                id: 1,
                originalId: 1,
                productId: productId,
                jwsRepresentation: "jws_demo_purchase_\(productId)"
            )
        )
    }

    func sync() async throws {}

    func currentEntitlements() async -> [PixerateStoreTransaction] {
        guard hasActiveSubscription else { return [] }
        return [
            PixerateStoreTransaction(
                id: 1,
                originalId: 1,
                productId: "com.pixerate.swash.pro.monthly",
                jwsRepresentation: "jws_demo_active"
            )
        ]
    }

    func unfinishedTransactions() async -> [PixerateStoreTransaction] { [] }

    func transactionUpdates() -> AsyncStream<PixerateStoreTransaction> {
        AsyncStream { $0.finish() }
    }
}

/// The fake server behind `--demo-auth` and `--demo-pro`.
final class DemoPixerateURLProtocol: URLProtocol {
    override nonisolated class func canInit(with request: URLRequest) -> Bool { true }
    override nonisolated class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override nonisolated func stopLoading() {}

    override nonisolated func startLoading() {
        let url = request.url ?? PixerateDefaults.defaultBaseURL
        let authHeader = request.value(forHTTPHeaderField: "Authorization")
        let customerHeader = request.value(forHTTPHeaderField: "X-Pixerate-App-Store-Customer")
        let (status, body): (Int, String)
        switch url.path {
        case "/api/teams":
            status = 200
            body = """
            {"user":{"id":"user_demo","email":"writer@example.com","displayName":"Demo Writer"},
             "defaultTeamId":"team_demo",
             "teams":[{"id":"team_demo","name":"Personal","ownerId":"user_demo","planId":"pro"},
                      {"id":"team_studio","name":"Studio","ownerId":"user_other","planId":"free"}]}
            """
        case "/api/auth/app-store":
            status = 200
            body = """
            {"token":"appstore_demo_pro","customer":{"id":"cust_demo_pro","supportId":"DEMO-SWSH"}}
            """
        case "/api/me/entitlements":
            status = 200
            if authHeader != nil {
                body = """
                {"entitlements":["pixerate_pro","swash_pro"],
                 "grants":[{"entitlement":"pixerate_pro","source":"plan","via":"team","teamId":"team_demo"}],
                 "supportId":"DEMO-SWSH",
                 "customer":{"id":"cust_demo","supportId":"DEMO-SWSH","linkedUserId":"user_demo"},
                 "user":{"id":"user_demo","email":"writer@example.com"}}
                """
            } else if customerHeader == "appstore_demo_pro" {
                body = """
                {"entitlements":["swash_pro"],
                 "grants":[{"entitlement":"swash_pro","source":"app_store","via":"customer","productId":"com.pixerate.swash.pro.monthly","ownership":"PURCHASED"}],
                 "supportId":"DEMO-SWSH",
                 "customer":{"id":"cust_demo_pro","supportId":"DEMO-SWSH"}}
                """
            } else {
                body = """
                {"entitlements":[],"grants":[],"supportId":"DEMO-SWSH","customer":{"id":"cust_demo","supportId":"DEMO-SWSH"}}
                """
            }
        case "/api/billing/apple/verify":
            status = 200
            body = """
            {"entitlements":["swash_pro"],
             "grants":[{"entitlement":"swash_pro","source":"app_store","via":"customer","productId":"com.pixerate.swash.pro.monthly","ownership":"PURCHASED"}],
             "supportId":"DEMO-SWSH",
             "customer":{"id":"cust_demo_pro","supportId":"DEMO-SWSH"}}
            """
        case "/api/app-store/link":
            status = 200
            body = """
            {"customer":{"id":"cust_demo_pro","supportId":"DEMO-SWSH","linkedUserId":"user_demo"}}
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

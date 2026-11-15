//
//  PixerateStore.swift
//  Swash
//
//  Buying Pixerate Pro in Swash through the App Store (StoreKit 2). Apple handles payment,
//  renewal and cancellation. Each purchase is sent to the Pixerate server
//  (`POST /api/billing/apple/verify`), which checks Apple's signature and puts the team on Pro,
//  and is finished only after the server accepts it. App Store Server Notifications keep the plan
//  current after that. Purchases are tied to a team, so they need a Pixerate account.
//

import CryptoKit
import Foundation
import Observation
import PixerateAccount
import StoreKit

/// The `appAccountToken` StoreKit attaches to a purchase: an RFC 4122 v5 UUID of `"team:<id>"`,
/// the same one the Pixerate server derives (`deriveAppAccountToken` in `@pixerate/teams`), so
/// the server can tell which team a purchase was for.
nonisolated enum PixerateAccountToken {
    static let namespace = UUID(uuidString: "9f8e7d6c-5b4a-4321-8765-fedcba098765")!

    static func uuid(teamId: String) -> UUID {
        let ns = withUnsafeBytes(of: namespace.uuid) { Array($0) }
        var hasher = Insecure.SHA1()
        hasher.update(data: ns)
        hasher.update(data: Array("team:\(teamId)".utf8))
        var digest = Array(hasher.finalize())
        digest[6] = (digest[6] & 0x0F) | 0x50 // version 5
        digest[8] = (digest[8] & 0x3F) | 0x80 // RFC 4122 variant
        return digest.withUnsafeBytes { UUID(uuid: $0.loadUnaligned(as: uuid_t.self)) }
    }
}

@MainActor
@Observable
final class PixerateStore {
    /// Pixerate Pro's App Store products. They must exist in App Store Connect, and the server's
    /// `APP_STORE_PRODUCT_PLANS` must map each one to the `pro` plan.
    nonisolated static let proProductIds = [
        "com.pixerate.swash.pro.monthly",
        "com.pixerate.swash.pro.yearly"
    ]
    nonisolated static let verifyPath = "/api/billing/apple/verify"
    nonisolated static let manageSubscriptionsURL = URL(string: "https://apps.apple.com/account/subscriptions")!

    static let shared = PixerateStore(access: .shared)

    let access: PixerateAccess

    /// Products to offer, cheapest first. Empty until `start()` has loaded them.
    private(set) var products: [Product] = []
    private(set) var isBusy = false
    /// A short message after a purchase or restore, for Settings.
    private(set) var message: String?

    @ObservationIgnored private var updates: Task<Void, Never>?
    @ObservationIgnored private let session: URLSession

    init(access: PixerateAccess, session: URLSession = .shared) {
        self.access = access
        self.session = session
    }

    /// Listens for renewals, Ask to Buy approvals and purchases finished elsewhere, sends any
    /// unfinished ones to the server, and loads the products. Safe to call often.
    func start() async {
        if updates == nil {
            updates = Task { [weak self] in
                for await result in Transaction.updates {
                    await self?.handle(result)
                }
            }
            for await result in Transaction.unfinished {
                await handle(result)
            }
        }
        if products.isEmpty {
            isBusy = true
            defer { isBusy = false }
            products = ((try? await Product.products(for: Self.proProductIds)) ?? []).sorted { $0.price < $1.price }
        }
    }

    /// At launch: when signed in, picks up renewals, refunds and purchases finished while Swash
    /// was closed. Signed out, it does nothing (no request is sent).
    static func startIfSignedIn() {
        Task { @MainActor in
            await PixerateAccess.shared.refresh()
            guard PixerateAccess.shared.account.isAuthenticated else { return }
            await shared.start()
        }
    }

    func buy(_ product: Product) async {
        message = nil
        guard let team = access.account.activeTeam else {
            message = "Sign in to Pixerate to buy Pro."
            return
        }
        isBusy = true
        defer { isBusy = false }
        do {
            let result = try await product.purchase(options: [.appAccountToken(PixerateAccountToken.uuid(teamId: team.id))])
            switch result {
            case .success(let verification):
                if await handle(verification) {
                    message = "Welcome to Pixerate Pro."
                }
            case .pending:
                message = "Your purchase is waiting for approval."
            case .userCancelled:
                break
            @unknown default:
                break
            }
        } catch {
            message = error.localizedDescription
        }
    }

    func restore() async {
        message = nil
        isBusy = true
        defer { isBusy = false }
        do {
            try await AppStore.sync()
            var restored = false
            for await result in Transaction.currentEntitlements {
                if await handle(result, finish: false) { restored = true }
            }
            message = restored ? "Purchases restored." : "No Pixerate Pro purchase to restore."
        } catch {
            message = error.localizedDescription
        }
    }

    // MARK: Server

    /// Sends a verified Pro transaction to the server for the team it was bought for, then
    /// finishes it. Returns whether the server accepted it.
    @discardableResult
    private func handle(_ result: VerificationResult<Transaction>, finish: Bool = true) async -> Bool {
        guard case .verified(let transaction) = result,
              Self.proProductIds.contains(transaction.productID),
              let teamId = teamId(for: transaction) else { return false }
        let body: [String: Any] = [
            "target": ["type": "team", "id": teamId],
            "signedTransactionInfo": result.jwsRepresentation
        ]
        do {
            let request = try access.account.authorizedRequest(
                path: Self.verifyPath,
                method: "POST",
                body: JSONSerialization.data(withJSONObject: body)
            )
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                let error = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error"] as? String
                message = error ?? "Pixerate couldn't confirm the purchase. It will try again."
                return false
            }
        } catch {
            message = "Pixerate couldn't confirm the purchase. It will try again."
            return false
        }
        // Finish only after the server has recorded it, so StoreKit redelivers it otherwise.
        if finish { await transaction.finish() }
        await access.refresh()
        return true
    }

    /// The team a transaction was bought for: the signed-in team whose token it carries, else
    /// the active team (purchases made outside the app carry no token).
    private func teamId(for transaction: Transaction) -> String? {
        guard access.account.isAuthenticated else { return nil }
        if let token = transaction.appAccountToken,
           let team = access.account.teams.first(where: { PixerateAccountToken.uuid(teamId: $0.id) == token }) {
            return team.id
        }
        return access.account.activeTeam?.id
    }
}

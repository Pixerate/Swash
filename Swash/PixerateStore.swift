//
//  PixerateStore.swift
//  Swash
//
//  Buying Pixerate Pro in Swash through the App Store. StoreKit handles payment, renewal and
//  cancellation; the Pixerate server verifies each purchase (`/api/billing/apple/verify`) and puts
//  the signed-in person's team on Pro, and App Store Server Notifications keep it current.
//  Purchases are tied to the active team, so they need a Pixerate account.
//

import Foundation
import Observation
import PixerateTeams

@MainActor
@Observable
final class PixerateStore {
    /// Pixerate Pro's App Store products. They must exist in App Store Connect, and the server's
    /// `APP_STORE_PRODUCT_PLANS` must map each one to the `pro` plan.
    nonisolated static let proProductIds = [
        "com.pixerate.swash.pro.monthly",
        "com.pixerate.swash.pro.yearly"
    ]
    nonisolated static let proPlanId = "pro"

    static let shared = PixerateStore(access: .shared)

    let access: PixerateAccess
    let billing: AppStoreBillingClient

    /// A short message after a purchase or restore, for Settings.
    private(set) var message: String?

    private var started = false

    init(access: PixerateAccess) {
        self.access = access
        self.billing = AppStoreBillingClient(
            teamsClient: access.account,
            descriptors: Self.proProductIds.map {
                .subscription(productId: $0, planId: Self.proPlanId)
            }
        )
    }

    /// Products to offer, cheapest first. Empty until `start()` has loaded them.
    var products: [AppStoreProductItem] {
        billing.subscriptionProducts.sorted { $0.price < $1.price }
    }

    var isBusy: Bool { billing.isPurchasing || billing.isRestoring || billing.isLoadingProducts }

    /// Loads products and listens for renewals and purchases finished elsewhere. Safe to call often.
    func start() async {
        if !started {
            started = true
            billing.startTransactionListener()
        }
        if billing.products.isEmpty {
            await billing.loadProducts()
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

    func buy(_ product: AppStoreProductItem) async {
        message = nil
        do {
            switch try await billing.purchase(productId: product.id) {
            case .purchased:
                await access.refresh()
                message = "Welcome to Pixerate Pro."
            case .pending:
                message = "Your purchase is waiting for approval."
            case .userCancelled:
                break
            }
        } catch {
            message = billing.error ?? error.localizedDescription
        }
    }

    func restore() async {
        message = nil
        do {
            let restored = try await billing.restorePurchases()
            await access.refresh()
            message = restored.isEmpty ? "No Pixerate Pro purchase to restore." : "Purchases restored."
        } catch {
            message = billing.error ?? error.localizedDescription
        }
    }

    func manageSubscription() async {
        await billing.openManageSubscriptions()
    }
}

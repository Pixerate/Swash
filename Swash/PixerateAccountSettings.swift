//
//  PixerateAccountSettings.swift
//  Swash
//
//  The Swash Pro, Support ID, and optional Pixerate account sections of Settings, shared by the
//  Mac's Account tab and the iOS Settings sheet (#60, #149).
//

import SwiftUI
import PixerateAccount
import PixerateStore
import StoreKit
#if canImport(UIKit)
import UIKit
#endif

struct PixerateAccountSections: View {
    var access: PixerateAccess = .shared
    var store: PixerateStore?
    /// Preview override for displaying the signed-in state without a live token exchange.
    var previewSignedInUser: AuthUser?
    var previewSignedInTeams: [Team] = []

    @Environment(\.openURL) private var openURL
    @State private var showMovePurchaseAlert = false
    @State private var linkError: String?

    private var activeStore: PixerateStore { store ?? access.store }
    private var account: PixerateAccountClient { access.account }
    private var isSignedIn: Bool { account.isAuthenticated || previewSignedInUser != nil }
    private var displayedUser: AuthUser? { account.user ?? previewSignedInUser }
    private var displayedTeams: [Team] { account.teams.isEmpty ? previewSignedInTeams : account.teams }

    var body: some View {
        Group {
            swashProSection
            if activeStore.supportId != nil {
                Section("Support") {
                    PixerateSupportIDRow(supportId: activeStore.supportId)
                }
            }
            pixerateAccountSection
            privacySection
        }
        .onAppear {
            activeStore.lastError = nil
            linkError = nil
        }
        .onChange(of: activeStore.lastError) { _, newError in
            if newError?.isCancellation == true {
                activeStore.lastError = nil
            }
        }
    }

    // MARK: - Swash Pro Section

    @ViewBuilder private var swashProSection: some View {
        Section {
            if let source = activeStore.proSource {
                LabeledContent("Status") {
                    Text(Self.statusText(for: source))
                        .foregroundStyle(Color.accentColor)
                }
                if source == .complimentary, let expiresAt = complimentaryExpiresAt {
                    Text("Pixerate has given you Pro until \(expiresAt, style: .date).")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                if case .appStore = source {
                    Button("Manage Subscription…") {
                        manageSubscriptions()
                    }
                }
                if activeStore.canPurchase {
                    Button("Restore Purchases") {
                        Task { await activeStore.restore() }
                    }
                    .disabled(activeStore.isPurchasing)
                }
                if let error = displayedStoreError {
                    Text(error)
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
            } else if activeStore.distribution == .appStore {
                PixerateProPaywall(
                    store: activeStore,
                    title: "Swash Pro",
                    features: proFeatures,
                    termsURL: PixerateAccess.termsURL,
                    privacyURL: PixerateAccess.privacyURL,
                    directMessage: "Sign in to use Pixerate Pro or a complimentary subscription."
                )
            } else {
                Text("Sign in to use Pixerate Pro or a complimentary subscription.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                if let error = displayedStoreError {
                    Text(error)
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
            }
            if let until = access.pausedUntil, until > .now {
                Text("Pixerate asked Swash to wait. The writing partner resumes \(until, style: .relative).")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Swash Pro")
        }
    }

    static func statusText(for source: PixerateProSource) -> String {
        switch source {
        case .appStore(familyShared: false):
            return "Swash Pro"
        case .appStore(familyShared: true):
            return "Swash Pro, shared by your family"
        case .pixeratePro:
            return "Included with Pixerate Pro"
        case .complimentary:
            return "Complimentary"
        case .plan, .offline:
            return "Swash Pro"
        }
    }

    private var complimentaryExpiresAt: Date? {
        if let grantExpiry = activeStore.grants.first(where: \.isComplimentary)?.expiresAt {
            return grantExpiry
        }
        return account.activeTeam?.complimentary?.expiresAtDate
    }

    private func manageSubscriptions() {
        #if os(iOS)
        Task {
            if let scene = UIApplication.shared.connectedScenes
                .compactMap({ $0 as? UIWindowScene })
                .first(where: { $0.activationState == .foregroundActive })
                ?? UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first {
                do {
                    try await AppStore.showManageSubscriptions(in: scene)
                    return
                } catch {
                    openURL(PixerateAccess.manageSubscriptionsURL)
                }
            } else {
                openURL(PixerateAccess.manageSubscriptionsURL)
            }
        }
        #else
        openURL(PixerateAccess.manageSubscriptionsURL)
        #endif
    }

    // MARK: - Pixerate Account Section

    @ViewBuilder private var pixerateAccountSection: some View {
        Section {
            if isSignedIn {
                signedIn
            } else {
                signedOut
            }
            if let error = displayedAccountError {
                Text(error)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            }
        } header: {
            Text("Pixerate Account")
        } footer: {
            if isSignedIn {
                Text("Optional: sign in or create a free Pixerate account to manage your subscription on the web. Deleting your Pixerate account doesn't cancel an App Store subscription.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                Text("Optional: sign in or create a free Pixerate account to manage your subscription on the web.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .alert(
            "This App Store purchase is linked to another Pixerate account. Move it to this account?",
            isPresented: $showMovePurchaseAlert
        ) {
            Button("Move to This Account") {
                Task { await confirmMoveLink() }
            }
            Button("Cancel", role: .cancel) {}
        }
    }

    @ViewBuilder private var signedOut: some View {
        if account.isAuthenticating {
            HStack {
                ProgressView().controlSize(.small)
                Text("Waiting for Pixerate…")
                Spacer()
                Button("Cancel") { account.cancelSignIn() }
            }
        } else {
            HStack {
                Text("Not signed in")
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Sign In with Pixerate…") {
                    Task { await signInAndLink() }
                }
            }
        }
    }

    @ViewBuilder private var signedIn: some View {
        LabeledContent("Signed in as") {
            Text(displayedUser?.displayName ?? displayedUser?.email ?? "Pixerate account")
                .textSelection(.enabled)
        }
        if displayedTeams.count > 1 {
            Picker("Team", selection: Binding(
                get: { account.activeTeam?.id ?? displayedTeams.first?.id ?? "" },
                set: { access.selectTeam($0) }
            )) {
                ForEach(displayedTeams) { team in
                    Text(team.name).tag(team.id)
                }
            }
        } else if let team = account.activeTeam ?? displayedTeams.first {
            LabeledContent("Team", value: team.name)
        }
        HStack {
            Button("Manage account") {
                openURL(PixerateAccess.manageAccountURL)
            }
            Button("Delete account…") {
                openURL(PixerateAccess.deleteAccountURL)
            }
            Spacer()
            Button("Sign Out", role: .destructive) {
                linkError = nil
                access.signOut()
            }
        }
    }

    private func signInAndLink() async {
        linkError = nil
        await access.signIn()
        guard account.isAuthenticated, activeStore.distribution == .appStore else { return }
        do {
            try await activeStore.link()
        } catch PixerateStoreError.linkedElsewhere {
            showMovePurchaseAlert = true
        } catch PixerateStoreError.unauthenticated {
            // No App Store customer session to link yet; ignore quietly.
        } catch is CancellationError {
            // Ignore cancellation
        } catch let urlError as URLError where urlError.code == .cancelled {
            // Ignore cancellation
        } catch {
            linkError = error.localizedDescription
        }
    }

    private func confirmMoveLink() async {
        linkError = nil
        do {
            try await activeStore.link(confirmMove: true)
        } catch is CancellationError {
            // Ignore cancellation
        } catch let urlError as URLError where urlError.code == .cancelled {
            // Ignore cancellation
        } catch {
            linkError = error.localizedDescription
        }
    }

    // MARK: - Privacy Section

    @ViewBuilder private var privacySection: some View {
        Section {
            Label("None of your writing is sent unless you have Swash Pro and the writing partner is on.", systemImage: "lock")
            Label("Swash sends only the paragraph you're writing and a little context around it, never the whole document, and never code blocks, math or tables.", systemImage: "text.alignleft")
            Label("Pixerate doesn't keep your text. It learns only which suggestions you kept or undid.", systemImage: "hand.raised")
            Label("The writing partner is part of Swash Pro. Everything else in Swash is free.", systemImage: "sparkles")
        } header: {
            Text("Privacy")
        }
        .font(.callout)
    }

    private var displayedStoreError: String? {
        guard let error = activeStore.lastError, !error.isCancellation else { return nil }
        return error.errorDescription
    }

    private var displayedAccountError: String? {
        if let linkError, !PixerateAccess.isCancellationMessage(linkError) {
            return linkError
        }
        if let error = account.error, !PixerateAccess.isCancellationMessage(error) {
            return error
        }
        return nil
    }

    private var proFeatures: [String] {
        Self.proFeatures()
    }

    /// The writing partner's pause tier runs on iPhone and iPad too (#109); Quick Note is Mac-only.
    static func proFeatures() -> [String] {
        #if os(iOS)
        return [
            "Paragraph structure and grammar suggestions when you pause",
            "Personal vocabulary and house style across devices",
            "Quick Note tidy-up on pause or save, on the Mac"
        ]
        #else
        return [
            "Paragraph structure and grammar suggestions when you pause",
            "Quick Note tidy-up on pause or save",
            "Personal vocabulary and house style across devices"
        ]
        #endif
    }
}

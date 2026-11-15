//
//  PixerateAccountSettings.swift
//  Swash
//
//  The Pixerate account sections of Settings, shared by the Mac's Account tab and the iOS
//  Settings sheet (#60).
//

import SwiftUI
import PixerateAccount
import PixerateTeams

struct PixerateAccountSections: View {
    var access: PixerateAccess = .shared
    var store: PixerateStore = .shared
    @Environment(\.openURL) private var openURL

    private var account: PixerateAccountClient { access.account }

    var body: some View {
        Section {
            if account.isAuthenticated {
                signedIn
            } else {
                signedOut
            }
            if let error = account.error {
                Text(error)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            }
        } header: {
            Text("Pixerate Account")
        } footer: {
            Text("Swash works fully without an account. With Pixerate Pro, the writing partner uses Pixerate's model when you pause.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }

        Section {
            Label("None of your writing is sent unless you're signed in to Pixerate Pro and the writing partner is on.", systemImage: "lock")
            Label("Swash sends only the paragraph you're writing and a little context around it, never the whole document, and never code blocks, math or tables.", systemImage: "text.alignleft")
            Label("Pixerate doesn't keep your text. It learns only which suggestions you kept or undid.", systemImage: "hand.raised")
            Label("The writing partner is part of Pixerate Pro. Everything else in Swash is free.", systemImage: "sparkles")
        } header: {
            Text("Privacy")
        }
        .font(.callout)
        .task {
            await access.refresh()
            if account.isAuthenticated { await store.start() }
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
                    Task { await access.signIn() }
                }
            }
        }
    }

    @ViewBuilder private var signedIn: some View {
        LabeledContent("Signed in as") {
            Text(account.user?.displayName ?? account.user?.email ?? "Pixerate account")
                .textSelection(.enabled)
        }
        if account.teams.count > 1 {
            Picker("Team", selection: Binding(
                get: { account.activeTeam?.id ?? "" },
                set: { account.selectTeam($0) }
            )) {
                ForEach(account.teams) { team in
                    Text(team.name).tag(team.id)
                }
            }
        } else if let team = account.activeTeam {
            LabeledContent("Team", value: team.name)
        }
        LabeledContent("Plan") {
            Text(access.planName)
                .foregroundStyle(access.isSubscribed ? Color.accentColor : Color.secondary)
        }
        if let grant = account.activeTeam?.complimentary, PixerateAccess.planSource(of: account.activeTeam) == .complimentary {
            if let end = grant.expiresAtDate {
                Text("Pixerate has given you Pro until \(end, style: .date).")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        } else if access.isSubscribed {
            Button("Manage Subscription…") { Task { await store.manageSubscription() } }
        } else {
            Text("You're on the Basic plan: everything in Swash except the writing partner. Pixerate Pro adds it.")
                .font(.footnote)
                .foregroundStyle(.secondary)
            upgrade
        }
        if let message = store.message {
            Text(message)
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        if let until = access.pausedUntil, until > .now {
            Text("Pixerate asked Swash to wait. The writing partner resumes \(until, style: .relative).")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        HStack {
            Button("Open pixerate.com") { openURL(account.baseURL) }
            Spacer()
            Button("Sign Out", role: .destructive) { access.signOut() }
        }
    }

    @ViewBuilder private var upgrade: some View {
        if store.products.isEmpty {
            if store.isBusy {
                ProgressView().controlSize(.small)
            } else {
                Text("Pixerate Pro isn't available from the App Store right now.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        } else {
            ForEach(store.products) { product in
                Button("Upgrade to Pro: \(product.displayPrice) \(Self.period(of: product))") {
                    Task { await store.buy(product) }
                }
                .disabled(store.isBusy)
            }
        }
        Button("Restore Purchases") { Task { await store.restore() } }
            .disabled(store.isBusy)
    }

    private static func period(of product: AppStoreProductItem) -> String {
        if product.id.hasSuffix(".yearly") { return "a year" }
        if product.id.hasSuffix(".monthly") { return "a month" }
        return ""
    }
}

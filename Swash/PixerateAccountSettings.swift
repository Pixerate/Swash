//
//  PixerateAccountSettings.swift
//  Swash
//
//  The Pixerate account sections of Settings, shared by the Mac's Account tab and the iOS
//  Settings sheet (#60).
//

import SwiftUI
import PixerateAccount

struct PixerateAccountSections: View {
    var access: PixerateAccess = .shared
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
            Text("Swash works fully without an account. Signing in lets the writing partner use Pixerate's model when you pause.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }

        Section {
            Label("Nothing is sent unless you're signed in and the writing partner is on.", systemImage: "lock")
            Label("Swash sends only the paragraph you're writing and a little context around it, never the whole document, and never code blocks, math or tables.", systemImage: "text.alignleft")
            Label("Pixerate doesn't keep your text. It learns only which suggestions you kept or undid.", systemImage: "hand.raised")
            Label("Each writing-partner request uses Fuel from your Pixerate team.", systemImage: "fuelpump")
        } header: {
            Text("Privacy")
        }
        .font(.callout)
        .task { await access.refresh() }
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
        LabeledContent("Fuel") {
            Text(account.fuelBalance, format: .number)
                .monospacedDigit()
                .foregroundStyle(account.fuelBalance > 0 ? Color.primary : Color.red)
        }
        if access.isOutOfFuel || account.fuelBalance <= 0 {
            Text("This team is out of Fuel, so the writing partner works on this device only. Add Fuel on pixerate.com.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        } else if let until = access.pausedUntil, until > .now {
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
}

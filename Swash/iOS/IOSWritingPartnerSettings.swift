//
//  IOSWritingPartnerSettings.swift
//  Swash
//
//  Settings › Writing Partner on iPhone and iPad (#109, #229): the same five sections as the Mac's
//  Settings › Writing, worded for touch (undo instead of ⌘Z, the edit menu instead of Tab).
//

#if os(iOS)
import SwiftUI

struct IOSWritingPartnerSettings: View {
    @AppStorage(WritingPartnerDefaults.mode) private var mode: WritingPartnerMode = .copyedit
    @AppStorage("markdownFlavor") private var defaultFlavor: MarkdownFlavor = .github
    @AppStorage(WritingPartnerDefaults.curlyQuotes) private var curlyQuotes = false
    @AppStorage(WritingPartnerDefaults.suggestions) private var suggestions = true
    @AppStorage(WritingPartnerDefaults.announceMarks) private var announceMarks = false
    @State private var proseStats = WritingPartnerStats.load(voice: .punctuate)
    @State private var chatStats = WritingPartnerStats.load(voice: .chat)
    var access: PixerateAccess = .shared
    private let activeVoice = WritingPartnerActiveVoice.shared

    private var provider: WritingPartnerProvider { WritingPartnerDefaults.provider() }
    private var languageReason: String? { activeVoice.unsupportedLanguageReason(for: provider) }
    private var flavor: MarkdownFlavor { activeVoice.currentFlavor(default: defaultFlavor) }
    private var voice: WritingPartnerVoice { WritingPartnerVoice(flavor: flavor) }
    private var stats: WritingPartnerStats { voice == .chat ? chatStats : proseStats }

    private var learnedRules: [PunctuationRule] {
        PunctuationRule.allCases.filter { $0 != .spelling && ($0 != .curlyQuotes || curlyQuotes) && voice.rules.contains($0) }
    }

    private var pauseTier: String {
        if access.isSubscribed {
            if let until = access.pausedUntil, until > .now { return "Paused until \(until.formatted(date: .omitted, time: .shortened))" }
            return "Pixerate, or on this device when offline"
        }
        return provider == .onDevice ? "On this device (Apple Intelligence)" : "Basic fixes only"
    }

    // The same five sections as the Mac's Settings › Writing (#229)
    var body: some View {
        Form {
            Section {
                Picker("Writing partner", selection: $mode) {
                    ForEach(WritingPartnerMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                Toggle(isOn: $suggestions) {
                    Text("Suggestions")
                    Text("Underlines fixes it isn't sure of instead of making them.")
                }
                .disabled(mode == .off)
                Toggle("Announce suggestions with VoiceOver", isOn: $announceMarks)
                    .disabled(mode == .off || !suggestions)
                LabeledContent("Voice", value: WritingPartnerVoice.summary(for: flavor))
            } footer: {
                Text(mode.isOn ? "\(mode.summary) Each fix is its own undo step. Writing Partner Edits in the editor's menu shows what it changed, to revert one edit or a whole layer." : mode.summary)
            }

            IOSWritingPartnerStyleSection(level: mode)

            Section {
                LabeledContent("When you pause", value: pauseTier)
                if let languageReason {
                    LabeledContent("Language", value: languageReason)
                }
            } footer: {
                if access.isSubscribed {
                    Text("Sends the paragraph you just wrote to Pixerate when you pause: for corrections in Copyedit, and to rewrite it in Ghostwrite. Code, math and tables are never sent. Without a connection, the partner carries on with what this device can do.")
                } else {
                    Text("Copyedit works without Swash Pro. Without it, or offline, Ghostwrite uses Copyedit and Apple Intelligence on this device.")
                }
            }
            .disabled(mode == .off)

            Section {
                Toggle("Curly quotes", isOn: $curlyQuotes)
            } header: {
                Text("Typography")
            }
            .disabled(mode == .off)

            Section {
                ForEach(learnedRules, id: \.self) { rule in
                    LabeledContent {
                        if !WritingPartnerDefaults.isRuleEnabled(rule) {
                            Text("Off").foregroundStyle(.tertiary)
                        } else if stats.isActive(rule) {
                            Text("On").foregroundStyle(.secondary)
                        } else {
                            Text("Stopped after you undid it").foregroundStyle(.orange)
                        }
                    } label: {
                        Text(rule.title)
                        if let example = rule.example {
                            Text(example)
                        }
                    }
                }
                Button("Reset What It Has Learned", role: .destructive) {
                    UserDefaults.standard.removeObject(forKey: WritingPartnerDefaults.statsKey(for: voice))
                    reloadStats()
                }
                .disabled(stats.rules.isEmpty)
            } header: {
                Text("What It Has Learned")
            } footer: {
                Text("Spelling, grammar and formatting are all on. Undoing or reverting a fix makes it less likely; two in a row stop it.")
            }
            .disabled(mode == .off)

            Section {
                Link("What the writing partner sends",
                     destination: URL(string: "https://github.com/Pixerate/Swash/blob/main/docs/writing-partner-privacy.md")!)
            }
        }
        .navigationTitle("Writing Partner")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { reloadStats() }
        .onReceive(NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)) { _ in
            reloadStats()
        }
    }

    private func reloadStats() {
        proseStats = WritingPartnerStats.load(voice: .punctuate)
        chatStats = WritingPartnerStats.load(voice: .chat)
    }
}

#Preview("Writing Partner") {
    NavigationStack {
        IOSWritingPartnerSettings(access: .preview())
    }
}

#Preview("Writing Partner - Dark Mode") {
    NavigationStack {
        IOSWritingPartnerSettings(access: .preview())
    }
    .preferredColorScheme(.dark)
}
#endif

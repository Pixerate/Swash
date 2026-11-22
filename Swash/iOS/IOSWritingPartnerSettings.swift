//
//  IOSWritingPartnerSettings.swift
//  Swash
//
//  Settings › Writing Partner on iPhone and iPad (#109): the same switches as the Mac's Settings ›
//  Writing, worded for touch (undo instead of ⌘Z, the edit menu instead of Tab).
//

#if os(iOS)
import SwiftUI

struct IOSWritingPartnerSettings: View {
    @AppStorage(WritingPartnerDefaults.mode) private var mode: WritingPartnerMode = .automatic
    @AppStorage("markdownFlavor") private var defaultFlavor: MarkdownFlavor = .github
    @AppStorage(WritingPartnerDefaults.curlyQuotes) private var curlyQuotes = false
    @AppStorage(WritingPartnerDefaults.doubledWords) private var doubledWords = true
    @AppStorage(WritingPartnerDefaults.aAndAn) private var aAndAn = true
    @AppStorage(WritingPartnerDefaults.agreementAndTense) private var agreementAndTense = true
    @AppStorage(WritingPartnerDefaults.missingWords) private var missingWords = true
    @AppStorage(WritingPartnerDefaults.markUncertain) private var markUncertain = true
    @AppStorage(WritingPartnerDefaults.announceMarks) private var announceMarks = false
    @AppStorage(WritingPartnerDefaults.formattingInSource) private var formattingInSource = false
    @State private var spellingOn = WritingPartnerDefaults.spelling()
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

    var body: some View {
        Form {
            Section {
                Picker("Fix as I type", selection: $mode) {
                    ForEach(WritingPartnerMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                Toggle("Correct spelling", isOn: Binding(
                    get: { spellingOn },
                    set: { UserDefaults.standard.set($0, forKey: WritingPartnerDefaults.spelling); spellingOn = $0 }
                ))
                .disabled(mode == .off)
                Toggle("Mark what it isn't sure about", isOn: $markUncertain)
                    .disabled(mode != .automatic)
                Toggle("Announce marks with VoiceOver", isOn: $announceMarks)
                    .disabled(mode != .automatic || !markUncertain)
                LabeledContent("Voice", value: WritingPartnerVoice.summary(for: flavor))
            } footer: {
                Text("Fixes punctuation, capitals and spelling as you type, on this device. Each fix is its own undo step. In Suggest mode, touch and hold a suggestion and choose it from the menu, or press Tab on a keyboard.")
            }

            Section {
                LabeledContent("When you pause", value: pauseTier)
            } footer: {
                if access.isSubscribed {
                    Text("Sends the paragraph you just wrote to Pixerate when you pause, for grammar and structure suggestions. Code, math and tables are never sent. Without a connection, the partner carries on with what this device can do.")
                } else {
                    Text("Fixes as you type work without Swash Pro.")
                }
            }
            .disabled(mode == .off)

            Section {
                Toggle("Doubled words", isOn: $doubledWords)
                Toggle("A and an", isOn: $aAndAn)
                Toggle("Agreement and tense", isOn: $agreementAndTense)
                    .disabled(provider == .none || languageReason != nil)
                Toggle("Missing words", isOn: $missingWords)
                    .disabled(provider == .none || languageReason != nil)
            } header: {
                Text("Grammar")
            } footer: {
                Text("\(languageReason.map { "\($0). " } ?? "")Doubled words and A and an run as you type; Agreement and tense and Missing words run when you pause.")
            }
            .disabled(mode == .off)

            Section {
                ForEach(FormattingVoice.rules, id: \.self) { rule in
                    IOSFormattingRuleToggle(rule: rule)
                }
                Toggle("Also in Source view", isOn: $formattingInSource)
            } header: {
                Text("Formatting")
            } footer: {
                Text("Tidies Markdown in blocks you've edited once you leave them, without changing how the document reads.")
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
                    LabeledContent(rule.title) {
                        if !WritingPartnerDefaults.isRuleEnabled(rule) {
                            Text("Off").foregroundStyle(.tertiary)
                        } else if stats.isActive(rule) {
                            Text("On").foregroundStyle(.secondary)
                        } else {
                            Text("Stopped after you undid it").foregroundStyle(.orange)
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
                Text("Undoing a fix makes it less likely; two undos in a row stop it.")
            }

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

private struct IOSFormattingRuleToggle: View {
    let rule: PunctuationRule
    @AppStorage private var isOn: Bool

    init(rule: PunctuationRule) {
        self.rule = rule
        _isOn = AppStorage(wrappedValue: true, WritingPartnerDefaults.formattingKey(rule))
    }

    var body: some View {
        Toggle(isOn: $isOn) {
            Text(rule.title)
            if let example = rule.example {
                Text(example)
            }
        }
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

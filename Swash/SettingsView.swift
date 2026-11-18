//
//  SettingsView.swift
//  Swash
//

#if os(macOS)
import SwiftUI
import MacAppKitExtras
import PixerateCore

struct SettingsView: View {
    private enum Tab: Hashable {
        case general, appearance, writing, agents, account, updates
    }

    @State private var selection: Tab = .general

    var body: some View {
        TabView(selection: $selection) {
            GeneralSettingsView()
                .tabItem { Label("General", systemImage: "gearshape") }
                .tag(Tab.general)

            AppearanceSettingsView()
                .tabItem { Label("Appearance", systemImage: "textformat.size") }
                .tag(Tab.appearance)

            WritingPartnerSettingsView()
                .tabItem { Label("Writing", systemImage: "character.cursor.ibeam") }
                .tag(Tab.writing)

            AgentSettingsView()
                .tabItem { Label("Agents", systemImage: "sparkles") }
                .tag(Tab.agents)

            AccountSettingsView()
                .tabItem { Label("Account", systemImage: "person.crop.circle") }
                .tag(Tab.account)

            UpdatesSettingsView()
                .tabItem { Label("Updates", systemImage: "arrow.triangle.2.circlepath") }
                .tag(Tab.updates)
        }
        .frame(width: 500)
        .scenePadding(.minimum, edges: .vertical)
    }
}

// MARK: - General

private struct GeneralSettingsView: View {
    @ObservedObject private var defaultAppManager = DefaultAppManager.shared
    @AppStorage("markdownFlavor") private var markdownFlavor: MarkdownFlavor = .github
    @AppStorage(QuickCaptureShortcut.defaultsKey) private var quickCaptureShortcut: QuickCaptureShortcut = QuickCaptureShortcut.defaultValue
    @AppStorage("showMenuBarExtra") private var showMenuBarExtra = false
    @AppStorage(ImageInsertion.folderDefaultsKey) private var imageFolder = ImageInsertion.defaultFolderName
    @State private var opensAtLogin = LoginItem.isEnabled

    var body: some View {
        Form {
            Section {
                Picker("Markdown flavor", selection: $markdownFlavor) {
                    ForEach(MarkdownFlavor.allCases) { flavor in
                        Text(flavor.displayName).tag(flavor)
                    }
                }
            } header: {
                Text("Editor")
            } footer: {
                Text("Controls which Markdown syntax extensions are recognised when editing and previewing documents.")
                    .settingsFooterStyle()
            }

            Section {
                LabeledContent {
                    if defaultAppManager.isDefaultApp {
                        Label("Default", systemImage: "checkmark.circle.fill")
                            .labelStyle(.titleAndIcon)
                            .foregroundStyle(.green)
                    } else {
                        Button("Make Default") {
                            defaultAppManager.makeDefaultApp()
                        }
                    }
                } label: {
                    Text("Default Markdown editor")
                    Text(defaultAppManager.isDefaultApp
                         ? "Markdown files open in Swash."
                         : "Markdown files open in another app.")
                }
            } header: {
                Text("File Associations")
            }

            Section {
                TextField("Images folder", text: $imageFolder, prompt: Text("Same folder as the document"))
            } header: {
                Text("Images")
            } footer: {
                Text("Images you drag or paste into a document are copied into this folder beside it and linked with a relative path. Leave it empty to put them next to the document.")
                    .settingsFooterStyle()
            }

            Section {
                Picker("Quick Note shortcut", selection: $quickCaptureShortcut) {
                    ForEach(QuickCaptureShortcut.allCases) { shortcut in
                        Text(shortcut.title).tag(shortcut)
                    }
                }
                .onChange(of: quickCaptureShortcut) { _, shortcut in
                    GlobalHotKey.shared.register(shortcut)
                }
                Toggle("Show Swash in the menu bar", isOn: $showMenuBarExtra)
                Toggle("Open Swash at login", isOn: Binding(
                    get: { opensAtLogin },
                    set: { LoginItem.setEnabled($0); opensAtLogin = LoginItem.isEnabled }
                ))
            } header: {
                Text("Quick Note")
            } footer: {
                Text("The shortcut opens a floating note from any app. Save it as a new document or add it to the last document you used.")
                    .settingsFooterStyle()
            }
        }
        .formStyle(.grouped)
        .scrollDisabled(true)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear {
            defaultAppManager.refreshDefaultStatus()
        }
    }
}

// MARK: - Appearance

private struct AppearanceSettingsView: View {
    @AppStorage(EditorTypography.Keys.font) private var font: TypographyFont = .system
    @AppStorage(EditorTypography.Keys.textSize) private var textSize: Double = Double(EditorTypography.defaultTextSize)
    @AppStorage(EditorTypography.Keys.lineWidth) private var lineWidth: TypographyLineWidth = .full
    @AppStorage(EditorTypography.Keys.theme) private var theme: EditorTheme = .system

    private var typography: EditorTypography {
        EditorTypography(font: font, textSize: EditorTypography.clampedSize(textSize), lineWidth: lineWidth, theme: theme)
    }

    var body: some View {
        Form {
            Section {
                Picker("Font", selection: $font) {
                    ForEach(TypographyFont.allCases) { font in
                        Text(font.title).tag(font)
                    }
                }
                LabeledContent("Text size") {
                    HStack(spacing: 8) {
                        Slider(value: $textSize,
                               in: Double(EditorTypography.minTextSize)...Double(EditorTypography.maxTextSize),
                               step: 1)
                            .frame(width: 180)
                        Text("\(Int(textSize)) pt")
                            .monospacedDigit()
                            .frame(width: 44, alignment: .trailing)
                    }
                }
                Picker("Line width", selection: $lineWidth) {
                    ForEach(TypographyLineWidth.allCases) { width in
                        Text(width.title).tag(width)
                    }
                }
                .pickerStyle(.segmented)
            } header: {
                Text("Typography")
            } footer: {
                Text("Applies to Edit Text, Edit Markdown and the Preview. Use View › Bigger (⌘+), Smaller (⌘−) and Actual Size (⌘0) to change the text size from any document.")
                    .settingsFooterStyle()
            }

            Section {
                Picker("Theme", selection: $theme) {
                    ForEach(EditorTheme.allCases) { theme in
                        Label {
                            Text(theme.title)
                        } icon: {
                            Image(systemName: "circle.fill")
                                .foregroundStyle(theme.accent.map { Color(nsColor: $0) } ?? Color.accentColor)
                        }
                        .tag(theme)
                    }
                }
                LabeledContent("Sample") {
                    sample
                }
            } header: {
                Text("Colours")
            } footer: {
                Text("Themes colour code, links, quotes and tasks, and follow Light and Dark Mode. Quick Look previews use the standard look.")
                    .settingsFooterStyle()
            }

            Section {
                HStack {
                    Spacer()
                    Button("Restore Defaults") {
                        font = .system
                        textSize = Double(EditorTypography.defaultTextSize)
                        lineWidth = .full
                        theme = .system
                    }
                    .disabled(typography == EditorTypography())
                }
            }
        }
        .formStyle(.grouped)
        .scrollDisabled(true)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var sample: some View {
        let accent = typography.previewAccent
        return (Text("Swash ").bold()
            + Text("writes ")
            + Text("code").monospaced().foregroundColor(accent)
            + Text(" and ")
            + Text("links").foregroundColor(accent).underline())
            .font(typography.previewFont())
            .padding(.vertical, 4)
            .padding(.horizontal, 8)
            .background(typography.theme.background.map { Color(nsColor: $0) } ?? Color(nsColor: .textBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 4))
    }
}

// MARK: - Updates

private struct UpdatesSettingsView: View {
    @ObservedObject private var sparkleUpdater = SparkleUpdater.shared

    private var versionString: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "–"
        let build = info?["CFBundleVersion"] as? String ?? "–"
        return "\(version) (\(build))"
    }

    var body: some View {
        Form {
            Section {
                Toggle("Automatically check for updates", isOn: $sparkleUpdater.automaticallyChecksForUpdates)

                LabeledContent("Current version") {
                    Text(versionString)
                        .monospacedDigit()
                        .textSelection(.enabled)
                }
            } footer: {
                HStack {
                    Spacer()
                    Button("Check for Updates…") {
                        sparkleUpdater.checkForUpdates()
                    }
                    .disabled(!sparkleUpdater.canCheckForUpdates)
                }
            }
        }
        .formStyle(.grouped)
        .scrollDisabled(true)
        .fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: - Writing partner

/// Punctuation and capitals as you type (#61, #105).
private struct WritingPartnerSettingsView: View {
    @AppStorage(WritingPartnerDefaults.mode) private var mode: WritingPartnerMode = .off
    @AppStorage("markdownFlavor") private var defaultFlavor: MarkdownFlavor = .github
    private let activeVoice = WritingPartnerActiveVoice.shared
    @State private var proseStats = WritingPartnerStats.load(voice: .punctuate)
    @State private var chatStats = WritingPartnerStats.load(voice: .chat)
    @State private var spellingOn = WritingPartnerDefaults.spelling()
    private var access: PixerateAccess = .shared
    @AppStorage(WritingPartnerDefaults.curlyQuotes) private var curlyQuotes = false
    @AppStorage(WritingPartnerDefaults.doubledWords) private var doubledWords = true
    @AppStorage(WritingPartnerDefaults.aAndAn) private var aAndAn = true
    @AppStorage(WritingPartnerDefaults.agreementAndTense) private var agreementAndTense = true
    @AppStorage(WritingPartnerDefaults.missingWords) private var missingWords = true
    @AppStorage(WritingPartnerDefaults.quickNoteTidy) private var quickNoteTidy = true
    @State private var showLearnedRules = false

    private var provider: WritingPartnerProvider {
        WritingPartnerDefaults.provider()
    }

    private var unsupportedLanguageReason: String? {
        activeVoice.unsupportedLanguageReason(for: provider)
    }

    private var isPauseGrammarAvailable: Bool {
        provider != .none && unsupportedLanguageReason == nil
    }

    private var flavor: MarkdownFlavor {
        activeVoice.currentFlavor(default: defaultFlavor)
    }

    private var voice: WritingPartnerVoice {
        WritingPartnerVoice(flavor: flavor)
    }

    private var stats: WritingPartnerStats {
        voice == .chat ? chatStats : proseStats
    }

    private var learnedRules: [PunctuationRule] {
        PunctuationRule.allCases.filter { $0 != .spelling && ($0 != .curlyQuotes || curlyQuotes) }
    }

    private var learnedSummary: String {
        let stopped = learnedRules.filter { voice.rules.contains($0) && !stats.isActive($0) }.count
        return stopped == 0 ? "All on" : "\(stopped) stopped"
    }

    private func reloadStats() {
        proseStats = WritingPartnerStats.load(voice: .punctuate)
        chatStats = WritingPartnerStats.load(voice: .chat)
    }

    var body: some View {
        Form {
            Section {
                Picker("Fix punctuation as I type", selection: $mode) {
                    ForEach(WritingPartnerMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                Toggle("Correct spelling", isOn: Binding(
                    get: { spellingOn },
                    set: { UserDefaults.standard.set($0, forKey: WritingPartnerDefaults.spelling); spellingOn = $0 }
                ))
                .disabled(mode == .off)
                LabeledContent("Voice") {
                    Text(WritingPartnerVoice.summary(for: flavor))
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("Writing Partner")
            } footer: {
                Text("Fixes punctuation, capitals, and spelling as you type on this Mac. In Suggest mode, press Tab or ⌥⏎ to accept, Esc to dismiss, or ⌘Z to undo.")
                    .settingsFooterStyle()
                Link("What the writing partner sends", destination: URL(string: "https://github.com/Pixerate/Swash/blob/main/docs/writing-partner-privacy.md")!)
                    .font(.footnote)
            }

            WritingPartnerStyleSection()

            Section {
                LabeledContent("When you pause") {
                    if WritingPartnerDefaults.provider() == .onDevice {
                        Text("On this Mac (Apple Intelligence)").foregroundStyle(.secondary)
                    } else if access.isSignedOut {
                        Text("Basic fixes only").foregroundStyle(.secondary)
                    } else if !access.isSubscribed {
                        Text("Basic plan: fixes as you type only").foregroundStyle(.secondary)
                    } else if let until = access.pausedUntil, until > .now {
                        Text("Paused until \(until, style: .time)").foregroundStyle(.secondary)
                    } else {
                        Text("Pixerate")
                    }
                }
                .disabled(mode == .off)
                Toggle("Tidy Quick Notes on pause or save", isOn: $quickNoteTidy)
                    .disabled(WritingPartnerDefaults.provider() != .pixerate)
            } footer: {
                if access.isSignedOut {
                    Text("Sign in to Pixerate (Account) for paragraph structure suggestions on pause. On-device fixes work without an account.")
                        .settingsFooterStyle()
                } else if !access.isSubscribed {
                    Text("Paragraph structure suggestions on pause require Pixerate Pro (Account). On-device fixes work on the Basic plan.")
                        .settingsFooterStyle()
                } else {
                    Text("Sends the paragraph you just wrote to Pixerate on pause for structure suggestions. Code, math, and tables are never sent.")
                        .settingsFooterStyle()
                }
            }

            Section {
                Toggle("Doubled words", isOn: $doubledWords)
                Toggle("A and an", isOn: $aAndAn)
                Toggle("Agreement and tense", isOn: $agreementAndTense)
                    .disabled(!isPauseGrammarAvailable)
                Toggle("Missing words", isOn: $missingWords)
                    .disabled(!isPauseGrammarAvailable)
                if let languageReason = unsupportedLanguageReason {
                    LabeledContent("Language") {
                        Text(languageReason)
                            .foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text("Grammar")
            } footer: {
                if let languageReason = unsupportedLanguageReason {
                    Text("\(languageReason). Doubled words and A and an run on this Mac as you type; Agreement and tense and Missing words run when you pause. Each rule learns from ⌘Z.")
                        .settingsFooterStyle()
                } else {
                    Text("Doubled words (the the → the, keeping had had and that that) and A and an (a apple → an apple, an user → a user) run on this Mac as you type. Agreement and tense (the results shows, tense slips, should of) and Missing words (went the shop → went to the shop) run when you pause. Each rule learns from ⌘Z, and is off in code, math, tables, verse, dialogue and quotations.")
                        .settingsFooterStyle()
                }
            }
            .disabled(mode == .off)

            Section {
                Toggle("Curly quotes", isOn: $curlyQuotes)
            } header: {
                Text("Typography")
            } footer: {
                Text("Converts straight quotes, dashes (--, ---), and ellipses (...) in prose only. Undo with ⌘Z to teach the partner to do it less.")
                    .settingsFooterStyle()
            }
            .disabled(mode == .off)

            Section {
                DisclosureGroup(isExpanded: $showLearnedRules) {
                    ForEach(learnedRules, id: \.self) { rule in
                        LabeledContent(rule.title) {
                            if !voice.rules.contains(rule) {
                                Text("Off in Chat")
                                    .foregroundStyle(.tertiary)
                            } else if !WritingPartnerDefaults.isRuleEnabled(rule) {
                                Text("Off")
                                    .foregroundStyle(.tertiary)
                            } else if rule.isPauseTierGrammar, let languageReason = unsupportedLanguageReason {
                                Text(languageReason)
                                    .foregroundStyle(.tertiary)
                            } else if stats.isActive(rule) {
                                Text("On")
                                    .foregroundStyle(.secondary)
                            } else {
                                Text("Stopped after you undid it")
                                    .foregroundStyle(.orange)
                            }
                        }
                    }
                } label: {
                    LabeledContent("Learned rules") {
                        Text(learnedSummary)
                            .foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text("What It Has Learned")
            } footer: {
                HStack(alignment: .firstTextBaseline) {
                    Text("Undoing a fix with ⌘Z makes it less likely in this voice; two undos in a row stop it.")
                        .settingsFooterStyle()
                    Button("Reset") {
                        UserDefaults.standard.removeObject(forKey: WritingPartnerDefaults.statsKey(for: voice))
                        reloadStats()
                    }
                    .disabled(stats.rules.isEmpty)
                }
            }
        }
        .formStyle(.grouped)
        .frame(height: 520)
        .onAppear { reloadStats() }
        .onReceive(NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)) { _ in
            reloadStats()
        }
    }
}

// MARK: - Agents

/// Hosts a local Streamable HTTP MCP server so AI agents can read and edit open documents.
private struct AgentSettingsView: View {
    @AppStorage(AgentBridgeDefaults.enabled) private var enabled = false
    @AppStorage(AgentBridgeDefaults.port) private var port = Int(AgentBridgeDefaults.defaultPort)
    @AppStorage(AgentBridgeDefaults.token) private var token = ""
    @State private var copiedConfig = false
    private let bridge = AgentBridge.shared

    private var statusText: String {
        guard enabled else { return "Off" }
        switch bridge.status {
        case .stopped:
            return "Stopped"
        case .starting:
            return "Starting…"
        case .listening(let port):
            let docs = bridge.documentCount
            if docs == 0 {
                return "Listening on \(AgentBridgeDefaults.endpointURL(port: port))"
            }
            return "Listening on \(AgentBridgeDefaults.endpointURL(port: port)) (\(docs) \(docs == 1 ? "document" : "documents"))"
        case .failed(let message):
            return "Failed: \(message)"
        }
    }

    private var statusColor: Color {
        guard enabled else { return .secondary }
        switch bridge.status {
        case .listening: return .green
        case .starting: return .orange
        case .failed: return .red
        case .stopped: return .secondary
        }
    }

    var body: some View {
        Form {
            Section {
                Toggle("Let agents connect to Swash", isOn: $enabled)
                    .onChange(of: enabled) { bridge.settingsChanged() }
                LabeledContent("Status") {
                    Label(statusText, systemImage: "circle.fill")
                        .labelStyle(.titleAndIcon)
                        .foregroundStyle(statusColor)
                        .textSelection(.enabled)
                }
            } header: {
                Text("MCP Server")
            } footer: {
                Text("Swash runs a local Streamable HTTP MCP server on this Mac. Agents such as Antigravity, Claude Code, and Cursor connect directly to read and edit open documents. Every change can be undone.")
                    .settingsFooterStyle()
            }

            Section {
                TextField("Port", value: $port, format: .number.grouping(.never))
                    .onSubmit { bridge.settingsChanged() }
                if !AgentBridgeDefaults.validPorts.contains(port) {
                    Text("Use a port from \(AgentBridgeDefaults.validPorts.lowerBound) to \(AgentBridgeDefaults.validPorts.upperBound). Swash listens on \(bridge.port) until then.")
                        .foregroundStyle(.red)
                        .settingsFooterStyle()
                }
                SecureField("Token (optional)", text: $token)
                    .onSubmit { bridge.settingsChanged() }
                LabeledContent("Client Setup") {
                    HStack {
                        Button(copiedConfig ? "Copied" : "Copy MCP Config") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(bridge.mcpConfigSnippet(), forType: .string)
                            copiedConfig = true
                            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                                copiedConfig = false
                            }
                        }
                        if enabled {
                            Button("Restart") { bridge.restartServer() }
                        }
                    }
                }
            } footer: {
                Text("Add the copied mcpServers entry to your MCP client's configuration. Leave Token blank for local-only access without a bearer token.")
                    .settingsFooterStyle()
            }
        }
        .formStyle(.grouped)
        .scrollDisabled(true)
        .fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: - Account

/// The opt-in Pixerate account for the writing partner's server features (#60).
private struct AccountSettingsView: View {
    var body: some View {
        Form {
            PixerateAccountSections()
        }
        .formStyle(.grouped)
        .scrollDisabled(true)
        .fixedSize(horizontal: false, vertical: true)
    }
}

private extension View {
    func settingsFooterStyle() -> some View {
        font(.footnote)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

#Preview {
    SettingsView()
}
#endif

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

/// Punctuation and capitals as you type (#61).
private struct WritingPartnerSettingsView: View {
    @AppStorage(WritingPartnerDefaults.mode) private var mode: WritingPartnerMode = .off
    @State private var stats = WritingPartnerStats.load()
    @State private var spellingOn = WritingPartnerDefaults.spelling()
    private var access: PixerateAccess = .shared

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
            } header: {
                Text("Writing Partner")
            } footer: {
                Text("When you finish a word, Swash gives it a capital, an apostrophe or a comma it needs (i → I, dont → don't, id like → I'd like, ok → OK, a capital to start a sentence, a comma before “but” that starts a new clause), and pressing Return at the end of a sentence adds its full stop or question mark. With Correct spelling on, it also fixes misspellings, in place of macOS's autocorrect. In Suggest mode, each fix is underlined for you to accept (Tab, ⌥⏎ or click) or dismiss (Esc). Each fix is its own step: press ⌘Z to undo it, and an undone or dismissed spelling fix leaves that word alone. Code, math, links' addresses and tables are never changed. These fixes never leave this Mac.")
                    .settingsFooterStyle()
                Link("What the writing partner sends", destination: URL(string: "https://github.com/Pixerate/Swash/blob/main/docs/writing-partner-privacy.md")!)
                    .font(.footnote)
            }

            WritingPartnerStyleSection()

            Section {
                LabeledContent("When you pause") {
                    if access.isSignedOut {
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
            } footer: {
                if access.isSignedOut {
                    Text("Signed in to Pixerate (the Account tab), the partner also reads the paragraph you've just written when you pause, and suggests structure such as a list or a heading. Until then, the fixes as you type work on this Mac.")
                        .settingsFooterStyle()
                } else if !access.isSubscribed {
                    Text("Reading the paragraph when you pause is part of Pixerate Pro (Settings › Account). On the Basic plan, the fixes as you type work on this Mac.")
                        .settingsFooterStyle()
                } else {
                    Text("When you pause, the partner sends the paragraph you've just written to Pixerate and may suggest structure, such as a list or a heading as part of Pixerate Pro. Code, math and tables are never sent.")
                        .settingsFooterStyle()
                }
            }

            Section {
                ForEach(PunctuationRule.allCases.filter { $0 != .spelling }, id: \.self) { rule in
                    LabeledContent(rule.title) {
                        if stats.isActive(rule) {
                            Text("On")
                                .foregroundStyle(.secondary)
                        } else {
                            Text("Stopped after you undid it")
                                .foregroundStyle(.orange)
                        }
                    }
                }
            } header: {
                Text("What It Has Learned")
            } footer: {
                HStack(alignment: .firstTextBaseline) {
                    Text("Undoing a fix straight away makes its kind less likely; undo it twice in a row and it stops.")
                        .settingsFooterStyle()
                    Button("Reset") {
                        UserDefaults.standard.removeObject(forKey: WritingPartnerDefaults.stats)
                        stats = WritingPartnerStats()
                    }
                    .disabled(stats.rules.isEmpty)
                }
            }
        }
        .formStyle(.grouped)
        .scrollDisabled(true)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear { stats = WritingPartnerStats.load() }
    }
}

// MARK: - Agents

/// Connects open documents to `pixerate-mcp-bridge`, so AI agents can read and edit them (#49).
private struct AgentSettingsView: View {
    @AppStorage(AgentBridgeDefaults.enabled) private var enabled = false
    @AppStorage(AgentBridgeDefaults.url) private var url = AgentBridgeDefaults.defaultURL
    @AppStorage(AgentBridgeDefaults.token) private var token = ""
    private let bridge = AgentBridge.shared

    private var statusText: String {
        guard enabled else { return "Off" }
        switch bridge.status {
        case .connected:
            return bridge.documentCount == 1 ? "Connected" : "Connected (\(bridge.connectedCount) of \(bridge.documentCount) documents)"
        case .connecting:
            return "Connecting…"
        case .disconnected:
            return "Not connected"
        case .closed:
            return bridge.documentCount == 0 ? "Connects when a document is open" : "Not connected"
        }
    }

    private var statusColor: Color {
        guard enabled else { return .secondary }
        switch bridge.status {
        case .connected: return .green
        case .connecting: return .orange
        default: return bridge.documentCount == 0 ? .secondary : .red
        }
    }

    var body: some View {
        Form {
            Section {
                Toggle("Let agents edit open documents", isOn: $enabled)
                    .onChange(of: enabled) { bridge.settingsChanged() }
                LabeledContent("Status") {
                    Label(statusText, systemImage: "circle.fill")
                        .labelStyle(.titleAndIcon)
                        .foregroundStyle(statusColor)
                }
                if enabled, bridge.status != .connected, let detail = bridge.detail {
                    Text(detail)
                        .settingsFooterStyle()
                        .textSelection(.enabled)
                }
            } header: {
                Text("Pixerate MCP Bridge")
            } footer: {
                Text("Agents such as Claude Code connect through pixerate-mcp-bridge, which runs on this Mac. Each open document is listed to them, and they edit it with the same tools as the Pixerate editor. Every change can be undone.")
                    .settingsFooterStyle()
            }

            Section {
                TextField("Bridge URL", text: $url)
                    .onSubmit { bridge.settingsChanged() }
                SecureField("Token", text: $token)
                    .onSubmit { bridge.settingsChanged() }
            } footer: {
                HStack(alignment: .firstTextBaseline) {
                    Text("Start the bridge with npx pixerate-mcp-bridge --token <secret>, and enter the same token here.")
                        .settingsFooterStyle()
                    Button("Reconnect") { bridge.settingsChanged() }
                        .disabled(!enabled)
                }
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

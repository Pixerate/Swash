//
//  AgentBridge.swift
//  Swash
//
//  Connects open documents to `pixerate-mcp-bridge` (#49), so an MCP client (Claude Desktop,
//  Claude Code, an IDE) can read and edit them with the Pixerate editor's text tools
//  (`MarkdownAgentTools.swift`). Each document window registers as one editor in the bridge's
//  `list_editors`. Off by default: Settings › Agents turns it on, with the bridge's token.
//

#if os(macOS)
import Foundation
import Observation
import PixerateCore
import SwiftUI

enum AgentBridgeDefaults {
    static let enabled = "agentBridgeEnabled"
    static let url = "agentBridgeURL"
    static let token = "agentBridgeToken"
    static let defaultURL = "ws://127.0.0.1:\(toolBridgeDefaultPort)"
}

/// One document's tools: what they read and edit, and its bridge connection.
@MainActor
final class AgentDocumentSession: MarkdownToolTarget {
    /// The live raw Markdown.
    var readMarkdown: () -> String = { "" }
    /// The live selection in raw-Markdown offsets, or nil without an editor.
    var readSelection: () -> NSRange? = { nil }
    /// Applies a whole-text edit as one undo step and selects the range.
    var applyEdit: (String, NSRange, String) -> Void = { _, _, _ in }
    /// Moves the editor's selection.
    var selectRange: (NSRange) -> Void = { _ in }

    /// How the document is listed to agents ("Swash — <name>").
    var name = "Untitled" {
        didSet { if name != oldValue { AgentBridge.shared.reconnect(self) } }
    }

    /// The document's flavour, so Slack documents are read and formatted as Slack mrkdwn.
    var flavor: MarkdownFlavor = .github

    /// Why the document can't be edited; the write tools are hidden while it is set.
    var readOnlyReason: String? {
        didSet { if readOnlyReason != oldValue { registry.notifyListChanged() } }
    }

    let registry = ToolRegistry()
    fileprivate var client: ToolBridgeClient?
    fileprivate var status: ToolBridgeStatus = .closed
    /// The selection the tools last set, for documents shown without an editor.
    private var lastSelection = NSRange(location: 0, length: 0)
    private var tools: MarkdownToolProvider?

    init() {
        let tools = MarkdownToolProvider(target: self)
        self.tools = tools
        do {
            try registry.register(tools.provider())
        } catch {
            assertionFailure("Agent tools did not register: \(error)")
        }
    }

    var markdown: String { readMarkdown() }

    var selection: NSRange { readSelection() ?? lastSelection }

    func apply(markdown: String, selection: NSRange, actionName: String) {
        lastSelection = selection
        applyEdit(markdown, selection, actionName)
    }

    func select(_ range: NSRange) {
        lastSelection = range
        selectRange(range)
    }
}

/// The open documents' bridge connections and their combined status, for Settings.
@MainActor
@Observable
final class AgentBridge {
    static let shared = AgentBridge()

    /// The combined status: connected when any document is.
    private(set) var status: ToolBridgeStatus = .closed
    /// Why the last connection closed, or why none could be made.
    private(set) var detail: String?
    private(set) var documentCount = 0
    private(set) var connectedCount = 0

    @ObservationIgnored private var sessions: [ObjectIdentifier: AgentDocumentSession] = [:]

    private var defaults: UserDefaults { .standard }
    var isEnabled: Bool { defaults.bool(forKey: AgentBridgeDefaults.enabled) }
    private var urlString: String { defaults.string(forKey: AgentBridgeDefaults.url).flatMap { $0.isEmpty ? nil : $0 } ?? AgentBridgeDefaults.defaultURL }
    private var token: String? { defaults.string(forKey: AgentBridgeDefaults.token).flatMap { $0.isEmpty ? nil : $0 } }

    /// Starts serving a document's tools (connecting when the setting is on).
    func attach(_ session: AgentDocumentSession) {
        sessions[ObjectIdentifier(session)] = session
        if isEnabled { connect(session) }
        refresh()
    }

    /// Stops serving a document's tools.
    func detach(_ session: AgentDocumentSession) {
        disconnect(session)
        sessions.removeValue(forKey: ObjectIdentifier(session))
        refresh()
    }

    /// Reconnects a document, for example after its name changed.
    func reconnect(_ session: AgentDocumentSession) {
        guard isEnabled, sessions[ObjectIdentifier(session)] != nil else { return }
        connect(session)
    }

    /// Applies the settings: connects every document when on, disconnects when off.
    func settingsChanged() {
        detail = nil
        for session in sessions.values {
            if isEnabled { connect(session) } else { disconnect(session) }
        }
        refresh()
    }

    private func connect(_ session: AgentDocumentSession) {
        disconnect(session)
        guard let url = URL(string: urlString), url.scheme == "ws" || url.scheme == "wss", url.host != nil else {
            detail = "\(urlString) is not a WebSocket URL (ws://…)."
            return
        }
        session.client = ToolBridgeClient(registry: session.registry, options: ToolBridgeOptions(
            name: "Swash — \(session.name)",
            kind: "document",
            url: url,
            token: token,
            onStatus: { [weak self, weak session] status, detail in
                session?.status = status
                if let detail { self?.detail = detail } else if status == .connected { self?.detail = nil }
                self?.refresh()
            }
        ))
    }

    private func disconnect(_ session: AgentDocumentSession) {
        let client = session.client
        session.client = nil
        client?.close()
        session.status = .closed
    }

    private func refresh() {
        let statuses = sessions.values.map(\.status)
        documentCount = statuses.count
        connectedCount = statuses.filter { $0 == .connected }.count
        if !isEnabled {
            status = .closed
        } else if connectedCount > 0 {
            status = .connected
        } else if statuses.contains(.connecting) {
            status = .connecting
        } else {
            status = statuses.isEmpty ? .closed : .disconnected
        }
    }
}
/// Serves a document view's text to agents while it is shown: reads go to the live editor (or
/// the document when no editor is attached), and writes go through `SwashEditorController`, so
/// each one is a single undo step (GOTCHAS #10).
struct AgentToolsHookup: ViewModifier {
    @Binding var text: String
    let editor: SwashEditorController
    let name: String
    let readOnlyReason: String?
    let flavor: MarkdownFlavor
    @State private var session = AgentDocumentSession()

    func body(content: Content) -> some View {
        content
            .onAppear {
                configure()
                AgentBridge.shared.attach(session)
            }
            .onDisappear { AgentBridge.shared.detach(session) }
            .onChange(of: name) { configure() }
            .onChange(of: readOnlyReason) { configure() }
            .onChange(of: flavor) { configure() }
    }

    private func configure() {
        let text = $text
        let editor = editor
        let attached = { editor.textView?.window != nil }
        session.readMarkdown = { (attached() ? editor.currentRawText : nil) ?? text.wrappedValue }
        session.readSelection = { attached() ? editor.currentRawSelection : nil }
        session.applyEdit = { newText, selection, actionName in
            if !editor.applyAgentEdit(newText: newText, selection: selection, actionName: actionName) {
                text.wrappedValue = newText
            }
        }
        session.selectRange = { editor.select(rawRange: $0) }
        session.readOnlyReason = readOnlyReason
        session.flavor = flavor
        session.name = name
    }
}
#endif

//
//  AgentBridge.swift
//  Swash
//
//  Runs an in-process Streamable HTTP MCP server on 127.0.0.1 so AI agents (Antigravity,
//  Claude Code, Cursor, etc.) can read and edit open documents directly without an external
//  bridge process. Off by default: Settings › Agents turns it on. The server, its security checks
//  and the routing to open documents are PixerateCore's (`MCPServerController`, `MCPToolRouter`);
//  this file supplies Swash's documents, settings and tool catalogue.
//

#if os(macOS)
import Foundation
import Observation
import PixerateCore
import SwiftUI

enum AgentBridgeDefaults {
    static let enabled = "agentBridgeEnabled"
    static let port = "agentBridgePort"
    static let token = "agentBridgeToken"
    /// Swash's own port. Not 4477, which `pixerate-mcp-bridge` uses (`toolBridgeDefaultPort`).
    static let defaultPort: UInt16 = 4478
    /// The default before Swash moved off the bridge's port (GOTCHAS #90).
    static let legacyDefaultPort = 4477

    /// Keeps 4477 for people who turned the server on while it was the default, so the MCP config
    /// they copied still works. Everyone else gets `defaultPort`.
    static func migrateStoredPort(_ defaults: UserDefaults = .standard) {
        if defaults.object(forKey: port) == nil && defaults.bool(forKey: enabled) {
            defaults.set(legacyDefaultPort, forKey: port)
        }
    }
}

/// Hosts the local Streamable HTTP MCP server and routes tool calls to open documents.
@MainActor
@Observable
final class AgentBridge {
    static let shared = AgentBridge()

    private(set) var documentCount = 0
    /// Starts, stops and reports the server (observable, for Settings › Agents).
    let server: MCPServerController

    @ObservationIgnored private let router: MCPToolRouter
    /// A document-less, editable session whose registry is the full tool catalogue: `tools/list`
    /// must not depend on which documents are open (GOTCHAS #88).
    @ObservationIgnored private let catalog = AgentDocumentSession()

    private init() {
        AgentBridgeDefaults.migrateStoredPort()
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        router = MCPToolRouter(
            configuration: .init(
                serverName: "Swash",
                serverVersion: version,
                singular: "document",
                listToolDescription: "Lists the Markdown documents currently open in Swash, most recently active first, with their id, name, flavor, and readOnly status. Pass an id or name as the `document` argument of any other tool.",
                noTargetsMessage: "No documents are open in Swash. Open a Markdown document first."
            ),
            catalog: catalog.registry
        )
        server = MCPServerController(serverName: "swash", realm: "Swash", defaultPort: AgentBridgeDefaults.defaultPort, logSubsystem: "com.pixerate.Swash") { [weak router] method, params in
            guard let router else { return .failure(code: -32603, message: "Server shut down.") }
            // Name the agent's caret after the client that connected (GOTCHAS #95).
            if method == "initialize" { router.actor = AgentBridge.actor(forInitialize: params) }
            return await router.handle(method: method, params: params)
        }
        server.unauthorizedMessage = "Unauthorized: send \"Authorization: Bearer <token>\" with the token from Swash Settings › Agents."
    }

    /// The tool actor for a client that sent `initialize`: one per client name, so a client that
    /// reconnects keeps its caret and colour. PixerateCore's server passes the handler no headers
    /// (no `Mcp-Session-Id`), so calls are attributed to the client that initialized last.
    static func actor(forInitialize params: JSONObject?) -> ToolActor {
        let info = params?["clientInfo"]?.objectValue
        let name = (info?["title"]?.stringValue ?? info?["name"]?.stringValue ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? ToolActor(id: "mcp", name: "MCP Client") : ToolActor(id: "mcp:\(name)", name: name)
    }

    private var defaults: UserDefaults { .standard }
    var isEnabled: Bool { defaults.bool(forKey: AgentBridgeDefaults.enabled) }

    /// The port from Settings, or the default when it is missing or out of range.
    var port: UInt16 { server.validatedPort(defaults.object(forKey: AgentBridgeDefaults.port) as? Int) }

    var token: String? {
        defaults.string(forKey: AgentBridgeDefaults.token).flatMap { $0.isEmpty ? nil : $0 }
    }

    var status: MCPServerStatus { server.status }
    var endpointURL: String { MCPHTTP.endpointURL(port: port) }

    /// Starts the MCP server at app launch when enabled in Settings.
    func startIfEnabled() {
        if isEnabled { settingsChanged() }
    }

    /// Starts serving a document's tools and makes it the default document.
    func attach(_ session: AgentDocumentSession) {
        router.attach(session.target)
        documentCount = router.orderedTargets.count
        if isEnabled && server.status == .stopped { settingsChanged() }
    }

    /// Makes a document the default target for tool calls (its window became active).
    func activate(_ session: AgentDocumentSession) {
        router.activate(session.target)
    }

    /// Stops serving a document's tools.
    func detach(_ session: AgentDocumentSession) {
        session.removeAllAgents()
        router.detach(session.target)
        documentCount = router.orderedTargets.count
        if documentCount == 0 { WritingPartnerActiveVoice.shared.documentFlavor = nil }
    }

    /// Applies the settings: starts when enabled, restarts if the port changed or the last
    /// listener failed, stops when off. Token changes apply to the next request.
    func settingsChanged() {
        server.update(enabled: isEnabled, port: port, token: token)
    }

    /// Restarts the listener (waiting for the old socket to close before rebinding).
    func restartServer() {
        guard isEnabled else { return settingsChanged() }
        settingsChanged()
        // `update` already (re)started it when the port changed or it had failed.
        if server.status != .starting { server.restart() }
    }

    /// Builds the `mcpServers` JSON snippet for Settings › Copy MCP Config (`"type": "http"`).
    func mcpConfigSnippet() -> String {
        MCPHTTP.configSnippet(serverName: "swash", url: endpointURL, token: token)
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
    var documentID: URL? = nil
    @State private var session = AgentDocumentSession()
    @Environment(\.appearsActive) private var appearsActive

    func body(content: Content) -> some View {
        content
            .onAppear {
                configure()
                AgentBridge.shared.attach(session)
            }
            .onDisappear {
                editor.agentCarets = nil
                editor.onUserRawEdit = nil
                AgentBridge.shared.detach(session)
            }
            .onChange(of: appearsActive) { _, active in
                if active { AgentBridge.shared.activate(session) }
            }
            .onChange(of: documentID) {
                session.removeAllAgents()
                editor.onUserRawEdit = nil
                configure()
            }
            .onChange(of: name) { configure() }
            .onChange(of: readOnlyReason) { configure() }
            .onChange(of: flavor) { configure() }
    }

    private func configure() {
        let text = $text
        let editor = editor
        let session = session
        let attached = { editor.textView?.window != nil }
        editor.agentCarets = session.carets
        session.readMarkdown = { (attached() ? editor.currentRawText : nil) ?? text.wrappedValue }
        session.readSelection = { attached() ? editor.currentRawSelection : nil }
        // Agents keep their own selections: their edits map the user's caret instead of moving it.
        session.applyEdit = { newText, edits, actionName in
            let editTuples = edits.map { (range: $0.range, replacementLength: $0.newLength) }
            if !editor.applyAgentEdit(newText: newText, edits: editTuples, actionName: actionName) {
                text.wrappedValue = newText
            }
        }
        // Report the user's edits (exactly, per keystroke) only once an agent has a selection to
        // keep in place; before that the session diffs the text when a tool next reads it. Weak:
        // the session's closures hold the editor, and the editor holds `onUserRawEdit`.
        let reportUserEdits = { [weak session, weak editor] in
            guard let editor, let session, editor.onUserRawEdit == nil else { return }
            editor.onUserRawEdit = { [weak session] range, newLength, newText in
                session?.noteUserEdit(range: range, newLength: newLength, newMarkdown: newText)
            }
        }
        session.onAgentsAppeared = reportUserEdits
        if session.hasAgents { reportUserEdits() }
        session.readOnlyReason = readOnlyReason
        session.flavor = flavor
        session.name = name
        if attached() || WritingPartnerActiveVoice.shared.documentFlavor == nil {
            WritingPartnerActiveVoice.shared.documentFlavor = flavor
        }
    }
}
#endif

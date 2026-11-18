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

/// One document's tools: what they read and edit.
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

    /// How the document is listed to agents (`list_documents`).
    var name: String {
        get { target.name }
        set { target.name = newValue }
    }

    /// The document's flavour, so Slack documents are read and formatted as Slack mrkdwn.
    var flavor: MarkdownFlavor = .github {
        didSet { target.info = Self.info(flavor) }
    }

    /// Why the document can't be edited; the write tools are hidden while it is set.
    var readOnlyReason: String? {
        didSet {
            target.readOnlyReason = readOnlyReason
            if readOnlyReason != oldValue { registry.notifyListChanged() }
        }
    }

    let registry: ToolRegistry
    /// What the MCP server routes this document's tool calls to.
    let target: MCPToolTarget
    /// The selection the tools last set, for documents shown without an editor.
    private var lastSelection = NSRange(location: 0, length: 0)
    private var tools: MarkdownToolProvider?

    init() {
        let registry = ToolRegistry()
        self.registry = registry
        target = MCPToolTarget(name: "Untitled", registry: registry, info: Self.info(.github))
        let tools = MarkdownToolProvider(target: self)
        self.tools = tools
        do {
            try registry.register(tools.provider(id: "document", namespace: ""))
            try registry.register(Self.genUIProvider())
        } catch {
            assertionFailure("Agent tools did not register: \(error)")
        }
    }

    private static func info(_ flavor: MarkdownFlavor) -> JSONObject {
        ["flavor": .string(flavor == .slack ? "slack" : "github")]
    }

    private static func genUIProvider() -> AgentToolProvider {
        let listGenUIBlocks = AgentTool(
            name: "list_genui_blocks",
            title: "List supported GenUI blocks",
            description: "Returns the fenced Markdown code-block languages and capabilities supported by Swash for @pixerate/genui-core embedded UI blocks and permission-gated sandboxed widgets.",
            inputSchema: [
                "type": "object",
                "properties": [:],
                "additionalProperties": false,
            ],
            annotations: ToolAnnotations(title: "List supported GenUI blocks", readOnlyHint: true, destructiveHint: false, idempotentHint: true, openWorldHint: false),
            handler: { _, _ in
                .value(.object([
                    "builtInKinds": .array(GenUIBlockKind.allCases.filter { $0 != .widget }.map { .string($0.rawValue) }),
                    "supportedLanguages": .array(GenUIBlockRegistry.supportedLanguages.map { .string($0) }),
                    "sandboxedWidgets": [
                        "languages": .array([.string("widget"), .string("genui-widget")]),
                        "permissionGated": .bool(true),
                        "fields": .array([.string("title"), .string("height"), .string("html"), .string("script")])
                    ]
                ]))
            }
        )
        return AgentToolProvider(
            id: "genui",
            namespace: "",
            title: "GenUI Blocks",
            description: "Discover Markdown fenced code-block UI capabilities in Swash.",
            tools: { [listGenUIBlocks] }
        )
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
        server = MCPServerController(serverName: "swash", realm: "Swash", defaultPort: AgentBridgeDefaults.defaultPort, logSubsystem: "com.pixerate.Swash", router: router)
        server.unauthorizedMessage = "Unauthorized: send \"Authorization: Bearer <token>\" with the token from Swash Settings › Agents."
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
    @State private var session = AgentDocumentSession()
    @Environment(\.appearsActive) private var appearsActive

    func body(content: Content) -> some View {
        content
            .onAppear {
                configure()
                AgentBridge.shared.attach(session)
            }
            .onDisappear { AgentBridge.shared.detach(session) }
            .onChange(of: appearsActive) { _, active in
                if active { AgentBridge.shared.activate(session) }
            }
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
        if attached() || WritingPartnerActiveVoice.shared.documentFlavor == nil {
            WritingPartnerActiveVoice.shared.documentFlavor = flavor
        }
    }
}
#endif

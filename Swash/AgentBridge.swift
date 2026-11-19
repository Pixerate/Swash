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
    /// Distinct colours for connected agents' cursors and name tags (matching `PRESENCE_COLORS` in @pixerate/editor).
    static let presencePalette = ["#7c3aed", "#db2777", "#0891b2", "#ea580c", "#16a34a"]
    /// How long an idle agent caret stays visible on screen after its last call, in ms (0 keeps it).
    static let defaultCaretIdleMs: Double = 12_000
    /// How long a changed-text tint stays visible after an edit, in ms.
    static let defaultChangedTintMs: Double = 1_500

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
    /// Connected agents' visual carets, selections and changed-range highlights for the editor overlay.
    let carets = AgentCaretStore()
    /// How long an idle agent caret lingers (ms; 0 disables auto-expiry).
    var caretIdleMs: Double = AgentDocumentSession.defaultCaretIdleMs
    /// How long changed-range tints linger (ms; 0 disables auto-expiry).
    var changedTintMs: Double = AgentDocumentSession.defaultChangedTintMs

    /// Monotonically increasing document revision, incremented on every edit.
    private(set) var revision: Int = 0
    /// Retained history of edits per revision, used to transform or reject stale-offset writes.
    private(set) var revisionHistory: [MarkdownRevisionEntry] = []
    private static let maxRevisionHistory = 256

    /// The selection the tools last set when called without an agent actor, or for documents without an editor.
    private var lastSelection = NSRange(location: 0, length: 0)
    /// Per-agent cursor / selection (`actor.id` -> `NSRange` in raw-Markdown UTF-16 offsets).
    private var agentSelections: [String: NSRange] = [:]
    /// Per-agent last-observed document revision (`actor.id` -> `revision`).
    private var agentObservedRevisions: [String: Int] = [:]
    /// Assigned colour per agent id (`actor.id` -> `#rrggbb`).
    private var agentColors: [String: String] = [:]
    private var idleTimers: [String: Task<Void, Never>] = [:]
    private var tintTimers: [String: Task<Void, Never>] = [:]
    private var lastKnownMarkdown: String?
    private var isApplyingToolEdit = false
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

    /// Synchronizes with the current document text so external edits (human typing, undo/redo,
    /// Writing Partner) increment `revision` and map all stored agent cursors before a tool runs.
    private func syncExternalChangesIfNeeded() -> String {
        let current = readMarkdown()
        guard !isApplyingToolEdit else {
            lastKnownMarkdown = current
            return current
        }
        if let previous = lastKnownMarkdown, previous != current {
            let edit = MarkdownToolProvider.change(from: previous as NSString, to: current as NSString)
            recordRevision(edits: [edit])
            mapAllSelections(through: [edit], excludingAgentID: nil)
            carets.mapThroughEdit(range: edit.range, length: edit.newLength)
        }
        lastKnownMarkdown = current
        return current
    }

    /// Called when the user or editor mutates the text outside of an agent tool call.
    func noteExternalEdit(to newMarkdown: String) {
        guard !isApplyingToolEdit else { return }
        let previous = lastKnownMarkdown ?? readMarkdown()
        guard previous != newMarkdown else { return }
        let edit = MarkdownToolProvider.change(from: previous as NSString, to: newMarkdown as NSString)
        lastKnownMarkdown = newMarkdown
        recordRevision(edits: [edit])
        mapAllSelections(through: [edit], excludingAgentID: nil)
        carets.mapThroughEdit(range: edit.range, length: edit.newLength)
    }

    private func recordRevision(edits: [(range: NSRange, newLength: Int)]) {
        revision += 1
        revisionHistory.append(MarkdownRevisionEntry(revision: revision, edits: edits))
        if revisionHistory.count > Self.maxRevisionHistory {
            revisionHistory.removeFirst(revisionHistory.count - Self.maxRevisionHistory)
        }
    }

    private func mapAllSelections(through edits: [(range: NSRange, newLength: Int)], excludingAgentID: String?) {
        lastSelection = MarkdownToolProvider.mapSelection(lastSelection, through: edits)
        for (id, sel) in agentSelections where id != excludingAgentID {
            agentSelections[id] = MarkdownToolProvider.mapSelection(sel, through: edits)
        }
    }

    func caretInfo(for actor: ToolActor) -> AgentCaretInfo {
        let color: String
        if let existing = agentColors[actor.id] {
            color = existing
        } else {
            let assigned = Self.presencePalette[agentColors.count % Self.presencePalette.count]
            agentColors[actor.id] = assigned
            color = assigned
        }
        let label = (actor.name?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap { $0.isEmpty ? nil : $0 } ?? "Agent"
        return AgentCaretInfo(id: actor.id, name: label, color: color)
    }

    private func updatePresence(for actor: ToolActor?, selection: NSRange, changedRanges: [NSRange]) {
        guard let actor else { return }
        let info = caretInfo(for: actor)
        carets.set(info, anchor: selection.location, head: NSMaxRange(selection))
        if !changedRanges.isEmpty {
            carets.markChanges(actor.id, changedRanges)
            tintTimers[actor.id]?.cancel()
            let delay = changedTintMs
            if delay > 0 {
                let id = actor.id
                tintTimers[id] = Task { @MainActor [weak self] in
                    try? await Task.sleep(for: .milliseconds(delay))
                    guard !Task.isCancelled else { return }
                    self?.carets.markChanges(id, [])
                }
            }
        }
        idleTimers[actor.id]?.cancel()
        let idle = caretIdleMs
        if idle > 0 {
            let id = actor.id
            idleTimers[id] = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(idle))
                guard !Task.isCancelled else { return }
                self?.carets.clear(id)
            }
        }
    }

    /// Removes an agent's session state and visual caret (e.g. when the client disconnects).
    func removeAgent(_ id: String) {
        idleTimers[id]?.cancel()
        idleTimers[id] = nil
        tintTimers[id]?.cancel()
        tintTimers[id] = nil
        carets.clear(id)
    }

    var markdown: String { syncExternalChangesIfNeeded() }

    var selection: NSRange { readSelection() ?? lastSelection }

    func selection(for agent: ToolActor?) -> NSRange {
        _ = syncExternalChangesIfNeeded()
        guard let id = agent?.id else { return selection }
        if let existing = agentSelections[id] { return existing }
        let initial = selection
        agentSelections[id] = initial
        return initial
    }

    func select(_ range: NSRange) {
        lastSelection = range
        selectRange(range)
    }

    func select(_ range: NSRange, for agent: ToolActor?) {
        _ = syncExternalChangesIfNeeded()
        if let agent {
            agentSelections[agent.id] = range
            updatePresence(for: agent, selection: range, changedRanges: [])
        } else {
            select(range)
        }
    }

    func apply(markdown: String, selection: NSRange, actionName: String) {
        apply(markdown: markdown, edits: [MarkdownToolProvider.change(from: self.markdown as NSString, to: markdown as NSString)], agentSelection: selection, for: nil, actionName: actionName)
    }

    func apply(markdown: String, edits: [(range: NSRange, newLength: Int)], agentSelection: NSRange, for agent: ToolActor?, actionName: String) {
        _ = syncExternalChangesIfNeeded()
        recordRevision(edits: edits)
        if let agent {
            agentSelections[agent.id] = agentSelection
            mapAllSelections(through: edits, excludingAgentID: agent.id)
        } else {
            lastSelection = agentSelection
            mapAllSelections(through: edits, excludingAgentID: nil)
        }
        for edit in edits {
            carets.mapThroughEdit(range: edit.range, length: edit.newLength)
        }
        var shift = 0
        let insertedRanges: [NSRange] = edits.compactMap { edit in
            defer { shift += edit.newLength - edit.range.length }
            guard edit.newLength > 0 else { return nil }
            return NSRange(location: edit.range.location + shift, length: edit.newLength)
        }
        updatePresence(for: agent, selection: agentSelection, changedRanges: insertedRanges)
        isApplyingToolEdit = true
        lastKnownMarkdown = markdown
        applyEdit(markdown, lastSelection, actionName)
        isApplyingToolEdit = false
    }

    func observedRevision(for agent: ToolActor?) -> Int? {
        guard let id = agent?.id else { return nil }
        return agentObservedRevisions[id]
    }

    func noteObservedRevision(_ revision: Int, for agent: ToolActor?) {
        guard let id = agent?.id else { return }
        agentObservedRevisions[id] = revision
    }
}

/// Tracks connected MCP client sessions (`Mcp-Session-Id` -> `ToolActor`) and dispatches HTTP requests
/// to `MCPToolRouter` with each client's own actor identity so concurrent agents hold independent cursors.
@MainActor
final class MCPSessionManager {
    private var sessions: [String: ToolActor] = [:]
    private var nextFallbackIndex = 0
    var onSessionEnded: ((ToolActor) -> Void)?

    func actor(forSessionID sessionID: String?, params: JSONObject? = nil) -> ToolActor? {
        if let sessionID, !sessionID.isEmpty {
            return sessions[sessionID] ?? ToolActor(id: "mcp:\(sessionID)", name: "MCP Client")
        }
        let clientInfo = params?["clientInfo"]?.objectValue
        if let rawName = clientInfo?["title"]?.stringValue ?? clientInfo?["name"]?.stringValue {
            let trimmed = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                return ToolActor(id: "mcp:\(trimmed)", name: trimmed)
            }
        }
        return nil
    }

    func registerSession(id: String, params: JSONObject?) -> ToolActor {
        let clientInfo = params?["clientInfo"]?.objectValue
        let rawName = clientInfo?["title"]?.stringValue ?? clientInfo?["name"]?.stringValue
        let name = rawName?.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedName: String
        if let name, !name.isEmpty {
            resolvedName = name
        } else {
            nextFallbackIndex += 1
            resolvedName = nextFallbackIndex == 1 ? "MCP Client" : "MCP Client \(nextFallbackIndex)"
        }
        let actor = ToolActor(id: "mcp:\(id)", name: resolvedName)
        sessions[id] = actor
        return actor
    }

    @discardableResult
    func endSession(id: String?) -> ToolActor? {
        guard let id, let removed = sessions.removeValue(forKey: id) else { return nil }
        onSessionEnded?(removed)
        return removed
    }

    /// Handles an `MCPHTTPRequest`, allocating a fresh `Mcp-Session-Id` on `initialize` and
    /// attributing subsequent `tools/call` requests to the session's `ToolActor`.
    func response(
        to request: MCPHTTPRequest,
        port: UInt16,
        token: String?,
        realm: String,
        unauthorizedMessage: String?,
        router: MCPToolRouter
    ) async -> MCPHTTPResponse {
        let incomingSessionID = request.headers["mcp-session-id"]
        if request.method == "DELETE" {
            let context = MCPHTTP.ResponseContext(port: port, token: token, sessionID: incomingSessionID ?? UUID().uuidString, realm: realm, unauthorizedMessage: unauthorizedMessage)
            let resp = await MCPHTTP.response(to: request, context: context) { _, _ in .success([:]) }
            if resp.statusCode == 200 { endSession(id: incomingSessionID) }
            return resp
        }
        let assignedSessionID = incomingSessionID ?? UUID().uuidString
        let context = MCPHTTP.ResponseContext(port: port, token: token, sessionID: assignedSessionID, realm: realm, unauthorizedMessage: unauthorizedMessage)
        return await MCPHTTP.response(to: request, context: context) { [weak self, weak router] method, params in
            guard let router else { return .failure(code: -32603, message: "Server shut down.") }
            if method == "initialize" {
                _ = self?.registerSession(id: assignedSessionID, params: params)
            }
            let previousActor = router.actor
            if let sessionActor = self?.actor(forSessionID: incomingSessionID, params: params) {
                router.actor = sessionActor
            }
            defer { router.actor = previousActor }
            return await router.handle(method: method, params: params)
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

    @ObservationIgnored let router: MCPToolRouter
    @ObservationIgnored let sessionManager = MCPSessionManager()
    @ObservationIgnored private var sessions: [ObjectIdentifier: AgentDocumentSession] = [:]
    /// A document-less, editable session whose registry is the full tool catalogue: `tools/list`
    /// must not depend on which documents are open (GOTCHAS #88).
    @ObservationIgnored private let catalog = AgentDocumentSession()

    private init() {
        AgentBridgeDefaults.migrateStoredPort()
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        let router = MCPToolRouter(
            configuration: .init(
                serverName: "Swash",
                serverVersion: version,
                singular: "document",
                listToolDescription: "Lists the Markdown documents currently open in Swash, most recently active first, with their id, name, flavor, and readOnly status. Pass an id or name as the `document` argument of any other tool.",
                noTargetsMessage: "No documents are open in Swash. Open a Markdown document first."
            ),
            catalog: catalog.registry
        )
        self.router = router
        let sessionManager = self.sessionManager
        server = MCPServerController(serverName: "swash", realm: "Swash", defaultPort: AgentBridgeDefaults.defaultPort, logSubsystem: "com.pixerate.Swash") { [weak router, weak sessionManager] method, params in
            guard let router else { return .failure(code: -32603, message: "Server shut down.") }
            let previousActor = router.actor
            if method == "initialize" {
                let actor = sessionManager?.registerSession(id: UUID().uuidString, params: params)
                if let actor { router.actor = actor }
            } else if let actor = sessionManager?.actor(forSessionID: nil, params: params) {
                router.actor = actor
            }
            defer { if method != "initialize" { router.actor = previousActor } }
            return await router.handle(method: method, params: params)
        }
        server.unauthorizedMessage = "Unauthorized: send \"Authorization: Bearer <token>\" with the token from Swash Settings › Agents."
        sessionManager.onSessionEnded = { [weak self] actor in
            guard let self else { return }
            for session in self.sessions.values {
                session.removeAgent(actor.id)
            }
        }
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
        sessions[ObjectIdentifier(session)] = session
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
        sessions.removeValue(forKey: ObjectIdentifier(session))
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
        let session = session
        let attached = { editor.textView?.window != nil }
        editor.agentCarets = session.carets
        editor.attachAgentCaretsIfNeeded()
        editor.onExternalTextChange = { [weak session] newText in
            session?.noteExternalEdit(to: newText)
        }
        session.readMarkdown = { (attached() ? editor.currentRawText : nil) ?? text.wrappedValue }
        session.readSelection = { attached() ? editor.currentRawSelection : nil }
        session.applyEdit = { newText, _, actionName in
            if !editor.applyAgentEdit(newText: newText, selection: nil, actionName: actionName) {
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

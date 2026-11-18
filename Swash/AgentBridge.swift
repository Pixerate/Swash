//
//  AgentBridge.swift
//  Swash
//
//  Runs an in-process Streamable HTTP MCP server on 127.0.0.1 so AI agents (Antigravity,
//  Claude Code, Cursor, etc.) can read and edit open documents directly without an external
//  bridge process. Off by default: Settings › Agents turns it on.
//

#if os(macOS)
import Foundation
import Network
import Observation
import os
import PixerateCore
import SwiftUI

enum AgentBridgeDefaults {
    static let enabled = "agentBridgeEnabled"
    static let port = "agentBridgePort"
    static let token = "agentBridgeToken"
    static let defaultPort: UInt16 = 4477

    static func endpointURL(port: UInt16) -> String {
        "http://127.0.0.1:\(port)/mcp"
    }
}

enum AgentBridgeStatus: Equatable {
    case stopped
    case starting
    case listening(port: UInt16)
    case failed(String)
}

/// One document's tools: what they read and edit.
@MainActor
final class AgentDocumentSession: MarkdownToolTarget {
    let id = String(UUID().uuidString.prefix(8)).lowercased()

    /// The live raw Markdown.
    var readMarkdown: () -> String = { "" }
    /// The live selection in raw-Markdown offsets, or nil without an editor.
    var readSelection: () -> NSRange? = { nil }
    /// Applies a whole-text edit as one undo step and selects the range.
    var applyEdit: (String, NSRange, String) -> Void = { _, _, _ in }
    /// Moves the editor's selection.
    var selectRange: (NSRange) -> Void = { _ in }

    /// How the document is listed to agents.
    var name = "Untitled"

    /// The document's flavour, so Slack documents are read and formatted as Slack mrkdwn.
    var flavor: MarkdownFlavor = .github

    /// Why the document can't be edited; the write tools are hidden while it is set.
    var readOnlyReason: String? {
        didSet { if readOnlyReason != oldValue { registry.notifyListChanged() } }
    }

    let registry = ToolRegistry()
    fileprivate var attachedAt = Date()
    /// The selection the tools last set, for documents shown without an editor.
    private var lastSelection = NSRange(location: 0, length: 0)
    private var tools: MarkdownToolProvider?

    init() {
        let tools = MarkdownToolProvider(target: self)
        self.tools = tools
        do {
            try registry.register(tools.provider(id: "document", namespace: ""))
            try registry.register(Self.genUIProvider())
        } catch {
            assertionFailure("Agent tools did not register: \(error)")
        }
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

    private(set) var status: AgentBridgeStatus = .stopped
    private(set) var documentCount = 0

    @ObservationIgnored private var sessions: [ObjectIdentifier: AgentDocumentSession] = [:]
    @ObservationIgnored private var server: LocalMCPServer?

    private var defaults: UserDefaults { .standard }
    var isEnabled: Bool { defaults.bool(forKey: AgentBridgeDefaults.enabled) }

    var port: UInt16 {
        let raw = defaults.integer(forKey: AgentBridgeDefaults.port)
        if raw >= 1024 && raw <= 65535 { return UInt16(raw) }
        return AgentBridgeDefaults.defaultPort
    }

    var token: String? {
        defaults.string(forKey: AgentBridgeDefaults.token).flatMap { $0.isEmpty ? nil : $0 }
    }

    var endpointURL: String {
        AgentBridgeDefaults.endpointURL(port: port)
    }

    /// Starts the MCP server at app launch when enabled in Settings.
    func startIfEnabled() {
        if isEnabled && server == nil {
            startServer()
        }
    }

    /// Starts serving a document's tools (and starts the MCP server when enabled).
    func attach(_ session: AgentDocumentSession) {
        session.attachedAt = Date()
        sessions[ObjectIdentifier(session)] = session
        documentCount = sessions.count
        if isEnabled && server == nil {
            startServer()
        }
    }

    /// Stops serving a document's tools.
    func detach(_ session: AgentDocumentSession) {
        sessions.removeValue(forKey: ObjectIdentifier(session))
        documentCount = sessions.count
        if sessions.isEmpty { WritingPartnerActiveVoice.shared.documentFlavor = nil }
    }

    /// Applies the settings: starts when enabled, restarts if the port changed, stops when off.
    func settingsChanged() {
        guard isEnabled else {
            stopServer()
            return
        }
        if let server {
            if server.port != port {
                restartServer()
            }
        } else {
            startServer()
        }
    }

    /// Restarts the listener (waiting for the old socket to close before rebinding).
    func restartServer() {
        guard isEnabled else {
            stopServer()
            return
        }
        if let old = server {
            status = .starting
            old.stop { [weak self] in
                Task { @MainActor [weak self] in
                    _ = old
                    guard let self, self.isEnabled else { return }
                    self.server = nil
                    self.startServer()
                }
            }
        } else {
            startServer()
        }
    }

    /// Builds the `mcpServers` JSON snippet for Settings › Copy MCP Config.
    func mcpConfigSnippet() -> String {
        var entry: [String: Any] = ["url": endpointURL]
        if let token {
            entry["headers"] = ["Authorization": "Bearer \(token)"]
        }
        let root: [String: Any] = ["mcpServers": ["swash": entry]]
        guard let data = try? JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]),
              let str = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return str
    }

    private func startServer() {
        stopServer()
        let listenPort = port
        status = .starting
        let mcpServer = LocalMCPServer(
            port: listenPort,
            token: { [weak self] in self?.token },
            onStateChange: { [weak self] newStatus in
                self?.status = newStatus
            },
            onRequest: { [weak self] method, params in
                guard let self else {
                    return .failure(code: -32603, message: "Server shut down.")
                }
                return await self.handleRPC(method: method, params: params)
            }
        )
        server = mcpServer
        mcpServer.start()
    }

    private func stopServer() {
        server?.stop()
        server = nil
        status = .stopped
    }

    // MARK: - MCP JSON-RPC Dispatch

    private func orderedSessions() -> [AgentDocumentSession] {
        sessions.values.sorted { $0.attachedAt > $1.attachedAt }
    }

    private func resolveSession(forDocument key: String?) -> AgentDocumentSession? {
        let ordered = orderedSessions()
        guard let key, !key.isEmpty else {
            return ordered.first
        }
        if let byID = ordered.first(where: { $0.id.caseInsensitiveCompare(key) == .orderedSame }) {
            return byID
        }
        return ordered.first(where: { $0.name.caseInsensitiveCompare(key) == .orderedSame })
    }

    private func handleRPC(method: String, params: JSONObject?) async -> MCPDispatchResult {
        switch method {
        case "initialize":
            let requestedVersion = params?["protocolVersion"]?.stringValue
            let version = (requestedVersion == "2024-11-05" || requestedVersion == "2025-03-26")
                ? requestedVersion!
                : "2025-03-26"
            let appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
            return .success([
                "protocolVersion": .string(version),
                "capabilities": ["tools": [:]],
                "serverInfo": ["name": "Swash", "version": .string(appVersion)]
            ])

        case "ping":
            return .success([:])

        case "tools/list":
            var tools: [JSONValue] = [listDocumentsToolJSON()]
            if let primary = orderedSessions().first {
                for def in primary.registry.listTools() {
                    tools.append(withOptionalDocumentParameter(def).json)
                }
            }
            return .success(["tools": .array(tools)])

        case "tools/call":
            guard let name = params?["name"]?.stringValue, !name.isEmpty else {
                return .failure(code: -32602, message: "Missing tool name.")
            }
            var args = params?["arguments"]?.objectValue ?? JSONObject()

            if name == "list_documents" {
                let docs: [JSONValue] = orderedSessions().enumerated().map { index, session in
                    .object([
                        "id": .string(session.id),
                        "name": .string(session.name),
                        "flavor": .string(session.flavor == .slack ? "slack" : "github"),
                        "readOnly": .bool(session.readOnlyReason != nil),
                        "isActive": .bool(index == 0)
                    ])
                }
                let result = McpToolResult(
                    content: [.text(JSONValue.array(docs).stringified())],
                    structuredContent: ["documents": .array(docs)]
                )
                return .success(result.json.objectValue ?? [:])
            }

            let docKey = args["document"]?.stringValue
            args["document"] = nil
            guard let session = resolveSession(forDocument: docKey) else {
                let message = docKey == nil
                    ? "No documents are open in Swash. Open a Markdown document first."
                    : "No open document matching \"\(docKey!)\". Call list_documents to see open documents."
                let err = McpToolResult(content: [.text(message)], isError: true)
                return .success(err.json.objectValue ?? [:])
            }

            let result = await session.registry.callTool(name, args, actor: ToolActor(id: "mcp", name: "MCP Client"))
            return .success(result.json.objectValue ?? [:])

        default:
            return .failure(code: -32601, message: "Method not found: \(method)")
        }
    }

    private func listDocumentsToolJSON() -> JSONValue {
        [
            "name": "list_documents",
            "title": "List Open Documents",
            "description": "Lists the Markdown documents currently open in Swash, with their id, name, flavor, and readOnly status.",
            "inputSchema": [
                "type": "object",
                "properties": [:],
                "additionalProperties": false
            ],
            "annotations": [
                "title": "List Open Documents",
                "readOnlyHint": true,
                "idempotentHint": true
            ]
        ]
    }

    private func withOptionalDocumentParameter(_ def: McpToolDefinition) -> McpToolDefinition {
        var copy = def
        guard var schema = def.inputSchema.objectValue else { return copy }
        var props = schema["properties"]?.objectValue ?? JSONObject()
        props["document"] = [
            "type": "string",
            "description": "Optional document id or name from list_documents. Defaults to the active document."
        ]
        schema["properties"] = .object(props)
        copy.inputSchema = .object(schema)
        return copy
    }
}

// MARK: - Embedded Streamable HTTP MCP Server

enum MCPDispatchResult {
    case success(JSONObject)
    case failure(code: Int, message: String)
}

/// Minimal HTTP/1.1 Streamable HTTP MCP server bound to 127.0.0.1 using Network.framework.
@MainActor
final class LocalMCPServer {
    let port: UInt16
    private let token: () -> String?
    private let onStateChange: (AgentBridgeStatus) -> Void
    private let onRequest: (String, JSONObject?) async -> MCPDispatchResult

    private var listener: NWListener?
    private var onStopped: (() -> Void)?
    private let sessionId = UUID().uuidString
    private let logger = Logger(subsystem: "com.pixerate.Swash", category: "MCPServer")

    init(
        port: UInt16,
        token: @escaping () -> String?,
        onStateChange: @escaping (AgentBridgeStatus) -> Void,
        onRequest: @escaping (String, JSONObject?) async -> MCPDispatchResult
    ) {
        self.port = port
        self.token = token
        self.onStateChange = onStateChange
        self.onRequest = onRequest
    }

    func start() {
        logger.notice("Starting MCP server on 127.0.0.1:\(self.port)")
        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            onStateChange(.failed("Invalid port \(port)."))
            return
        }

        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        params.requiredLocalEndpoint = NWEndpoint.hostPort(host: .ipv4(.loopback), port: nwPort)

        do {
            let listener = try NWListener(using: params)
            self.listener = listener

            listener.stateUpdateHandler = { [weak self, weak listener] state in
                Task { @MainActor [weak self, weak listener] in
                    guard let self, let listener, self.listener === listener else { return }
                    switch state {
                    case .ready:
                        self.logger.notice("Listening on http://127.0.0.1:\(self.port)/mcp")
                        self.onStateChange(.listening(port: self.port))
                    case .failed(let error):
                        self.logger.error("Listener failed on port \(self.port): \(error.localizedDescription)")
                        self.onStateChange(.failed(error.localizedDescription))
                    case .cancelled:
                        self.listener = nil
                        self.onStateChange(.stopped)
                        let completion = self.onStopped
                        self.onStopped = nil
                        completion?()
                    default:
                        break
                    }
                }
            }

            listener.newConnectionHandler = { [weak self] connection in
                Task { @MainActor [weak self] in
                    self?.handleConnection(connection)
                }
            }

            listener.start(queue: .main)
        } catch {
            onStateChange(.failed(error.localizedDescription))
        }
    }

    func stop(completion: (() -> Void)? = nil) {
        guard let listener else {
            completion?()
            return
        }
        onStopped = completion
        listener.cancel()
    }

    private func handleConnection(_ connection: NWConnection) {
        connection.start(queue: .main)
        receiveHTTPRequest(on: connection, buffer: Data())
    }

    private func receiveHTTPRequest(on connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            Task { @MainActor in
                guard let self else {
                    connection.cancel()
                    return
                }
                if error != nil {
                    connection.cancel()
                    return
                }
                var accumulated = buffer
                if let data { accumulated.append(data) }

                if let parsed = self.tryParseHTTPRequest(accumulated) {
                    await self.processHTTPRequest(parsed, on: connection)
                } else if isComplete || accumulated.count > Self.maximumBodySize + 64 * 1024 {
                    self.sendHTTPResponse(on: connection, status: "400 Bad Request", body: Data())
                } else {
                    self.receiveHTTPRequest(on: connection, buffer: accumulated)
                }
            }
        }
    }

    private struct HTTPRequest {
        var method: String
        var path: String
        var headers: [String: String]
        var body: Data
    }

    private func tryParseHTTPRequest(_ data: Data) -> HTTPRequest? {
        let separator = Data("\r\n\r\n".utf8)
        guard let headerEnd = data.range(of: separator) else { return nil }
        let headerData = data[..<headerEnd.lowerBound]
        guard let headerString = String(data: headerData, encoding: .utf8) else { return nil }
        let lines = headerString.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { return nil }
        let parts = requestLine.split(separator: " ", omittingEmptySubsequences: true)
        guard parts.count >= 2 else { return nil }

        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let val = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            headers[key] = val
        }

        // A negative or absurd length would trap in `subdata` (any local process could crash Swash)
        guard let contentLength = Int(headers["content-length"] ?? "0"),
              contentLength >= 0, contentLength <= Self.maximumBodySize else {
            return HTTPRequest(method: "INVALID", path: "", headers: headers, body: Data())
        }
        let bodyStart = headerEnd.upperBound
        guard data.count >= bodyStart + contentLength else { return nil }
        let body = data.subdata(in: bodyStart..<(bodyStart + contentLength))
        return HTTPRequest(method: String(parts[0]).uppercased(), path: String(parts[1]), headers: headers, body: body)
    }

    /// The largest request body accepted.
    nonisolated static let maximumBodySize = 4 * 1024 * 1024

    /// Whether a request may reach the tools. Web pages can send requests to 127.0.0.1 too, and the
    /// token is optional, so (as the MCP Streamable HTTP transport requires) a request that comes
    /// from a browser page on another origin, or names a host other than this machine (DNS
    /// rebinding), is refused. POSTs must be `application/json`, which a page on another origin
    /// can't send without a CORS preflight, and this server never answers one with CORS headers.
    nonisolated static func isAllowed(method: String, headers: [String: String], port: UInt16) -> Bool {
        let localHosts: Set<String> = ["127.0.0.1", "localhost", "[::1]"]
        func isLocal(host: String) -> Bool {
            let lower = host.lowercased()
            if localHosts.contains(lower) { return true }
            return localHosts.contains { lower == "\($0):\(port)" }
        }
        guard let host = headers["host"], isLocal(host: host) else { return false }
        if let origin = headers["origin"] {
            guard let originHost = URL(string: origin)?.host(percentEncoded: false),
                  ["127.0.0.1", "localhost", "::1"].contains(originHost.lowercased()) else { return false }
        }
        if method == "POST" {
            let type = headers["content-type"]?.split(separator: ";").first?
                .trimmingCharacters(in: .whitespaces).lowercased()
            guard type == "application/json" else { return false }
        }
        return true
    }

    private func processHTTPRequest(_ req: HTTPRequest, on connection: NWConnection) async {
        guard req.method != "INVALID" else {
            sendHTTPResponse(on: connection, status: "400 Bad Request", body: Data())
            return
        }
        guard Self.isAllowed(method: req.method, headers: req.headers, port: port) else {
            sendHTTPResponse(on: connection, status: "403 Forbidden", body: Data())
            return
        }

        // Check optional Bearer token
        if let expectedToken = token() {
            let auth = req.headers["authorization"] ?? ""
            if auth != "Bearer \(expectedToken)" {
                sendJSONResponse(
                    on: connection,
                    status: "401 Unauthorized",
                    json: ["jsonrpc": "2.0", "error": ["code": -32001, "message": "Unauthorized"]]
                )
                return
            }
        }

        let pathOnly = req.path.split(separator: "?", maxSplits: 1).first.map(String.init) ?? req.path
        guard pathOnly == "/mcp" || pathOnly == "/" else {
            sendHTTPResponse(on: connection, status: "404 Not Found", body: Data())
            return
        }

        switch req.method {
        case "OPTIONS":
            sendHTTPResponse(
                on: connection,
                status: "204 No Content",
                extraHeaders: ["Allow": "GET, POST, DELETE, OPTIONS"],
                body: Data()
            )

        case "GET":
            sendHTTPResponse(
                on: connection,
                status: "405 Method Not Allowed",
                extraHeaders: ["Allow": "POST, DELETE, OPTIONS"],
                body: Data()
            )

        case "DELETE":
            sendHTTPResponse(on: connection, status: "200 OK", body: Data())

        case "POST":
            guard let payload = try? JSONValue.parse(req.body),
                  let obj = payload.objectValue,
                  let method = obj["method"]?.stringValue else {
                sendJSONResponse(
                    on: connection,
                    status: "400 Bad Request",
                    json: ["jsonrpc": "2.0", "id": .null, "error": ["code": -32700, "message": "Invalid JSON-RPC request"]]
                )
                return
            }

            // Notifications have no "id" and expect 202 Accepted with empty body.
            guard let id = obj["id"], !id.isNull else {
                sendHTTPResponse(on: connection, status: "202 Accepted", body: Data())
                return
            }

            let params = obj["params"]?.objectValue
            let result = await onRequest(method, params)
            let responseObj: JSONObject
            switch result {
            case .success(let value):
                responseObj = ["jsonrpc": "2.0", "id": id, "result": .object(value)]
            case .failure(let code, let message):
                responseObj = ["jsonrpc": "2.0", "id": id, "error": ["code": .number(Double(code)), "message": .string(message)]]
            }

            let extra: [String: String] = method == "initialize" ? ["Mcp-Session-Id": sessionId] : [:]
            sendJSONResponse(on: connection, status: "200 OK", extraHeaders: extra, json: .object(responseObj))

        default:
            sendHTTPResponse(on: connection, status: "405 Method Not Allowed", body: Data())
        }
    }

    private func sendJSONResponse(
        on connection: NWConnection,
        status: String,
        extraHeaders: [String: String] = [:],
        json: JSONValue
    ) {
        let data = Data(json.stringified().utf8)
        var headers = extraHeaders
        headers["Content-Type"] = "application/json"
        sendHTTPResponse(on: connection, status: status, extraHeaders: headers, body: data)
    }

    private func sendHTTPResponse(
        on connection: NWConnection,
        status: String,
        extraHeaders: [String: String] = [:],
        body: Data
    ) {
        var headerLines = [
            "HTTP/1.1 \(status)",
            "Content-Length: \(body.count)",
            "Connection: close"
        ]
        for (k, v) in extraHeaders.sorted(by: { $0.key < $1.key }) {
            headerLines.append("\(k): \(v)")
        }
        var response = Data((headerLines.joined(separator: "\r\n") + "\r\n\r\n").utf8)
        response.append(body)

        connection.send(content: response, completion: .contentProcessed { _ in
            connection.cancel()
        })
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
        if attached() || WritingPartnerActiveVoice.shared.documentFlavor == nil {
            WritingPartnerActiveVoice.shared.documentFlavor = flavor
        }
    }
}
#endif

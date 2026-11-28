// Pixie's hands in a Swash document: the document's own agent tools (the registry MCP agents
// use) as a `PixieToolHost`. Every tool reaches her as it is, with no list kept here, and her calls
// run as her own agent, so her caret and name tag show where she reads and writes and each edit is
// one undo step.

import Foundation
import PixerateCore
import PixieKit

@MainActor
final class PixieSwashHost: PixieToolHost {
    let document: SwashPixieDocument

    private static let actor = ToolActor(id: Pixie.id, name: Pixie.name)

    init(document: SwashPixieDocument) {
        self.document = document
    }

    func listTools() -> [PixieToolDefinition] {
        document.registry.listTools().map { tool in
            PixieToolDefinition(
                name: tool.name,
                title: tool.title ?? tool.annotations?.title,
                description: tool.description,
                inputSchema: PixieJSON(tool.inputSchema),
                readOnly: tool.annotations?.readOnlyHint == true,
                destructive: tool.annotations?.destructiveHint == true
            )
        }
    }

    func callTool(_ name: String, arguments: [String: PixieJSON]) async throws -> PixieToolResult {
        var args = JSONObject()
        for key in arguments.keys.sorted() { args[key] = JSONValue(arguments[key]!) }
        let result = await document.registry.callTool(name, args, actor: Self.actor)
        return PixieToolResult(
            content: result.content.map { part in
                switch part {
                case .text(let text): .text(text)
                case .image(let data, let mimeType): .image(data: data, mimeType: mimeType)
                case .other(let object): .text(PixieJSON(.object(object)).encoded())
                }
            },
            structuredContent: result.structuredContent.map { PixieJSON(.object($0)) },
            isError: result.isError
        )
    }

    func toolsets() -> [PixieToolset] {
        document.registry.toolsets().map { PixieToolset(name: $0.name, title: $0.title, description: $0.description) }
    }

    /**
     * What she is working on, read fresh for every step: the document's name, flavour and size, and
     * the person's selection (where it is, and up to `selectionExcerpt` characters of it). She reads
     * the rest with the document's tools when she needs it.
     */
    func brief() -> PixieJSON {
        let text = document.markdown() as NSString
        var brief: [String: PixieJSON] = [
            "app": "Swash",
            "name": .string(document.name()),
            "flavor": .string(document.flavor()),
            "characters": .number(Double(text.length)),
            "words": .number(Double((text as String).split(whereSeparator: \.isWhitespace).count)),
            "readOnly": .bool(document.readOnlyReason() != nil),
        ]
        if let selection = document.selection(), selection.location != NSNotFound,
            NSMaxRange(selection) <= text.length
        {
            var selected: [String: PixieJSON] = [
                "from": .number(Double(selection.location)),
                "to": .number(Double(NSMaxRange(selection))),
            ]
            if selection.length > 0 {
                let excerpt = text.substring(with: NSRange(location: selection.location, length: min(selection.length, Self.selectionExcerpt)))
                selected["text"] = .string(excerpt)
                if selection.length > Self.selectionExcerpt { selected["truncated"] = true }
            }
            brief["selection"] = .object(selected)
        }
        return .object(brief)
    }

    /// How much of a selection the brief carries; she reads longer ones with the tools.
    static let selectionExcerpt = 600
}

extension PixieJSON {
    /// From the editor's JSON (which keeps JavaScript's key order; Pixie's doesn't need it).
    nonisolated init(_ value: JSONValue) {
        switch value {
        case .null: self = .null
        case .bool(let b): self = .bool(b)
        case .number(let n): self = .number(n)
        case .string(let s): self = .string(s)
        case .array(let items): self = .array(items.map(PixieJSON.init))
        case .object(let object):
            var dict: [String: PixieJSON] = [:]
            for key in object.keys { dict[key] = PixieJSON(object[key]!) }
            self = .object(dict)
        }
    }
}

extension JSONValue {
    nonisolated init(_ value: PixieJSON) {
        switch value {
        case .null: self = .null
        case .bool(let b): self = .bool(b)
        case .number(let n): self = .number(n)
        case .string(let s): self = .string(s)
        case .array(let items): self = .array(items.map(JSONValue.init))
        case .object(let dict):
            var object = JSONObject()
            for key in dict.keys.sorted() { object[key] = JSONValue(dict[key]!) }
            self = .object(object)
        }
    }
}

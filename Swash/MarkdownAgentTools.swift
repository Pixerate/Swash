//
//  MarkdownAgentTools.swift
//  Swash
//
//  Agent tools for one Markdown document (#49), with the names and argument schemas of the
//  Pixerate web editor's rich-text tools (`createRichTextToolProvider` and
//  `createDocumentFormatTools` in @pixerate/editor), so an agent and the `pixerate-rich-text`
//  skills use either editor the same way. Positions are UTF-16 offsets into the raw Markdown
//  (GOTCHAS #9), not the web editor's ProseMirror positions. Every write is one undo step.
//
//  Foundation, PixerateCore and PixerateMarkdown only, so scripts/run_agent_tools_tests.sh can
//  compile it without the app. `AgentBridge.swift` connects it to `pixerate-mcp-bridge`.
//

#if os(macOS)
import Foundation
import PixerateCore
import PixerateMarkdown

/// The document the tools read and edit.
@MainActor
protocol MarkdownToolTarget: AnyObject {
    /// The raw Markdown.
    var markdown: String { get }
    /// The selection, in raw-Markdown UTF-16 offsets.
    var selection: NSRange { get }
    /// Why the document can't be edited, or nil when it can.
    var readOnlyReason: String? { get }
    /// Replaces the whole Markdown as one undoable edit, then selects `selection`.
    func apply(markdown: String, selection: NSRange, actionName: String)
    /// Moves the selection.
    func select(_ range: NSRange)
}

/// A tool failure, reported to the agent as an `isError` result with this message.
struct MarkdownToolError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

/// Builds the tool provider for one document.
@MainActor
final class MarkdownToolProvider {
    /// The skill that documents the tools.
    static let skill = "pixerate-rich-text"
    /// Characters of context `find_text` returns around a match.
    static let contextCharacters = 30
    /// Matches `find_text` and `replace_text` consider at most.
    static let searchLimit = 10_000

    private weak var target: MarkdownToolTarget?

    init(target: MarkdownToolTarget) {
        self.target = target
    }

    /// The provider. `subscribe` is called with a function to call when the tool list may have
    /// changed (the document became read-only or editable).
    func provider(id: String = "document", namespace: String = "", subscribe: ((@escaping () -> Void) -> Cancellable)? = nil) -> AgentToolProvider {
        let reads = [getText, findText]
        let writes = [insertText, replaceText, replaceRange, replaceSelection, setSelection, formatText, setBlockType]
        return AgentToolProvider(
            id: id,
            namespace: namespace,
            title: "Document",
            description: "A Markdown document in Swash: read and find text, insert, replace and format it. Positions are UTF-16 offsets into the Markdown source.",
            skill: Self.skill,
            // As in the web editor, a read-only document lists only its read tools.
            tools: { [weak self] in
                guard let target = self?.target else { return [] }
                return target.readOnlyReason == nil ? reads + writes : reads
            },
            subscribe: subscribe
        )
    }

    // MARK: - Helpers

    private func document() throws -> MarkdownToolTarget {
        guard let target else { throw MarkdownToolError("The document has closed.") }
        return target
    }

    private func editable() throws -> MarkdownToolTarget {
        let target = try document()
        if let reason = target.readOnlyReason {
            throw MarkdownToolError("The document is read-only (\(reason)), so it cannot be edited.")
        }
        return target
    }

    /// A handler that runs `body` on the main actor (where the bridge client calls the registry
    /// from) and returns its JSON.
    private static func handler(_ body: @escaping @MainActor (JSONObject) throws -> JSONObject) -> AgentToolHandler {
        { args, _ in
            .value(.object(try body(args)))
        }
    }

    private static func int(_ args: JSONObject, _ key: String) -> Int? {
        args[key]?.numberValue.map { Int($0) }
    }

    private static func range(_ r: NSRange) -> JSONValue {
        ["from": .number(Double(r.location)), "to": .number(Double(NSMaxRange(r)))]
    }

    private static func selectionInfo(_ text: NSString, _ selection: NSRange) -> JSONValue {
        let clamped = clamp(selection, text.length)
        return ["from": .number(Double(clamped.location)), "to": .number(Double(NSMaxRange(clamped))), "text": .string(text.substring(with: clamped))]
    }

    private static func clamp(_ r: NSRange, _ length: Int) -> NSRange {
        let start = min(max(0, r.location), length)
        return NSRange(location: start, length: min(max(0, r.length), length - start))
    }

    /// Throws unless `from..to` is an ordered range inside a document of `size`.
    private static func checkRange(_ from: Int, _ to: Int, size: Int) throws {
        if from > to { throw MarkdownToolError("\"from\" (\(from)) must not be after \"to\" (\(to)).") }
        if to > size { throw MarkdownToolError("Position \(to) is outside the document (size \(size)).") }
    }

    /// The range a tool acts on: `from..to`, or the selection when both are omitted.
    private static func targetRange(_ args: JSONObject, _ target: MarkdownToolTarget, size: Int, allowEmpty: Bool) throws -> NSRange {
        let from = int(args, "from"), to = int(args, "to")
        if (from == nil) != (to == nil) { throw MarkdownToolError("Pass both \"from\" and \"to\", or neither to use the selection.") }
        let range: NSRange
        if let from, let to {
            try checkRange(from, to, size: size)
            range = NSRange(location: from, length: to - from)
        } else {
            range = clamp(target.selection, size)
        }
        if !allowEmpty && range.length == 0 {
            throw MarkdownToolError("The range is empty: pass \"from\" and \"to\" around the text (find_text returns them), or select it first.")
        }
        return range
    }

    /// `position` after replacing each of `edits` (ascending, non-overlapping) with text of
    /// `newLength`. Positions inside a replaced range move to the end of its replacement, and
    /// positions at an insertion move after it (as ProseMirror maps a selection).
    static func map(_ position: Int, through edits: [(range: NSRange, newLength: Int)]) -> Int {
        var delta = 0
        for edit in edits {
            if position < edit.range.location || (position == edit.range.location && edit.range.length > 0) { break }
            if position < NSMaxRange(edit.range) { return edit.range.location + delta + edit.newLength }
            delta += edit.newLength - edit.range.length
        }
        return position + delta
    }

    /// The single changed span between two texts (common prefix and suffix removed), as an edit.
    static func change(from old: NSString, to new: NSString) -> (range: NSRange, newLength: Int) {
        let minLength = min(old.length, new.length)
        var prefix = 0
        while prefix < minLength && old.character(at: prefix) == new.character(at: prefix) { prefix += 1 }
        var suffix = 0
        while suffix < minLength - prefix && old.character(at: old.length - 1 - suffix) == new.character(at: new.length - 1 - suffix) { suffix += 1 }
        return (NSRange(location: prefix, length: old.length - prefix - suffix), new.length - prefix - suffix)
    }

    /// `selection` moved through an edit from `old` to `new`.
    static func mapSelection(_ selection: NSRange, from old: NSString, to new: NSString) -> NSRange {
        let edit = [change(from: old, to: new)]
        let start = map(selection.location, through: edit)
        let end = max(start, map(NSMaxRange(selection), through: edit))
        return NSRange(location: start, length: end - start)
    }

    // MARK: - Search

    /// Ranges of `query` in `text` (literal unless `regex`), skipping empty matches.
    static func search(_ text: NSString, _ query: String, _ args: JSONObject) throws -> (matches: [NSRange], truncated: Bool) {
        let isRegex = args["regex"]?.boolValue == true
        var pattern = isRegex ? query : NSRegularExpression.escapedPattern(for: query)
        if args["wholeWord"]?.boolValue == true {
            pattern = "(?<![\\p{L}\\p{N}_])(?:" + pattern + ")(?![\\p{L}\\p{N}_])"
        }
        let expression: NSRegularExpression
        do {
            expression = try NSRegularExpression(pattern: pattern, options: args["matchCase"]?.boolValue == true ? [] : [.caseInsensitive])
        } catch {
            throw MarkdownToolError("Invalid search pattern: \(query)")
        }
        var matches: [NSRange] = []
        var truncated = false
        expression.enumerateMatches(in: text as String, range: NSRange(location: 0, length: text.length)) { result, _, stop in
            guard let r = result?.range, r.length > 0 else { return }
            if matches.count == searchLimit {
                truncated = true
                stop.pointee = true
                return
            }
            matches.append(r)
        }
        return (matches, truncated)
    }

    // MARK: - Blocks

    /// The leaf blocks of `text` (paragraphs, headings, code blocks, table cells…) with their
    /// source ranges, as `get_text {blocks: true}` returns them.
    static func blocks(in text: String, overlapping range: NSRange? = nil) -> [JSONValue] {
        let ns = text as NSString
        let document = MarkdownDocument.parse(text)
        var out: [JSONValue] = []
        func visit(_ node: MarkdownNode) {
            let type: String
            var extra = JSONObject()
            switch node.kind {
            case .paragraph: type = "paragraph"
            case .heading(let level, _):
                type = "heading"
                extra["level"] = .number(Double(level))
            case .codeBlock(_, let info):
                type = "codeBlock"
                if !info.isEmpty { extra["language"] = .string(info) }
            case .htmlBlock: type = "htmlBlock"
            case .frontMatter: type = "frontMatter"
            case .tableCell(_, let isHeader): type = isHeader ? "tableHeader" : "tableCell"
            default:
                for child in node.children where child.kind.isBlock { visit(child) }
                return
            }
            let r = clamp(node.range, ns.length)
            if let range {
                let end = max(NSMaxRange(range), range.location)
                guard r.location <= end, NSMaxRange(r) >= range.location else { return }
            }
            var block: JSONObject = ["type": .string(type), "from": .number(Double(r.location)), "to": .number(Double(NSMaxRange(r))), "text": .string(ns.substring(with: r))]
            for (key, value) in extra { block[key] = value }
            for ancestor in node.ancestors {
                if case .listItem(let task) = ancestor.kind, let task {
                    block["checked"] = .bool(task == .checked)
                }
                var wrapper: String?
                switch ancestor.kind {
                case .list(let ordered, _, _, _, _):
                    let isTask = ancestor.children.contains { if case .listItem(let t) = $0.kind { return t != nil }; return false }
                    wrapper = isTask ? "taskList" : ordered ? "orderedList" : "bulletList"
                case .blockQuote, .alert: wrapper = "blockquote"
                default: break
                }
                if let wrapper {
                    block["in"] = .string(wrapper)
                    break
                }
            }
            out.append(.object(block))
        }
        visit(document.root)
        return out
    }

    // MARK: - Read tools

    private lazy var getText = AgentTool(
        name: "get_text",
        title: "Get document text",
        description: "Returns the document content (the Markdown source by default, or plain text / HTML), the current selection and the document size. " +
            "Positions are UTF-16 offsets into the Markdown source: pass `blocks: true` to get every paragraph, heading and cell with the positions " +
            "its source spans, or use find_text to get the positions of a phrase.",
        inputSchema: [
            "type": "object",
            "properties": [
                "format": ["type": "string", "enum": ["text", "html", "markdown"], "description": "Content format (default: markdown, which positions index)."],
                "blocks": ["type": "boolean", "description": "Also return `blocks`: each paragraph/heading/cell as {type, from, to, text} (default false)."],
            ],
            "additionalProperties": false,
        ],
        annotations: ToolAnnotations(title: "Get document text", readOnlyHint: true, destructiveHint: false, idempotentHint: true, openWorldHint: false),
        handler: Self.handler { [unowned self] args in
            let target = try self.document()
            let text = target.markdown
            let format = args["format"]?.stringValue ?? "markdown"
            let content: String
            switch format {
            case "html": content = MarkdownHTMLRenderer.render(MarkdownDocument.parse(text))
            case "text": content = Self.plainText(text)
            default: content = text
            }
            let ns = text as NSString
            var result: JSONObject = ["format": .string(format), "content": .string(content), "selection": Self.selectionInfo(ns, target.selection), "size": .number(Double(ns.length))]
            if let reason = target.readOnlyReason {
                result["readOnly"] = .string(reason)
            }
            if args["blocks"]?.boolValue == true { result["blocks"] = .array(Self.blocks(in: text)) }
            return result
        }
    )

    /// The text of the leaf blocks without Markdown syntax, one block per line.
    static func plainText(_ text: String) -> String {
        var lines: [String] = []
        func visit(_ node: MarkdownNode) {
            switch node.kind {
            case .paragraph, .heading, .tableCell: lines.append(node.plainText)
            case .codeBlock, .htmlBlock: lines.append(node.literal.hasSuffix("\n") ? String(node.literal.dropLast()) : node.literal)
            case .frontMatter, .linkReferenceDefinition, .thematicBreak: break
            default: for child in node.children where child.kind.isBlock { visit(child) }
            }
        }
        visit(MarkdownDocument.parse(text).root)
        return lines.joined(separator: "\n")
    }

    private static let findProperties: JSONObject = [
        "matchCase": ["type": "boolean", "description": "Case-sensitive match (default false)."],
        "wholeWord": ["type": "boolean", "description": "Match whole words only (default false)."],
        "regex": ["type": "boolean", "description": "Treat the query as a regular expression (default false: literal text)."],
    ]

    private lazy var findText: AgentTool = {
        var properties: JSONObject = ["query": ["type": "string", "minLength": 1, "description": "Text (or regex) to find."]]
        for (key, value) in Self.findProperties { properties[key] = value }
        properties["maxResults"] = ["type": "integer", "minimum": 1, "maximum": 500, "description": "Matches returned (default 50)."]
        return AgentTool(
            name: "find_text",
            title: "Find text",
            description: "Finds a phrase (literal by default) in the Markdown source and returns each match with its positions {from, to}, " +
                "ready for replace_range, insert_text `at` or set_selection, plus surrounding context.",
            inputSchema: ["type": "object", "properties": .object(properties), "required": ["query"], "additionalProperties": false],
            annotations: ToolAnnotations(title: "Find text", readOnlyHint: true, destructiveHint: false, idempotentHint: true, openWorldHint: false),
            handler: Self.handler { [unowned self] args in
                let ns = try self.document().markdown as NSString
                let (matches, truncated) = try Self.search(ns, args["query"]?.stringValue ?? "", args)
                let maxResults = Self.int(args, "maxResults") ?? 50
                let context = Self.contextCharacters
                return [
                    "total": .number(Double(matches.count)),
                    "truncated": .bool(truncated || matches.count > maxResults),
                    "matches": .array(matches.prefix(maxResults).map { m in
                        let before = max(0, m.location - context)
                        let after = min(ns.length, NSMaxRange(m) + context)
                        return [
                            "from": .number(Double(m.location)),
                            "to": .number(Double(NSMaxRange(m))),
                            "text": .string(ns.substring(with: m)),
                            "before": .string(ns.substring(with: NSRange(location: before, length: m.location - before))),
                            "after": .string(ns.substring(with: NSRange(location: NSMaxRange(m), length: after - NSMaxRange(m)))),
                        ]
                    }),
                ]
            }
        )
    }()

    // MARK: - Write tools

    /// Replaces `range` with `text`; returns the inserted range and the selection after.
    private func write(_ target: MarkdownToolTarget, _ range: NSRange, _ text: String, actionName: String, selectInserted: Bool) -> (range: NSRange, selection: NSRange, text: NSString) {
        let old = target.markdown as NSString
        let new = old.replacingCharacters(in: range, with: text) as NSString
        let length = (text as NSString).length
        let inserted = NSRange(location: range.location, length: length)
        let selection = selectInserted
            ? NSRange(location: NSMaxRange(inserted), length: 0)
            : Self.mapSelection(target.selection, through: [(range, length)])
        target.apply(markdown: new as String, selection: selection, actionName: actionName)
        return (inserted, selection, new)
    }

    private static func mapSelection(_ selection: NSRange, through edits: [(range: NSRange, newLength: Int)]) -> NSRange {
        let start = map(selection.location, through: edits)
        let end = max(start, map(NSMaxRange(selection), through: edits))
        return NSRange(location: start, length: end - start)
    }

    private lazy var insertText = AgentTool(
        name: "insert_text",
        title: "Insert text",
        description: "Inserts literal Markdown text at a position, or at the cursor when `at` is omitted (replacing any selected text). " +
            "Returns the inserted `range` {from, to}.",
        inputSchema: [
            "type": "object",
            "properties": [
                "text": ["type": "string", "description": "Text to insert."],
                "at": ["type": "integer", "minimum": 0, "description": "Position (default: the selection)."],
            ],
            "required": ["text"],
            "additionalProperties": false,
        ],
        annotations: ToolAnnotations(title: "Insert text", readOnlyHint: false, destructiveHint: false, idempotentHint: false, openWorldHint: false),
        handler: Self.handler { [unowned self] args in
            let target = try self.editable()
            let text = args["text"]?.stringValue ?? ""
            let size = (target.markdown as NSString).length
            let range: NSRange
            if let at = Self.int(args, "at") {
                if at > size { throw MarkdownToolError("Position \(at) is outside the document (size \(size)).") }
                range = NSRange(location: at, length: 0)
            } else {
                range = Self.clamp(target.selection, size)
            }
            let result = self.write(target, range, text, actionName: "Insert Text", selectInserted: Self.int(args, "at") == nil)
            return ["inserted": .number(Double((text as NSString).length)), "range": Self.range(result.range), "selection": Self.selectionInfo(result.text, result.selection)]
        }
    )

    private lazy var replaceText: AgentTool = {
        var properties: JSONObject = [
            "find": ["type": "string", "minLength": 1, "description": "Text (or regex) to find."],
            "replace": ["type": "string", "description": "Replacement text (literal; an empty string deletes the matches)."],
        ]
        for (key, value) in Self.findProperties { properties[key] = value }
        properties["occurrence"] = ["type": "integer", "minimum": 1, "description": "Only replace the n-th match (1-based, in document order). Default: all matches."]
        return AgentTool(
            name: "replace_text",
            title: "Find and replace",
            description: "Replaces occurrences of a phrase in the Markdown source with literal text in one undoable step. " +
                "Replaces every occurrence by default, or only the n-th with `occurrence`. Fails when nothing matches.",
            inputSchema: ["type": "object", "properties": .object(properties), "required": ["find", "replace"], "additionalProperties": false],
            annotations: ToolAnnotations(title: "Find and replace", readOnlyHint: false, destructiveHint: true, idempotentHint: false, openWorldHint: false),
            handler: Self.handler { [unowned self] args in
                let target = try self.editable()
                let find = args["find"]?.stringValue ?? ""
                let replace = (args["replace"]?.stringValue ?? "").replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
                let old = target.markdown as NSString
                let (matches, _) = try Self.search(old, find, args)
                if matches.isEmpty { throw MarkdownToolError("No match for \(JSONValue.string(find).stringified()).") }
                let chosen: [NSRange]
                if let occurrence = Self.int(args, "occurrence") {
                    if occurrence > matches.count {
                        throw MarkdownToolError("Occurrence \(occurrence) requested, but there are only \(matches.count) matches.")
                    }
                    chosen = [matches[occurrence - 1]]
                } else {
                    chosen = matches
                }
                let length = (replace as NSString).length
                let new = NSMutableString(string: old)
                for r in chosen.reversed() { new.replaceCharacters(in: r, with: replace) }
                let edits = chosen.map { (range: $0, newLength: length) }
                var shift = 0
                let ranges: [JSONValue] = chosen.map { r in
                    defer { shift += length - r.length }
                    return Self.range(NSRange(location: r.location + shift, length: length))
                }
                let selection = Self.mapSelection(target.selection, through: edits)
                target.apply(markdown: new as String, selection: selection, actionName: "Replace")
                return ["replaced": .number(Double(chosen.count)), "total": .number(Double(matches.count)), "ranges": .array(ranges), "selection": Self.selectionInfo(new, selection)]
            }
        )
    }()

    private lazy var replaceRange = AgentTool(
        name: "replace_range",
        title: "Replace a range",
        description: "Replaces the Markdown source between two positions (from get_text `blocks` or find_text) with literal text. " +
            "from === to inserts; an empty text deletes. Returns the new text's `range` {from, to}.",
        inputSchema: [
            "type": "object",
            "properties": [
                "from": ["type": "integer", "minimum": 0, "description": "Start position."],
                "to": ["type": "integer", "minimum": 0, "description": "End position."],
                "text": ["type": "string", "description": "Replacement text (Markdown)."],
            ],
            "required": ["from", "to", "text"],
            "additionalProperties": false,
        ],
        annotations: ToolAnnotations(title: "Replace a range", readOnlyHint: false, destructiveHint: true, idempotentHint: false, openWorldHint: false),
        handler: Self.handler { [unowned self] args in
            let target = try self.editable()
            let from = Self.int(args, "from") ?? 0, to = Self.int(args, "to") ?? 0
            try Self.checkRange(from, to, size: (target.markdown as NSString).length)
            let result = self.write(target, NSRange(location: from, length: to - from), args["text"]?.stringValue ?? "", actionName: "Replace", selectInserted: false)
            return [
                "replaced": ["from": .number(Double(from)), "to": .number(Double(to))],
                "range": Self.range(result.range),
                "selection": Self.selectionInfo(result.text, result.selection),
                "size": .number(Double(result.text.length)),
            ]
        }
    )

    private lazy var replaceSelection = AgentTool(
        name: "replace_selection",
        title: "Replace selection",
        description: "Replaces the selected text with literal text (an empty string deletes the selection). Returns the new text's `range` {from, to}.",
        inputSchema: [
            "type": "object",
            "properties": ["text": ["type": "string", "description": "Replacement text."]],
            "required": ["text"],
            "additionalProperties": false,
        ],
        annotations: ToolAnnotations(title: "Replace selection", readOnlyHint: false, destructiveHint: true, idempotentHint: false, openWorldHint: false),
        handler: Self.handler { [unowned self] args in
            let target = try self.editable()
            let selection = Self.clamp(target.selection, (target.markdown as NSString).length)
            let result = self.write(target, selection, args["text"]?.stringValue ?? "", actionName: "Replace", selectInserted: true)
            return ["replaced": Self.range(selection), "range": Self.range(result.range), "selection": Self.selectionInfo(result.text, result.selection)]
        }
    )

    private lazy var setSelection = AgentTool(
        name: "set_selection",
        title: "Set the selection",
        description: "Selects the Markdown source between two positions (from === to places the cursor).",
        inputSchema: [
            "type": "object",
            "properties": [
                "from": ["type": "integer", "minimum": 0, "description": "Start position."],
                "to": ["type": "integer", "minimum": 0, "description": "End position (default: from)."],
            ],
            "required": ["from"],
            "additionalProperties": false,
        ],
        annotations: ToolAnnotations(title: "Set the selection", readOnlyHint: false, destructiveHint: false, idempotentHint: true, openWorldHint: false),
        handler: Self.handler { [unowned self] args in
            let target = try self.editable()
            let from = Self.int(args, "from") ?? 0
            let to = Self.int(args, "to") ?? from
            let ns = target.markdown as NSString
            try Self.checkRange(from, to, size: ns.length)
            let range = NSRange(location: from, length: to - from)
            target.select(range)
            return ["selection": Self.selectionInfo(ns, range)]
        }
    )

    // MARK: - Formatting tools

    private static let rangeProperties: JSONObject = [
        "from": ["type": "integer", "minimum": 0, "description": "Start position (from find_text or get_text `blocks`). Default: the selection."],
        "to": ["type": "integer", "minimum": 0, "description": "End position. Default: the selection."],
    ]

    /// The inline formats Markdown has, by `format_text` argument.
    private static let inlineFormats: [(arg: String, format: MarkdownInlineFormat, command: FormatCommand, what: String)] = [
        ("bold", .strong, .bold, "Bold (strong) text."),
        ("italic", .emphasis, .italic, "Italic (emphasis)."),
        ("strike", .strikethrough, .strikethrough, "Struck-through text."),
        ("code", .code, .code, "Inline code."),
    ]

    private static let unsafeLink = try! NSRegularExpression(pattern: "^\\s*(javascript|data|vbscript):", options: [.caseInsensitive])

    /// Which inline formats are on a range: `true` on all of its text, `"partly"` on some.
    static func formattingInfo(_ text: String, _ range: NSRange) -> JSONObject {
        let formatting = MarkdownFormatting(text: text)
        var out = JSONObject()
        for entry in inlineFormats {
            if formatting.isActive(entry.format, selection: range) {
                out[entry.arg] = true
                continue
            }
            var any = false
            formatting.document.root.walk { node in
                if !any, entry.format.matches(node.kind), NSIntersectionRange(node.range, range).length > 0 { any = true }
            }
            if any { out[entry.arg] = "partly" }
        }
        if let link = formatting.link(at: range), case .link(let destination, _, _) = link.kind {
            out["link"] = .string(destination)
        }
        return out
    }

    private lazy var formatText: AgentTool = {
        var properties = Self.rangeProperties
        for entry in Self.inlineFormats {
            properties[entry.arg] = ["type": "boolean", "description": .string("\(entry.what) true sets it, false clears it; omit to leave it.")]
        }
        properties["link"] = ["type": ["string", "null"], "minLength": 1, "description": "Link the text to this URL (https://…, mailto:…), or null to remove links. Omit to leave links."]
        let names = Self.inlineFormats.map(\.arg) + ["link"]
        return AgentTool(
            name: "format_text",
            title: "Format text",
            description: "Sets or clears inline formatting on a range of text (or the selection): \(names.joined(separator: ", ")). " +
                "Only the properties you pass change. Positions come from find_text or get_text `blocks`. One undo step; the selection is left where it was. " +
                "Returns the `range` and the formatting now on it (`partly` where only some of the text has it). For headings and lists use set_block_type.",
            inputSchema: ["type": "object", "properties": .object(properties), "additionalProperties": false],
            annotations: ToolAnnotations(title: "Format text", readOnlyHint: false, destructiveHint: false, idempotentHint: true, openWorldHint: false),
            handler: Self.handler { [unowned self] args in
                let target = try self.editable()
                guard names.contains(where: { args[$0] != nil }) else {
                    throw MarkdownToolError("Pass at least one formatting property: \(names.joined(separator: ", ")).")
                }
                let original = target.markdown
                var range = try Self.targetRange(args, target, size: (original as NSString).length, allowEmpty: false)
                if let link = args["link"]?.stringValue,
                   Self.unsafeLink.firstMatch(in: link, range: NSRange(location: 0, length: (link as NSString).length)) != nil {
                    throw MarkdownToolError("Links may not use javascript:, data: or vbscript: URLs. Nothing was changed.")
                }
                var text = original
                for entry in Self.inlineFormats {
                    guard let wanted = args[entry.arg]?.boolValue else { continue }
                    let formatting = MarkdownFormatting(text: text)
                    if formatting.isActive(entry.format, selection: range) == wanted { continue }
                    guard formatting.isEnabled(entry.command, selection: range), let edit = formatting.toggle(entry.format, selection: range) else {
                        throw MarkdownToolError("That text cannot be made \(entry.arg) here (for example inside a code block). Nothing was changed.")
                    }
                    text = edit.text
                    range = edit.selection
                }
                if let link = args["link"] {
                    let url = link.stringValue?.trimmingCharacters(in: .whitespaces)
                    if url != nil || MarkdownFormatting(text: text).link(at: range) != nil {
                        guard let edit = FormatCommandEdits.link(url, text: text, selection: range) else {
                            throw MarkdownToolError("That text cannot be linked here (for example inside a code block). Nothing was changed.")
                        }
                        text = edit.text
                        range = edit.selection
                    }
                }
                if text != original {
                    target.apply(markdown: text, selection: Self.mapSelection(target.selection, from: original as NSString, to: text as NSString), actionName: "Format")
                }
                let ns = text as NSString
                return ["range": Self.range(range), "text": .string(ns.substring(with: range)), "formatting": .object(Self.formattingInfo(text, range))]
            }
        )
    }()

    /// Block types by `set_block_type` value.
    private static let blockTypes: [(value: String, what: String)] = [
        ("paragraph", "a plain paragraph (also takes the blocks out of lists, quotes and code blocks)"),
        ("heading", "a heading of `level`"),
        ("bullet_list", "items of a bulleted list"),
        ("ordered_list", "items of a numbered list"),
        ("task_list", "items of a checklist"),
        ("blockquote", "a quote"),
        ("code_block", "a fenced code block"),
    ]

    /// Applies `edit` (when there is one) to `text` and `range`.
    private static func step(_ text: inout String, _ range: inout NSRange, _ edit: MarkdownEdit?) {
        guard let edit else { return }
        text = edit.text
        range = edit.selection
    }

    /// Takes the lines of `range` out of code blocks and quotes and makes them paragraphs.
    private static func clearBlocks(_ text: inout String, _ range: inout NSRange) {
        if MarkdownFormatting(text: text).codeBlock(containing: range) != nil {
            step(&text, &range, FormatCommandEdits.edit(for: .codeBlock, text: text, selection: range))
        }
        for _ in 0..<8 where MarkdownFormatting(text: text).isQuoted(selection: range) {
            step(&text, &range, MarkdownFormatting(text: text).toggleBlock(.quote, selection: range))
        }
        let formatting = MarkdownFormatting(text: text)
        if formatting.activeBlockFormat(selection: range) != .paragraph {
            step(&text, &range, formatting.toggleBlock(.paragraph, selection: range))
        }
    }

    private lazy var setBlockType: AgentTool = {
        var properties = Self.rangeProperties
        properties["type"] = ["type": "string", "enum": .array(Self.blockTypes.map { .string($0.value) }), "description": "What the blocks become."]
        properties["level"] = ["type": "integer", "enum": [1, 2, 3, 4, 5, 6], "description": "Heading level for type \"heading\" (1, 2, 3, 4, 5, 6; 1 is the largest)."]
        return AgentTool(
            name: "set_block_type",
            title: "Set the block type",
            description: "Turns every line the range touches (or the one at the cursor) into " +
                Self.blockTypes.map { "\($0.value) (\($0.what))" }.joined(separator: ", ") +
                ". The lines are first taken out of any list, quote or code block, so one call switches between kinds. One undo step; the selection is left where it was. " +
                "Returns the resulting `blocks` with their type, positions, source, level and the list or quote they are in.",
            inputSchema: ["type": "object", "properties": .object(properties), "required": ["type"], "additionalProperties": false],
            annotations: ToolAnnotations(title: "Set the block type", readOnlyHint: false, destructiveHint: false, idempotentHint: true, openWorldHint: false),
            handler: Self.handler { [unowned self] args in
                let target = try self.editable()
                let type = args["type"]?.stringValue ?? ""
                let level = Self.int(args, "level")
                if type == "heading" && level == nil { throw MarkdownToolError("Pass a heading \"level\" (1, 2, 3, 4, 5, 6).") }
                if type != "heading" && level != nil { throw MarkdownToolError("\"level\" only applies to type \"heading\".") }
                let original = target.markdown
                var range = try Self.targetRange(args, target, size: (original as NSString).length, allowEmpty: true)
                var text = original
                let formatting = MarkdownFormatting(text: text)
                if formatting.isInTable(range) {
                    throw MarkdownToolError("Those lines cannot become \(type) here (they are in a table). Nothing was changed.")
                }
                let block: MarkdownBlockFormat? = switch type {
                case "heading": .heading(level ?? 1)
                case "bullet_list": .bulletList
                case "ordered_list": .numberedList
                case "task_list": .taskList
                default: nil
                }
                let alreadyCode = type == "code_block" && formatting.codeBlock(containing: range) != nil
                let alreadyThere = block.map { formatting.activeBlockFormat(selection: range) == $0 && !formatting.isQuoted(selection: range) && formatting.codeBlock(containing: range) == nil } ?? false
                if !alreadyCode && !alreadyThere {
                    Self.clearBlocks(&text, &range)
                    switch type {
                    case "blockquote":
                        Self.step(&text, &range, MarkdownFormatting(text: text).toggleBlock(.quote, selection: range))
                    case "code_block":
                        guard let edit = FormatCommandEdits.codeBlock(language: nil, text: text, selection: range) else {
                            throw MarkdownToolError("Those lines cannot become a code block here. Nothing was changed.")
                        }
                        Self.step(&text, &range, edit)
                    default:
                        if let block { Self.step(&text, &range, MarkdownFormatting(text: text).toggleBlock(block, selection: range)) }
                    }
                }
                if text != original {
                    target.apply(markdown: text, selection: Self.mapSelection(target.selection, from: original as NSString, to: text as NSString), actionName: "Block Type")
                }
                return ["type": .string(type), "range": Self.range(range), "blocks": .array(Self.blocks(in: text, overlapping: range))]
            }
        )
    }()
}
#endif

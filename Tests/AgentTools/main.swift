// Calls each agent tool (Swash/MarkdownAgentTools.swift) through a PixerateCore ToolRegistry, as
// the MCP bridge does, with valid and invalid arguments. Run with scripts/run_agent_tools_tests.sh.

import Foundation
import PixerateCore
import PixerateMarkdown

@MainActor
final class FakeDocument: MarkdownToolTarget {
    var markdown: String
    var selection: NSRange
    var readOnlyReason: String?
    var flavor: MarkdownFlavor
    /// Every edit, as the editor's undo stack would record it.
    var edits: [(text: String, actionName: String)] = []

    init(_ markdown: String, selection: NSRange = NSRange(location: 0, length: 0), flavor: MarkdownFlavor = .github) {
        self.markdown = markdown
        self.selection = selection
        self.flavor = flavor
    }

    func apply(markdown: String, selection: NSRange, actionName: String) {
        edits.append((markdown, actionName))
        self.markdown = markdown
        self.selection = selection
    }

    func select(_ range: NSRange) { selection = range }
}

var failures = 0
var checks = 0

func check(_ condition: Bool, _ message: String, file: StaticString = #file, line: UInt = #line) {
    checks += 1
    if !condition {
        failures += 1
        print("FAIL (line \(line)): \(message)")
    }
}

func expectEqual<T: Equatable>(_ actual: T, _ expected: T, _ message: String, line: UInt = #line) {
    check(actual == expected, "\(message): expected \(expected), got \(actual)", line: line)
}

struct Harness {
    let document: FakeDocument
    let registry: ToolRegistry
    let notify: () -> Void

    @MainActor
    init(_ markdown: String, selection: NSRange = NSRange(location: 0, length: 0), flavor: MarkdownFlavor = .github) {
        document = FakeDocument(markdown, selection: selection, flavor: flavor)
        registry = ToolRegistry()
        var listener: (() -> Void)?
        let tools = MarkdownToolProvider(target: document)
        _ = try! registry.register(tools.provider(subscribe: { fn in
            listener = fn
            return Cancellable { listener = nil }
        }))
        notify = { listener?() }
        // Keep the provider alive for the registry's lifetime
        Harness.keep.append(tools)
    }

    @MainActor static var keep: [MarkdownToolProvider] = []

    @MainActor
    func call(_ name: String, _ args: JSONObject = JSONObject()) async -> McpToolResult {
        await registry.callTool(name, args)
    }
}

extension McpToolResult {
    var value: JSONObject { structuredContent ?? JSONObject() }
    var errorCode: String? { structuredContent?["error"]?["code"]?.stringValue }
}

func int(_ v: JSONValue?) -> Int? { v?.numberValue.map { Int($0) } }
func range(_ v: JSONValue?) -> NSRange? {
    guard let from = int(v?["from"]), let to = int(v?["to"]) else { return nil }
    return NSRange(location: from, length: to - from)
}

/// A successful call's structured result; records a failure when it errored.
@MainActor
func ok(_ h: Harness, _ name: String, _ args: JSONObject = JSONObject(), line: UInt = #line) async -> JSONObject {
    let result = await h.call(name, args)
    check(!result.isError, "\(name) \(JSONValue.object(args).stringified()) failed: \(result.text ?? "")", line: line)
    return result.value
}

/// A failing call; checks its error code and that the document didn't change.
@MainActor
func fails(_ h: Harness, _ name: String, _ args: JSONObject, code: String, containing: String? = nil, line: UInt = #line) async {
    let before = h.document.markdown
    let edits = h.document.edits.count
    let result = await h.call(name, args)
    check(result.isError, "\(name) \(JSONValue.object(args).stringified()) should fail", line: line)
    expectEqual(result.errorCode ?? "", code, "\(name) error code", line: line)
    if let containing {
        check((result.text ?? "").contains(containing), "\(name) message \"\(result.text ?? "")\" should contain \"\(containing)\"", line: line)
    }
    expectEqual(h.document.markdown, before, "\(name) must not change the document", line: line)
    expectEqual(h.document.edits.count, edits, "\(name) must not record an edit", line: line)
}

let sample = "# Title\n\nHello world, hello **you**.\n\n- one\n- two\n"

@MainActor
func run() async {
    // MARK: Tool list
    do {
        let h = Harness(sample)
        expectEqual(h.registry.listTools().map(\.name),
                    ["get_text", "find_text", "insert_text", "replace_text", "replace_range", "replace_selection", "set_selection", "format_text", "set_block_type"],
                    "tool names (bare, as the web editor's)")
        await fails(h, "no_such_tool", [:], code: "unknown_tool")

        // Read-only documents list only the read tools, and say so when the list changes
        var lists: [[String]] = []
        let subscription = h.registry.onListChanged { lists.append($0.map(\.name)) }
        h.document.readOnlyReason = "the file is locked"
        h.notify()
        expectEqual(lists.last ?? [], ["get_text", "find_text"], "read-only tool list")
        await fails(h, "replace_text", ["find": "world", "replace": "there"], code: "unknown_tool", containing: "read-only")
        let text = await ok(h, "get_text")
        expectEqual(text["readOnly"]?.stringValue ?? "", "the file is locked", "get_text reports why the document is read-only")
        h.document.readOnlyReason = nil
        h.notify()
        expectEqual(lists.last?.count ?? 0, 9, "editable again")
        subscription.cancel()
    }

    // MARK: get_text
    do {
        let h = Harness(sample, selection: NSRange(location: 9, length: 5))
        let text = await ok(h, "get_text")
        expectEqual(text["format"]?.stringValue ?? "", "markdown", "default format")
        expectEqual(text["content"]?.stringValue ?? "", sample, "content is the Markdown source")
        expectEqual(int(text["size"]) ?? -1, (sample as NSString).length, "size")
        expectEqual(text["selection"]?["text"]?.stringValue ?? "", "Hello", "selection text")
        check(text["blocks"] == nil, "no blocks unless asked")

        let plain = await ok(h, "get_text", ["format": "text"])
        expectEqual(plain["content"]?.stringValue ?? "", "Title\nHello world, hello you.\none\ntwo", "plain text")
        let html = await ok(h, "get_text", ["format": "html"])
        check((html["content"]?.stringValue ?? "").contains("<h1>Title</h1>"), "HTML content")

        let withBlocks = await ok(h, "get_text", ["blocks": true])
        let blocks = withBlocks["blocks"]?.arrayValue ?? []
        expectEqual(blocks.count, 4, "block count")
        expectEqual(blocks.first?["type"]?.stringValue ?? "", "heading", "first block type")
        expectEqual(int(blocks.first?["level"]) ?? 0, 1, "heading level")
        expectEqual(range(blocks.first) ?? NSRange(), NSRange(location: 0, length: 7), "heading range")
        expectEqual(blocks[1]["text"]?.stringValue ?? "", "Hello world, hello **you**.", "paragraph source")
        expectEqual(blocks[2]["in"]?.stringValue ?? "", "bulletList", "list item wrapper")
        expectEqual(blocks[3]["text"]?.stringValue ?? "", "two", "list item text")

        await fails(h, "get_text", ["format": "pdf"], code: "invalid_arguments")
        await fails(h, "get_text", ["blocks": "yes"], code: "invalid_arguments")
        await fails(h, "get_text", ["extra": true], code: "invalid_arguments")
    }

    // MARK: find_text
    do {
        let h = Harness(sample)
        let found = await ok(h, "find_text", ["query": "hello"])
        expectEqual(int(found["total"]) ?? 0, 2, "case-insensitive by default")
        let first = found["matches"]?.arrayValue?.first
        expectEqual(range(first) ?? NSRange(), NSRange(location: 9, length: 5), "first match range")
        expectEqual(first?["before"]?.stringValue ?? "", "# Title\n\n", "context before")
        expectEqual(first?["after"]?.stringValue ?? "", " world, hello **you**.\n\n- one\n", "context after (30 characters)")

        let cased = await ok(h, "find_text", ["query": "hello", "matchCase": true])
        expectEqual(int(cased["total"]) ?? 0, 1, "matchCase")
        let word = await ok(h, "find_text", ["query": "on", "wholeWord": true])
        expectEqual(int(word["total"]) ?? -1, 0, "wholeWord skips \"one\"")
        let regex = await ok(h, "find_text", ["query": "\\*\\*(\\w+)\\*\\*", "regex": true])
        expectEqual(regex["matches"]?.arrayValue?.first?["text"]?.stringValue ?? "", "**you**", "regex match")
        let limited = await ok(h, "find_text", ["query": "o", "maxResults": 1])
        expectEqual(limited["matches"]?.arrayValue?.count ?? 0, 1, "maxResults")
        expectEqual(limited["truncated"]?.boolValue ?? false, true, "truncated")

        await fails(h, "find_text", [:], code: "invalid_arguments")
        await fails(h, "find_text", ["query": ""], code: "invalid_arguments")
        await fails(h, "find_text", ["query": "a", "maxResults": 0], code: "invalid_arguments")
        await fails(h, "find_text", ["query": "(", "regex": true], code: "tool_failed", containing: "Invalid search pattern")
    }

    // MARK: replace_text
    do {
        let h = Harness(sample, selection: NSRange(location: 22, length: 5)) // "hello"
        let all = await ok(h, "replace_text", ["find": "hello", "replace": "Hi"])
        expectEqual(int(all["replaced"]) ?? 0, 2, "replaced count")
        expectEqual(h.document.markdown, "# Title\n\nHi world, Hi **you**.\n\n- one\n- two\n", "replace all")
        expectEqual(h.document.edits.count, 1, "one undo step for every match")
        expectEqual((all["ranges"]?.arrayValue ?? []).compactMap(range), [NSRange(location: 9, length: 2), NSRange(location: 19, length: 2)], "ranges after the edit")
        expectEqual(h.document.selection, NSRange(location: 19, length: 2), "selection on a replaced match moves to its replacement")

        let nth = await ok(h, "replace_text", ["find": "hi", "replace": "Hello", "occurrence": 2])
        expectEqual(int(nth["replaced"]) ?? 0, 1, "occurrence replaces one")
        expectEqual(h.document.markdown, "# Title\n\nHi world, Hello **you**.\n\n- one\n- two\n", "occurrence 2")

        await fails(h, "replace_text", ["find": "absent", "replace": "x"], code: "tool_failed", containing: "No match for \"absent\"")
        await fails(h, "replace_text", ["find": "Hi", "replace": "x", "occurrence": 5], code: "tool_failed", containing: "only 1 matches")
        await fails(h, "replace_text", ["find": "Hi"], code: "invalid_arguments")
        await fails(h, "replace_text", ["find": "Hi", "replace": "x", "occurrence": 0], code: "invalid_arguments")
    }

    // MARK: replace_range
    do {
        let h = Harness("Hello world")
        let r = await ok(h, "replace_range", ["from": 6, "to": 11, "text": "there"])
        expectEqual(h.document.markdown, "Hello there", "replace_range")
        expectEqual(range(r["range"]) ?? NSRange(), NSRange(location: 6, length: 5), "returned range")
        expectEqual(int(r["size"]) ?? 0, 11, "size")
        _ = await ok(h, "replace_range", ["from": 5, "to": 5, "text": ","])
        expectEqual(h.document.markdown, "Hello, there", "from == to inserts")
        _ = await ok(h, "replace_range", ["from": 5, "to": 6, "text": ""])
        expectEqual(h.document.markdown, "Hello there", "empty text deletes")
        expectEqual(h.document.edits.count, 3, "one undo step per call")

        await fails(h, "replace_range", ["from": 6, "to": 2, "text": "x"], code: "tool_failed", containing: "must not be after")
        await fails(h, "replace_range", ["from": 0, "to": 99, "text": "x"], code: "tool_failed", containing: "outside the document")
        await fails(h, "replace_range", ["from": -1, "to": 2, "text": "x"], code: "invalid_arguments")
        await fails(h, "replace_range", ["from": 0, "to": 2], code: "invalid_arguments")
        await fails(h, "replace_range", ["from": 0.5, "to": 2, "text": "x"], code: "invalid_arguments")
    }

    // MARK: Offsets are UTF-16 code units of the raw Markdown
    do {
        let h = Harness("👋 **hi** there")
        let found = await ok(h, "find_text", ["query": "there"])
        expectEqual(range(found["matches"]?.arrayValue?.first) ?? NSRange(), NSRange(location: 10, length: 5), "UTF-16 offsets after an emoji and markers")
        _ = await ok(h, "replace_range", ["from": 10, "to": 15, "text": "you"])
        expectEqual(h.document.markdown, "👋 **hi** you", "edit after an emoji")
    }

    // MARK: insert_text, replace_selection, set_selection
    do {
        let h = Harness("Hello world", selection: NSRange(location: 6, length: 5))
        let inserted = await ok(h, "insert_text", ["text": "big ", "at": 6])
        expectEqual(h.document.markdown, "Hello big world", "insert at")
        expectEqual(range(inserted["range"]) ?? NSRange(), NSRange(location: 6, length: 4), "inserted range")
        expectEqual(h.document.selection, NSRange(location: 10, length: 5), "the user's selection moves with the text")
        await fails(h, "insert_text", ["text": "x", "at": 99], code: "tool_failed", containing: "outside the document")
        await fails(h, "insert_text", ["at": 0], code: "invalid_arguments")

        let replaced = await ok(h, "replace_selection", ["text": "there"])
        expectEqual(h.document.markdown, "Hello big there", "replace_selection")
        expectEqual(range(replaced["replaced"]) ?? NSRange(), NSRange(location: 10, length: 5), "replaced range")
        expectEqual(h.document.selection, NSRange(location: 15, length: 0), "caret after the new text")
        await fails(h, "replace_selection", [:], code: "invalid_arguments")

        _ = await ok(h, "insert_text", ["text": "!"])
        expectEqual(h.document.markdown, "Hello big there!", "insert at the cursor")

        let selected = await ok(h, "set_selection", ["from": 0, "to": 5])
        expectEqual(h.document.selection, NSRange(location: 0, length: 5), "set_selection")
        expectEqual(selected["selection"]?["text"]?.stringValue ?? "", "Hello", "selection text")
        _ = await ok(h, "set_selection", ["from": 3])
        expectEqual(h.document.selection, NSRange(location: 3, length: 0), "set_selection caret")
        await fails(h, "set_selection", ["from": 3, "to": 99], code: "tool_failed", containing: "outside the document")
        await fails(h, "set_selection", ["to": 3], code: "invalid_arguments")
    }

    // MARK: format_text in Slack mrkdwn
    do {
        let h = Harness("Hello world and more", flavor: .slack)
        let bold = await ok(h, "format_text", ["from": 6, "to": 11, "bold": true])
        expectEqual(h.document.markdown, "Hello *world* and more", "Slack bold uses single asterisks")
        expectEqual(range(bold["range"]) ?? NSRange(), NSRange(location: 7, length: 5), "Slack range on the text inside the markers")
        expectEqual(bold["formatting"]?["bold"]?.boolValue ?? false, true, "Slack *text* reads as bold, not italic")
        check(bold["formatting"]?["italic"] == nil, "Slack *text* is not reported as italic")

        _ = await ok(h, "format_text", ["from": 7, "to": 12, "bold": false, "italic": true])
        expectEqual(h.document.markdown, "Hello _world_ and more", "Slack italic uses underscores")

        _ = await ok(h, "format_text", ["from": 14, "to": 17, "strike": true])
        expectEqual(h.document.markdown, "Hello _world_ ~and~ more", "Slack strike uses single tildes")

        let linked = await ok(h, "format_text", ["from": 20, "to": 24, "link": "https://example.com"])
        expectEqual(h.document.markdown, "Hello _world_ ~and~ <https://example.com|more>", "Slack link uses <url|text>")
        expectEqual(linked["formatting"]?["link"]?.stringValue ?? "", "https://example.com", "Slack link is reported")
        expectEqual(h.document.edits.count, 4, "Slack: one undo step per call")

        let text = await ok(h, "get_text", ["format": "text"])
        expectEqual(text["content"]?.stringValue ?? "", "Hello world and more", "Slack plain text drops Slack syntax")
    }
    do {
        // Without the flavour, the same text would be GitHub Markdown
        let h = Harness("Hello world", flavor: .github)
        _ = await ok(h, "format_text", ["from": 6, "to": 11, "bold": true])
        expectEqual(h.document.markdown, "Hello **world**", "GitHub bold still uses double asterisks")
    }

    // MARK: format_text
    do {
        let h = Harness("Hello world and more", selection: NSRange(location: 0, length: 0))
        let bold = await ok(h, "format_text", ["from": 6, "to": 11, "bold": true])
        expectEqual(h.document.markdown, "Hello **world** and more", "bold")
        expectEqual(range(bold["range"]) ?? NSRange(), NSRange(location: 8, length: 5), "range on the text inside the markers")
        expectEqual(bold["formatting"]?["bold"]?.boolValue ?? false, true, "formatting reports bold")
        expectEqual(h.document.edits.count, 1, "one undo step")

        _ = await ok(h, "format_text", ["from": 8, "to": 13, "bold": true])
        expectEqual(h.document.markdown, "Hello **world** and more", "bold: true on bold text changes nothing")
        expectEqual(h.document.edits.count, 1, "no edit when nothing changes")

        _ = await ok(h, "format_text", ["from": 8, "to": 13, "bold": false, "italic": true])
        expectEqual(h.document.markdown, "Hello *world* and more", "clear bold and set italic in one call")
        expectEqual(h.document.edits.count, 2, "still one undo step")

        let linked = await ok(h, "format_text", ["from": 14, "to": 17, "link": "https://example.com"])
        expectEqual(h.document.markdown, "Hello *world* [and](https://example.com) more", "link")
        expectEqual(linked["formatting"]?["link"]?.stringValue ?? "", "https://example.com", "formatting reports the link")
        _ = await ok(h, "format_text", ["from": 15, "to": 18, "link": nil])
        expectEqual(h.document.markdown, "Hello *world* and more", "null removes the link")

        let code = await ok(h, "format_text", ["from": 18, "to": 22, "code": true, "strike": true])
        check(h.document.markdown.contains("~~`more`~~") || h.document.markdown.contains("`~~more~~`"), "strike and code: \(h.document.markdown)")
        check(code["formatting"]?["code"] != nil, "formatting reports code")

        await fails(h, "format_text", ["from": 0, "to": 5], code: "tool_failed", containing: "Pass at least one formatting property")
        await fails(h, "format_text", ["from": 2, "to": 2, "bold": true], code: "tool_failed", containing: "The range is empty")
        await fails(h, "format_text", ["from": 2, "bold": true], code: "tool_failed", containing: "Pass both")
        await fails(h, "format_text", ["from": 0, "to": 5, "link": "javascript:alert(1)"], code: "tool_failed", containing: "javascript:")
        await fails(h, "format_text", ["from": 0, "to": 5, "link": ""], code: "invalid_arguments")
        await fails(h, "format_text", ["from": 0, "to": 5, "underline": true], code: "invalid_arguments")

        // The selection is used when from/to are omitted, and left where it was
        let s = Harness("one two", selection: NSRange(location: 4, length: 3))
        _ = await ok(s, "format_text", ["italic": true])
        expectEqual(s.document.markdown, "one *two*", "formats the selection")
        expectEqual(s.document.selection, NSRange(location: 4, length: 5), "selection kept on the same text")

        let c = Harness("```\ncode here\n```\n")
        await fails(c, "format_text", ["from": 4, "to": 8, "bold": true], code: "tool_failed", containing: "cannot be made bold")
    }

    // MARK: set_block_type
    do {
        let h = Harness("Intro\n\nSecond line\n")
        let heading = await ok(h, "set_block_type", ["from": 0, "to": 0, "type": "heading", "level": 2])
        expectEqual(h.document.markdown, "## Intro\n\nSecond line\n", "heading")
        let blocks = heading["blocks"]?.arrayValue ?? []
        expectEqual(blocks.first?["type"]?.stringValue ?? "", "heading", "returned block type")
        expectEqual(int(blocks.first?["level"]) ?? 0, 2, "returned level")
        expectEqual(h.document.edits.count, 1, "one undo step")

        _ = await ok(h, "set_block_type", ["from": 3, "to": 3, "type": "heading", "level": 2])
        expectEqual(h.document.edits.count, 1, "already a level 2 heading: no edit")
        _ = await ok(h, "set_block_type", ["from": 3, "to": 3, "type": "bullet_list"])
        expectEqual(h.document.markdown, "- Intro\n\nSecond line\n", "heading to bullet list")
        _ = await ok(h, "set_block_type", ["from": 2, "to": 2, "type": "task_list"])
        expectEqual(h.document.markdown, "- [ ] Intro\n\nSecond line\n", "bullet to task list")
        _ = await ok(h, "set_block_type", ["from": 6, "to": 6, "type": "paragraph"])
        expectEqual(h.document.markdown, "Intro\n\nSecond line\n", "back to a paragraph")

        let quote = Harness("Quote me\n")
        _ = await ok(quote, "set_block_type", ["from": 0, "to": 0, "type": "blockquote"])
        expectEqual(quote.document.markdown, "> Quote me\n", "blockquote")
        _ = await ok(quote, "set_block_type", ["from": 3, "to": 3, "type": "ordered_list"])
        expectEqual(quote.document.markdown, "1. Quote me\n", "quote to ordered list (taken out of the quote first)")
        _ = await ok(quote, "set_block_type", ["from": 3, "to": 3, "type": "code_block"])
        expectEqual(quote.document.markdown, "```\nQuote me\n```\n", "code block")
        let back = await ok(quote, "set_block_type", ["from": 5, "to": 5, "type": "paragraph"])
        expectEqual(quote.document.markdown, "Quote me\n", "code block to paragraph")
        expectEqual(back["blocks"]?.arrayValue?.first?["type"]?.stringValue ?? "", "paragraph", "returned paragraph")

        let several = Harness("a\nb\nc\n")
        _ = await ok(several, "set_block_type", ["from": 0, "to": 5, "type": "ordered_list"])
        expectEqual(several.document.markdown, "1. a\n2. b\n3. c\n", "every line the range touches")

        await fails(h, "set_block_type", ["type": "heading"], code: "tool_failed", containing: "Pass a heading \"level\"")
        await fails(h, "set_block_type", ["type": "paragraph", "level": 2], code: "tool_failed", containing: "only applies to type \"heading\"")
        await fails(h, "set_block_type", ["type": "heading", "level": 7], code: "invalid_arguments")
        await fails(h, "set_block_type", ["type": "table"], code: "invalid_arguments")
        await fails(h, "set_block_type", [:], code: "invalid_arguments")
        let table = Harness("| a | b |\n| - | - |\n| 1 | 2 |\n")
        await fails(table, "set_block_type", ["from": 2, "to": 2, "type": "heading", "level": 1], code: "tool_failed", containing: "table")
    }

    // MARK: Writes on read-only documents
    do {
        let h = Harness("Text")
        h.document.readOnlyReason = "it is a version being browsed"
        // Called directly (as a stale tool list would), a write explains why it can't run
        let tools = MarkdownToolProvider(target: h.document).provider(id: "direct")
        let direct = ToolRegistry()
        h.document.readOnlyReason = nil
        _ = try! direct.register(tools)
        h.document.readOnlyReason = "it is a version being browsed"
        // The registry re-reads the list on each call, so the write is no longer there
        let result = await direct.callTool("replace_range", ["from": 0, "to": 1, "text": "x"])
        check(result.isError, "write on a read-only document fails")
        expectEqual(h.document.markdown, "Text", "read-only document unchanged")
    }
}

await run()
print("\(checks - failures)/\(checks) checks passed")
exit(failures == 0 ? 0 : 1)

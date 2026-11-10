// Checks for Slack mrkdwn on the shared Markdown model (Swash/SlackMarkdown.swift): the parse the
// Edit Text styler draws from, and the formatting edits behind the formatting bar, edit menu,
// bubble menu and Format menu. Run via scripts/run_slack_tests.sh.
import Foundation
import PixerateMarkdown

var failures = 0
func check(_ name: String, _ actual: String?, _ expected: String) {
    let ok = actual == expected
    print("\(ok ? "PASS" : "FAIL") \(name)\(ok ? "" : " — expected \(expected.debugDescription), got \((actual ?? "nil").debugDescription)")")
    if !ok { failures += 1 }
}

/// The inline nodes of every paragraph, heading and cell, as `kind(children)`, blocks separated by `|`.
func inlines(_ text: String) -> String {
    let document = SlackMarkdown.parse(text)
    let ns = text as NSString
    func describe(_ node: MarkdownNode) -> String {
        let name: String
        switch node.kind {
        case .text: return ns.substring(with: node.range).debugDescription
        case .softBreak: return "br"
        case .strong: name = "b"
        case .emphasis: name = "i"
        case .strikethrough: name = "s"
        case .code: return "code(\(ns.substring(with: node.range).debugDescription))"
        case .link(let destination, _, let kind): name = "link<\(destination)|\(kind)>"
        default: name = "\(node.kind)"
        }
        let children = node.children.map(describe).joined(separator: " ")
        return children.isEmpty ? name : "\(name)(\(children))"
    }
    var blocks: [String] = []
    document.root.walk { node in
        switch node.kind {
        case .paragraph, .heading, .tableCell: blocks.append(node.children.map(describe).joined(separator: " "))
        default: break
        }
    }
    return blocks.joined(separator: " | ")
}

/// The markers (hidden syntax) of the inline nodes, as source substrings.
func markers(_ text: String) -> String {
    let ns = text as NSString
    var found: [String] = []
    SlackMarkdown.parse(text).root.walk { node in
        guard !node.kind.isBlock else { return }
        found += node.markers.map { ns.substring(with: $0) }
    }
    return found.joined(separator: " ")
}

// MARK: Parsing

check("bold, italic, strike", inlines("*b* _i_ ~s~"), "b(\"b\") \" \" i(\"i\") \" \" s(\"s\")")
check("nested emphasis", inlines("*bold _both_*"), "b(\"bold \" i(\"both\"))")
check("doubled delimiters are literal", inlines("**not bold**"), "\"**not bold**\"")
check("delimiters inside words are literal", inlines("snake_case_name and 2*3*4"), "\"snake_case_name and 2*3*4\"")
check("an opener needs a non-space after it", inlines("a * not bold*"), "\"a * not bold*\"")
check("emphasis doesn't cross lines", inlines("*one\ntwo*"), "\"*one\" br \"two*\"")
check("code span contents are literal", inlines("`*x*` *y*"), "code(\"`*x*`\") \" \" b(\"y\")")
check("emphasis can't cut a code span", inlines("*a `b* c`"), "\"*a \" code(\"`b* c`\")")
check("labelled link", inlines("see <https://x.com|the site>"), "\"see \" link<https://x.com|inline>(\"the site\")")
check("bare angle link", inlines("<https://x.com>"), "link<https://x.com|autolink>(\"https://x.com\")")
check("mentions stay text", inlines("hi <@U123> and <!here>"), "\"hi <@U123> and <!here>\"")
check("a mention at the start of a line is a paragraph", inlines("<!here> look"), "\"<!here> look\"")
check("bare URL without trailing punctuation", inlines("go to https://x.com/a."), "\"go to \" link<https://x.com/a|extendedAutolink>(\"https://x.com/a\") \".\"")
check("www URL", inlines("www.example.com"), "link<http://www.example.com|extendedAutolink>(\"www.example.com\")")
check("link inside bold", inlines("*see <https://x.com|it>*"), "b(\"see \" link<https://x.com|inline>(\"it\"))")
check("quote continuation lines skip the marker", inlines("> *a*\n> _b_"), "b(\"a\") br i(\"b\")")
check("code block content isn't parsed", inlines("```\n*x*\n```\nafter *y*"), "\"after \" b(\"y\")")
check("list items", inlines("- *a*\n- ~b~"), "b(\"a\") | s(\"b\")")
check("CommonMark links aren't links, but their URLs are", inlines("[t](https://x.com)"), "\"[t](\" link<https://x.com|extendedAutolink>(\"https://x.com\") \")\"")
check("markers", markers("*b* <https://x.com|t> `c`"), "* * <https://x.com| > ` `")

// MARK: Formatting

/// Splits ⟦…⟧ (a selection) or ‸ (a caret) out of `input`.
func unmark(_ input: String) -> (String, NSRange) {
    var ns = input as NSString
    let caret = ns.range(of: "‸")
    if caret.location != NSNotFound {
        return (ns.replacingCharacters(in: caret, with: ""), NSRange(location: caret.location, length: 0))
    }
    let open = ns.range(of: "⟦")
    ns = ns.replacingCharacters(in: open, with: "") as NSString
    let close = ns.range(of: "⟧")
    return (ns.replacingCharacters(in: close, with: ""), NSRange(location: open.location, length: close.location - open.location))
}

func mark(_ text: String, _ selection: NSRange) -> String {
    let ns = text as NSString
    if selection.length == 0 { return ns.replacingCharacters(in: selection, with: "‸") }
    return ns.substring(to: selection.location) + "⟦" + ns.substring(with: selection) + "⟧" + ns.substring(from: NSMaxRange(selection))
}

/// Runs `command` on `input` (selection marked) and returns the result marked the same way.
func format(_ command: FormatCommand, _ input: String) -> String {
    let (text, selection) = unmark(input)
    guard let edit = FormatCommandEdits.edit(for: command, text: text, selection: selection, flavor: .slack) else { return "nil" }
    return mark(edit.text, edit.selection)
}

func link(_ url: String?, _ input: String) -> String {
    let (text, selection) = unmark(input)
    guard let edit = FormatCommandEdits.link(url, text: text, selection: selection, flavor: .slack) else { return "nil" }
    return mark(edit.text, edit.selection)
}

check("bold adds single asterisks", format(.bold, "make ⟦this⟧ bold"), "make *⟦this⟧* bold")
check("italic adds underscores", format(.italic, "make ⟦this⟧ italic"), "make _⟦this⟧_ italic")
check("strikethrough adds single tildes", format(.strikethrough, "⟦gone⟧"), "~⟦gone⟧~")
check("bold removes Slack bold", format(.bold, "make *⟦this⟧* plain"), "make ⟦this⟧ plain")
check("italic removes with a caret inside", format(.italic, "an _ita‸lic_ word"), "an ita‸lic word")
check("bold at a caret inserts a pair", format(.bold, "a ‸"), "a *‸*")
check("bold across lines wraps each line", format(.bold, "⟦one\ntwo⟧"), "⟦*one*\n*two*⟧")
check("bold merges an existing bold span", format(.bold, "⟦a *b* c⟧"), "*⟦a b c⟧*")
check("bold inside a link label", format(.bold, "<https://x.com|li⟦nk⟧> x"), "<https://x.com|li*⟦nk⟧*> x")
check("bold over a link and text takes the whole link", format(.bold, "<https://x.com|li⟦nk> x⟧"), "*⟦<https://x.com|link> x⟧*")
check("italic inside bold", format(.italic, "*a ⟦b⟧ c*"), "*a _⟦b⟧_ c*")
check("inline code uses backticks", format(.code, "run ⟦ls⟧ now"), "run `⟦ls⟧` now")
check("quote", format(.quote, "⟦line⟧"), "> ⟦line⟧")
check("bullet list", format(.bulletList, "⟦item⟧"), "- ⟦item⟧")
check("code block uses fences", format(.codeBlock, "⟦code⟧"), "```\n⟦code⟧\n```")
check("no callouts in Slack", format(.callout(.note), "⟦x⟧"), "nil")
check("no footnotes in Slack", format(.footnote, "⟦x⟧"), "nil")
check("bold is off in code", format(.bold, "`a⟦b⟧c`"), "nil")
check("link wraps the selection", link("https://x.com", "see ⟦docs⟧"), "see <https://x.com|⟦docs⟧>")
check("link changes the URL", link("https://y.com", "see <https://x.com|do‸cs>"), "see <https://y.com|do‸cs>")
check("link removal keeps the text", link(nil, "see <https://x.com|do‸cs>"), "see do‸cs")
check("no active link outside", FormatCommandEdits.activeLink(text: "a <https://x.com|b> c", selection: NSRange(location: 20, length: 0), flavor: .slack) ?? "nil", "nil")
check("active link at the label", FormatCommandEdits.activeLink(text: "a <https://x.com|b> c", selection: NSRange(location: 17, length: 0), flavor: .slack), "https://x.com")

// Other flavours keep the engine's CommonMark delimiters
let gfm = FormatCommandEdits.edit(for: .bold, text: "x", selection: NSRange(location: 0, length: 1), flavor: .github)
check("GitHub bold is unchanged", gfm?.text, "**x**")

print(failures == 0 ? "SLACK: all checks passed" : "SLACK: \(failures) failed")
exit(failures == 0 ? 0 : 1)

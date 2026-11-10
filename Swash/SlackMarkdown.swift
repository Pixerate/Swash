//
//  SlackMarkdown.swift
//  Swash
//
//  Slack mrkdwn on the shared Markdown model, so the Edit Text styler, the formatting bar, the
//  bubble menu and the Format menu work on Slack documents on every platform (issue #56).
//
//  Slack's blocks (quotes, ``` code blocks, list-like lines) are the CommonMark ones, so the
//  engine's block parser is reused. Inline content is Slack's own: `*bold*`, `_italic_`,
//  `~strike~`, `code`, `<url|text>` and `<url>` links, and bare URLs. Every node carries its
//  UTF-16 source range and markers, as the engine's do, so `MarkdownEditorStyler` and
//  `MarkdownFormatting` need no Slack-specific code. Formatting that *adds* delimiters writes
//  Slack's (`*`, `_`, `~`, `<url|text>`) rather than the engine's CommonMark ones.
//

import Foundation
import PixerateMarkdown

enum SlackMarkdown {
    /// Parses Slack mrkdwn into the shared document model.
    static func parse(_ text: String) -> MarkdownDocument {
        let document = MarkdownDocument.parse(text)
        let ns = text as NSString
        // Slack has no HTML: blocks the CommonMark parser took for HTML (`<!here>`, `<@U123>`
        // at the start of a line) are paragraphs
        var htmlBlocks: [MarkdownNode] = []
        document.root.walk { node in
            if case .htmlBlock = node.kind { htmlBlocks.append(node) }
        }
        for html in htmlBlocks {
            let paragraph = MarkdownNode(.paragraph, range: html.range)
            html.insertAfter(paragraph)
            html.unlink()
        }
        var containers: [MarkdownNode] = []
        document.root.walk { node in
            switch node.kind {
            case .paragraph, .heading, .tableCell: containers.append(node)
            default: break
            }
        }
        for container in containers {
            reparseInlines(of: container, in: ns)
        }
        return document
    }

    /// Replaces the CommonMark inline children of `container` with a Slack parse of the same source.
    private static func reparseInlines(of container: MarkdownNode, in ns: NSString) {
        let children = container.children
        let content: NSRange
        if let first = children.first, let last = children.last {
            content = NSRange(location: first.range.location, length: NSMaxRange(last.range) - first.range.location)
        } else if case .paragraph = container.kind {
            content = container.range
        } else {
            return
        }
        for child in children { child.unlink() }
        guard content.length > 0, NSMaxRange(content) <= ns.length else { return }

        // Quote markers on continuation lines are container syntax, not content
        let prefixMarkers = container.ancestors.flatMap { ancestor -> [NSRange] in
            switch ancestor.kind {
            case .blockQuote, .alert: return ancestor.markers
            default: return []
            }
        }
        let end = NSMaxRange(content)
        var lineStart = content.location
        var first = true
        while lineStart < end {
            var contentsEnd = 0
            var lineEnd = 0
            ns.getLineStart(nil, end: &lineEnd, contentsEnd: &contentsEnd, for: NSRange(location: lineStart, length: 0))
            var a = lineStart
            let b = min(contentsEnd, end)
            if !first {
                while a < b {
                    let c = ns.character(at: a)
                    if c == 0x20 || c == 0x09 || prefixMarkers.contains(where: { NSLocationInRange(a, $0) }) {
                        a += 1
                    } else {
                        break
                    }
                }
            }
            if b > a {
                for node in SlackInlineParser(ns: ns).parse(NSRange(location: a, length: b - a)) {
                    container.appendChild(node)
                }
            }
            if contentsEnd < end, lineEnd > contentsEnd {
                let breakRange = NSRange(location: contentsEnd, length: min(lineEnd, end) - contentsEnd)
                container.appendChild(MarkdownNode(.softBreak, range: breakRange))
            }
            if lineEnd <= lineStart { break }
            lineStart = lineEnd
            first = false
        }
    }
}

/// Slack's inline syntax within one line. Emphasis delimiters open after a non-word character and
/// before a non-space, close after a non-space and before a non-word character, and are never
/// doubled (`**x**` is literal in Slack).
private struct SlackInlineParser {
    let ns: NSString

    private static let star: unichar = 0x2A, underscore: unichar = 0x5F, tilde: unichar = 0x7E
    private static let backtick: unichar = 0x60, lessThan: unichar = 0x3C, greaterThan: unichar = 0x3E, pipe: unichar = 0x7C

    func parse(_ range: NSRange) -> [MarkdownNode] {
        let protected = protectedSpans(in: range)
        return parse(range, protected: protected)
    }

    // MARK: Code spans and links

    /// A code span or link: its node, made once, so emphasis never splits it.
    private struct Span {
        let range: NSRange
        let node: MarkdownNode
    }

    /// Code spans first (their contents are literal), then `<…>` links outside them, then bare URLs.
    private func protectedSpans(in range: NSRange) -> [Span] {
        var spans: [Span] = []
        let end = NSMaxRange(range)
        var i = range.location
        while i < end {
            let c = ns.character(at: i)
            if c == Self.backtick {
                var run = 0
                while i + run < end, ns.character(at: i + run) == Self.backtick { run += 1 }
                if let close = closingRun(of: run, from: i + run, end: end) {
                    let full = NSRange(location: i, length: close + run - i)
                    let node = MarkdownNode(.code, range: full)
                    node.markers = [NSRange(location: i, length: run), NSRange(location: close, length: run)]
                    node.literal = ns.substring(with: NSRange(location: i + run, length: close - i - run))
                    spans.append(Span(range: full, node: node))
                    i = close + run
                } else {
                    i += run
                }
                continue
            }
            if c == Self.lessThan, let span = angleLink(at: i, end: end) {
                spans.append(span)
                i = NSMaxRange(span.range)
                continue
            }
            if let span = bareURL(at: i, start: range.location, end: end) {
                spans.append(span)
                i = NSMaxRange(span.range)
                continue
            }
            i += 1
        }
        return spans
    }

    private func closingRun(of length: Int, from start: Int, end: Int) -> Int? {
        var j = start
        while j < end {
            guard ns.character(at: j) == Self.backtick else { j += 1; continue }
            var run = 0
            while j + run < end, ns.character(at: j + run) == Self.backtick { run += 1 }
            if run == length, j > start { return j }
            j += run
        }
        return nil
    }

    private static let schemes = ["https://", "http://", "mailto:"]

    private func hasScheme(at i: Int, end: Int) -> Bool {
        Self.schemes.contains { scheme in
            let length = (scheme as NSString).length
            return i + length <= end && ns.substring(with: NSRange(location: i, length: length)).lowercased() == scheme
        }
    }

    /// `<url|text>` or `<url>`; mentions and channels (`<@U…>`, `<#C…|name>`, `<!here>`) stay text.
    private func angleLink(at i: Int, end: Int) -> Span? {
        guard hasScheme(at: i + 1, end: end) else { return nil }
        var j = i + 1
        var pipe: Int?
        while j < end {
            let c = ns.character(at: j)
            if c == Self.greaterThan { break }
            if c == Self.lessThan || c == 0x20 && pipe == nil { return nil }
            if c == Self.pipe && pipe == nil { pipe = j }
            j += 1
        }
        guard j < end else { return nil }
        let full = NSRange(location: i, length: j + 1 - i)
        let closing = NSRange(location: j, length: 1)
        if let pipe = pipe {
            let destination = ns.substring(with: NSRange(location: i + 1, length: pipe - i - 1))
            let label = NSRange(location: pipe + 1, length: j - pipe - 1)
            guard label.length > 0 else { return nil }
            let node = MarkdownNode(.link(destination: destination, title: nil, kind: .inline), range: full)
            node.markers = [NSRange(location: i, length: pipe + 1 - i), closing]
            node.appendChild(text(label))
            return Span(range: full, node: node)
        }
        let urlRange = NSRange(location: i + 1, length: j - i - 1)
        let node = MarkdownNode(.link(destination: ns.substring(with: urlRange), title: nil, kind: .autolink), range: full)
        node.markers = [NSRange(location: i, length: 1), closing]
        node.appendChild(text(urlRange))
        return Span(range: full, node: node)
    }

    /// A bare `http(s)://` or `www.` URL after a non-word character, without trailing punctuation.
    private func bareURL(at i: Int, start: Int, end: Int) -> Span? {
        if i > start, isWordCharacter(ns.character(at: i - 1)) { return nil }
        func starts(with prefix: String) -> Bool {
            let length = (prefix as NSString).length
            return i + length <= end && ns.substring(with: NSRange(location: i, length: length)).lowercased() == prefix
        }
        let isWWW = starts(with: "www.")
        guard isWWW || starts(with: "http://") || starts(with: "https://") else { return nil }
        var j = i
        while j < end {
            let c = ns.character(at: j)
            if c == 0x20 || c == 0x09 || c == Self.lessThan || c == Self.greaterThan || c == Self.backtick { break }
            j += 1
        }
        let trailing: Set<unichar> = [0x2E, 0x2C, 0x3B, 0x3A, 0x21, 0x3F, 0x29, 0x5D, 0x22, 0x27, Self.star, Self.underscore, Self.tilde]
        while j > i, trailing.contains(ns.character(at: j - 1)) { j -= 1 }
        let range = NSRange(location: i, length: j - i)
        let source = ns.substring(with: range)
        guard isWWW ? range.length > 4 : !Self.schemes.contains(where: { source.lowercased() == $0 }) else { return nil }
        let node = MarkdownNode(.link(destination: isWWW ? "http://" + source : source, title: nil, kind: .extendedAutolink), range: range)
        node.appendChild(text(range))
        return Span(range: range, node: node)
    }

    // MARK: Emphasis

    private func parse(_ range: NSRange, protected: [Span]) -> [MarkdownNode] {
        var nodes: [MarkdownNode] = []
        let end = NSMaxRange(range)
        var textStart = range.location
        var i = range.location

        func flushText(upTo location: Int) {
            if location > textStart { nodes.append(text(NSRange(location: textStart, length: location - textStart))) }
        }

        while i < end {
            if let span = protected.first(where: { $0.range.location == i }), NSMaxRange(span.range) <= end {
                flushText(upTo: i)
                nodes.append(span.node)
                i = NSMaxRange(span.range)
                textStart = i
                continue
            }
            let c = ns.character(at: i)
            if let kind = Self.emphasisKind(c), canOpen(at: i, range: range),
               let close = closingDelimiter(c, after: i, range: range, protected: protected) {
                flushText(upTo: i)
                let full = NSRange(location: i, length: close + 1 - i)
                let node = MarkdownNode(kind, range: full)
                node.markers = [NSRange(location: i, length: 1), NSRange(location: close, length: 1)]
                for child in parse(NSRange(location: i + 1, length: close - i - 1), protected: protected) {
                    node.appendChild(child)
                }
                nodes.append(node)
                i = close + 1
                textStart = i
                continue
            }
            i += 1
        }
        flushText(upTo: end)
        return nodes
    }

    private static func emphasisKind(_ c: unichar) -> MarkdownNode.Kind? {
        switch c {
        case star: return .strong
        case underscore: return .emphasis
        case tilde: return .strikethrough
        default: return nil
        }
    }

    private func canOpen(at i: Int, range: NSRange) -> Bool {
        let c = ns.character(at: i)
        guard i + 1 < NSMaxRange(range) else { return false }
        let next = ns.character(at: i + 1)
        if next == c || isSpace(next) { return false }
        if i > range.location {
            let previous = ns.character(at: i - 1)
            if previous == c || isWordCharacter(previous) { return false }
        }
        return true
    }

    private func canClose(at j: Int, range: NSRange) -> Bool {
        let c = ns.character(at: j)
        let previous = ns.character(at: j - 1)
        if previous == c || isSpace(previous) { return false }
        if j + 1 < NSMaxRange(range) {
            let next = ns.character(at: j + 1)
            if next == c || isWordCharacter(next) { return false }
        }
        return true
    }

    /// The first closing delimiter for the opener at `i`, skipping code spans and links.
    private func closingDelimiter(_ c: unichar, after i: Int, range: NSRange, protected: [Span]) -> Int? {
        var j = i + 2
        let end = NSMaxRange(range)
        while j < end {
            if let span = protected.first(where: { NSLocationInRange(j, $0.range) }) {
                // A delimiter pair can't cut through a code span or link
                if span.range.location < i + 1 { return nil }
                j = NSMaxRange(span.range)
                continue
            }
            if ns.character(at: j) == c, canClose(at: j, range: range) { return j }
            j += 1
        }
        return nil
    }

    // MARK: Characters

    private func text(_ range: NSRange) -> MarkdownNode {
        let node = MarkdownNode(.text, range: range)
        node.literal = ns.substring(with: range)
        return node
    }

    private func isSpace(_ c: unichar) -> Bool {
        c == 0x20 || c == 0x09 || c == 0x0A || c == 0x0D
    }

    private func isWordCharacter(_ c: unichar) -> Bool {
        guard let scalar = Unicode.Scalar(c) else { return true }   // surrogate halves: part of a word
        return CharacterSet.alphanumerics.contains(scalar)
    }
}

// MARK: - Flavour-aware parsing and formatting

extension MarkdownDocument {
    /// The document model for `text` in `flavor`: Slack mrkdwn has its own inline syntax.
    static func parse(_ text: String, flavor: MarkdownFlavor) -> MarkdownDocument {
        flavor == .slack ? SlackMarkdown.parse(text) : parse(text)
    }
}

extension MarkdownFormatting {
    init(text: String, flavor: MarkdownFlavor) {
        self.init(text: text, document: flavor == .slack ? SlackMarkdown.parse(text) : nil)
    }

    /// Toggles an inline format, writing Slack's delimiters (`*bold*`, `_italic_`, `~strike~`)
    /// when it adds one. Removing works from the parsed markers, as for any flavour.
    func toggleSlack(_ format: MarkdownInlineFormat, selection: NSRange) -> MarkdownEdit? {
        let ns = text as NSString
        guard selection.location != NSNotFound, NSMaxRange(selection) <= ns.length else { return nil }
        if format == .code || isActive(format, selection: selection) {
            return toggle(format, selection: selection)
        }
        let delimiter: String
        switch format {
        case .strong: delimiter = "*"
        case .emphasis: delimiter = "_"
        case .strikethrough: delimiter = "~"
        case .code: return nil
        }
        let delimiterLength = (delimiter as NSString).length
        let segs = segments(in: selection)
        guard !segs.isEmpty else {
            // Caret: an empty pair with the caret between the delimiters
            let edited = ns.replacingCharacters(in: selection, with: delimiter + delimiter)
            return MarkdownEdit(text: edited, selection: NSRange(location: selection.location + delimiterLength, length: 0))
        }
        // Each segment grows until it no longer cuts through an inline node; nodes of the same
        // format inside it are merged (their delimiters dropped)
        var edits: [(range: NSRange, replacement: String)] = []
        for seg in segs {
            guard let container = inlineContainers(intersecting: seg).first(where: {
                $0.range.location <= seg.location && NSMaxRange(seg) <= NSMaxRange($0.range)
            }) else { continue }
            var union = seg
            var merged: [MarkdownNode] = []
            var changed = true
            while changed {
                changed = false
                container.walk { node in
                    guard node !== container, !node.kind.isBlock else { return }
                    switch node.kind {
                    case .text, .softBreak, .hardBreak: return
                    default: break
                    }
                    let r = node.range
                    let intersects = NSIntersectionRange(r, union).length > 0
                    let containsUnion = r.location <= union.location && NSMaxRange(union) <= NSMaxRange(r)
                    let insideUnion = union.location <= r.location && NSMaxRange(r) <= NSMaxRange(union)
                    guard intersects, !containsUnion else { return }
                    if format.matches(node.kind), !merged.contains(where: { $0 === node }) { merged.append(node) }
                    if !insideUnion {
                        union = NSUnionRange(union, r)
                        changed = true
                    }
                }
            }
            let inner = NSMutableString(string: ns.substring(with: union))
            let removals = merged.flatMap { $0.markers }
                .filter { union.location <= $0.location && NSMaxRange($0) <= NSMaxRange(union) }
                .sorted { $0.location > $1.location }
            for marker in removals {
                inner.replaceCharacters(in: NSRange(location: marker.location - union.location, length: marker.length), with: "")
            }
            edits.append((union, delimiter + (inner as String) + delimiter))
        }
        guard !edits.isEmpty else { return nil }
        let edited = NSMutableString(string: text)
        for edit in edits.sorted(by: { $0.range.location > $1.range.location }) {
            edited.replaceCharacters(in: edit.range, with: edit.replacement)
        }
        // Select the formatted text: inside the delimiters for one segment, across all of them otherwise
        let ordered = edits.sorted { $0.range.location < $1.range.location }
        var shift = 0
        var first: NSRange?
        var last: NSRange?
        for edit in ordered {
            let length = (edit.replacement as NSString).length
            let placed = NSRange(location: edit.range.location + shift, length: length)
            if first == nil { first = placed }
            last = placed
            shift += length - edit.range.length
        }
        guard let start = first, let finish = last else { return nil }
        let result = ordered.count == 1
            ? NSRange(location: start.location + delimiterLength, length: start.length - 2 * delimiterLength)
            : NSRange(location: start.location, length: NSMaxRange(finish) - start.location)
        return MarkdownEdit(text: edited as String, selection: result)
    }

    /// Links the selection to `url` with Slack's `<url|text>`, or changes the URL of the link at the selection.
    func setSlackLink(_ url: String, selection: NSRange) -> MarkdownEdit? {
        let ns = text as NSString
        guard selection.location != NSNotFound, NSMaxRange(selection) <= ns.length else { return nil }
        let opening = "<" + url + "|"
        let openingLength = (opening as NSString).length
        if let link = link(at: selection) {
            let textRange = linkTextRange(link)
            let label = ns.substring(with: textRange)
            let edited = ns.replacingCharacters(in: link.range, with: opening + label + ">")
            let start = link.range.location + openingLength
            func position(_ p: Int) -> Int { start + min(max(p - textRange.location, 0), textRange.length) }
            let a = position(selection.location)
            return MarkdownEdit(text: edited, selection: NSRange(location: a, length: position(NSMaxRange(selection)) - a))
        }
        guard let seg = segments(in: selection).first else {
            let edited = ns.replacingCharacters(in: selection, with: "<" + url + ">")
            return MarkdownEdit(text: edited, selection: NSRange(location: selection.location + 1, length: (url as NSString).length))
        }
        let edited = ns.replacingCharacters(in: seg, with: opening + ns.substring(with: seg) + ">")
        return MarkdownEdit(text: edited, selection: NSRange(location: seg.location + openingLength, length: seg.length))
    }
}

extension FormatCommandEdits {
    /// The edit for `command` in `flavor`. Slack mrkdwn adds its own inline delimiters and links,
    /// and has no callouts, footnotes or tables of contents; everything else is the engine's.
    static func edit(for command: FormatCommand, formatting: MarkdownFormatting, selection: NSRange, flavor: MarkdownFlavor) -> MarkdownEdit? {
        guard flavor == .slack else { return edit(for: command, formatting: formatting, selection: selection) }
        guard formatting.isEnabled(command, selection: selection) else { return nil }
        switch command {
        case .bold: return formatting.toggleSlack(.strong, selection: selection)
        case .italic: return formatting.toggleSlack(.emphasis, selection: selection)
        case .strikethrough: return formatting.toggleSlack(.strikethrough, selection: selection)
        case .callout, .footnote, .tableOfContents: return nil
        default: return edit(for: command, formatting: formatting, selection: selection)
        }
    }

    static func edit(for command: FormatCommand, text: String, selection: NSRange, flavor: MarkdownFlavor) -> MarkdownEdit? {
        edit(for: command, formatting: MarkdownFormatting(text: text, flavor: flavor), selection: selection, flavor: flavor)
    }

    /// Sets the link URL on the selection (`<url|text>` in Slack), or removes the link when `url` is nil or empty.
    static func link(_ url: String?, text: String, selection: NSRange, flavor: MarkdownFlavor) -> MarkdownEdit? {
        guard flavor == .slack else { return link(url, text: text, selection: selection) }
        let formatting = MarkdownFormatting(text: text, flavor: flavor)
        guard formatting.isEnabled(.link, selection: selection) else { return nil }
        guard let url = url, !url.isEmpty else { return formatting.removeLink(selection: selection) }
        return formatting.setSlackLink(url, selection: selection)
    }

    /// The destination of the link at `selection` in `flavor`, if there is one.
    static func activeLink(text: String, selection: NSRange, flavor: MarkdownFlavor) -> String? {
        let formatting = MarkdownFormatting(text: text, flavor: flavor)
        guard let node = formatting.link(at: selection), case .link(let destination, _, _) = node.kind else { return nil }
        return destination
    }
}

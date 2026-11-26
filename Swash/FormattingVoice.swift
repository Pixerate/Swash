//
//  FormattingVoice.swift
//  Swash
//
//  The writing partner's Formatting voice (#113): tidies Markdown that is safe to fix the way a full
//  stop is, without changing what the document says. It runs on this device, only on blocks the
//  person has finished with (never the block the caret is in), and never inside code, math, HTML or
//  front matter. Each fix is its own undo step and learns from ⌘Z, like the Punctuate voice's.
//
//  Structural changes that alter how a document reads (turning lines into a list, reordering) are
//  not made here: they stay suggestions (#101). The one exception is Copyedit's auto-formatting
//  (#229): a short title line on its own, followed by the text it introduces, becomes a heading.
//

import Foundation
import PixerateMarkdown

nonisolated enum FormattingVoice {
    /// The Formatting voice's rules, in the order Settings › Writing lists them.
    static let rules: [PunctuationRule] = [
        .formatLists, .formatHeadings, .formatSpacing, .formatSpans,
        .formatEmphasis, .formatTasks, .formatTables, .formatLinks, .formatTitleLines,
    ]

    /// Rules whose fixes are meant to change what a document renders (a `#Heading` that wasn't a
    /// heading, a `[]` that wasn't a task, two lists that differ only by bullet). Every other fix
    /// must leave the rendered document exactly as it was, and is dropped if it wouldn't.
    private static func mayChangeRendering(_ edit: PunctuationEdit) -> Bool {
        edit.rules.contains {
            $0 == .formatHeadings || $0 == .formatTasks || $0 == .formatLists || $0 == .formatSpans
                || $0 == .formatLinks || $0 == .formatTitleLines
        }
    }

    /// The fixes for the top-level blocks that `region` touches (the whole document when it's nil),
    /// leaving alone the block the caret is in and the gaps next to it. Edits are in raw-Markdown
    /// UTF-16 offsets of `text`, don't overlap, and are sorted left to right.
    static func edits(
        text: String,
        document: MarkdownDocument,
        flavor: MarkdownFlavor,
        regions: [NSRange]? = nil,
        caret: Int? = nil,
        isActive: (PunctuationRule) -> Bool = { _ in true },
        verify: Bool = true
    ) -> [PunctuationEdit] {
        guard flavor != .slack, !text.contains("\r") else { return [] }
        let ns = text as NSString
        let blocks = document.root.children
        guard !blocks.isEmpty else { return [] }

        let caretBlock = caret.flatMap { caretBlockIndex(blocks, caret: $0, ns: ns) }
        let touched: (Int) -> Bool = { index in
            guard let regions else { return true }
            let lines = lineSpan(of: blocks[index].range, in: ns)
            // A region that ends where a block starts (or starts where it ends) still touches it
            return regions.contains { $0.location <= NSMaxRange(lines) && NSMaxRange($0) >= lines.location }
        }

        var found: [PunctuationEdit] = []
        let emphasisMarker = documentEmphasisMarker(document.root, ns: ns)

        for (index, block) in blocks.enumerated() where index != caretBlock && touched(index) {
            if case .frontMatter = block.kind { continue }
            if case .htmlBlock = block.kind { continue }
            if isActive(.formatHeadings) { found += headingEdits(block, ns: ns) }
            if isActive(.formatLists) { found += listEdits(block, ns: ns, siblings: blocks, index: index, caretBlock: caretBlock) }
            if isActive(.formatTasks) { found += taskEdits(block, ns: ns, siblings: blocks, index: index) }
            if isActive(.formatSpacing) { found += spacingEdits(block, ns: ns) }
            if isActive(.formatSpans) { found += spanEdits(block, ns: ns) }
            if isActive(.formatEmphasis), let emphasisMarker { found += emphasisEdits(block, ns: ns, marker: emphasisMarker) }
            if isActive(.formatTables) { found += tableEdits(block, ns: ns) }
            if isActive(.formatLinks) { found += linkEdits(block, ns: ns, flavor: flavor) }
            if isActive(.formatTitleLines), let edit = titleLineEdit(blocks, index: index, ns: ns) { found.append(edit) }
        }
        if isActive(.formatSpacing) {
            for index in 0..<(blocks.count - 1) {
                guard index != caretBlock, index + 1 != caretBlock, touched(index) || touched(index + 1) else { continue }
                if let edit = gapEdit(between: blocks[index], and: blocks[index + 1], ns: ns, caret: caret) { found.append(edit) }
            }
        }

        // One fix per place: the first that reaches it wins, and the rest wait for the next pass
        var chosen: [PunctuationEdit] = []
        for edit in found.sorted(by: { $0.range.location < $1.range.location }) where edit.replacement != ns.substring(with: edit.range) {
            if let last = chosen.last, edit.range.location < NSMaxRange(last.range) || (edit.range.location == NSMaxRange(last.range) && edit.range.length == 0 && last.range.length == 0) {
                continue
            }
            chosen.append(edit)
        }
        return verify ? verified(chosen, text: text, flavor: flavor) : chosen
    }

    /// The top-level block the caret is in, which includes the line just after it: one Enter hasn't
    /// left it yet (the next line may continue the list or paragraph). A blank line in between has.
    private static func caretBlockIndex(_ blocks: [MarkdownNode], caret: Int, ns: NSString) -> Int? {
        let caretLine = lineSpan(of: NSRange(location: min(caret, ns.length), length: 0), in: ns)
        return blocks.lastIndex { block in
            let lines = lineSpan(of: block.range, in: ns)
            return caretLine.location >= lines.location && caretLine.location <= NSMaxRange(lines) + 1
        }
    }

    /// The text the caret's block spans (with the line after it), which a tidy waits to leave alone.
    static func caretSpan(text: String, document: MarkdownDocument, caret: Int) -> NSRange? {
        let ns = text as NSString
        let blocks = document.root.children
        guard let index = caretBlockIndex(blocks, caret: caret, ns: ns) else { return nil }
        let lines = lineSpan(of: blocks[index].range, in: ns)
        let end = min(ns.length, max(NSMaxRange(lines) + 1, NSMaxRange(lineSpan(of: NSRange(location: min(caret, ns.length), length: 0), in: ns))))
        return NSRange(location: lines.location, length: end - lines.location)
    }

    // MARK: - Checking a tidy leaves the rendering alone

    /// Drops any fix (other than those meant to change it) after which the document would render
    /// differently. Tidying must never change what the Markdown means.
    private static func verified(_ edits: [PunctuationEdit], text: String, flavor: MarkdownFlavor) -> [PunctuationEdit] {
        guard !edits.isEmpty else { return [] }
        let before = render(text, flavor: flavor)
        let preserving = edits.filter { !mayChangeRendering($0) }
        // Usually every fix keeps the rendering: check them together, then one by one only if not
        if preserving.isEmpty || render(apply(preserving, to: text), flavor: flavor) == before { return edits }
        return edits.filter { mayChangeRendering($0) || render(apply([$0], to: text), flavor: flavor) == before }
    }

    static func render(_ text: String, flavor: MarkdownFlavor) -> String {
        let html = MarkdownHTMLRenderer.render(MarkdownDocument.parse(text, flavor: flavor))
        // Whitespace between words collapses in HTML, so runs of it don't change what's shown
        return html.replacingOccurrences(of: "[ \\t]+", with: " ", options: .regularExpression)
            .replacingOccurrences(of: " ?\\n ?", with: "\n", options: .regularExpression)
    }

    /// `text` with `edits` applied (non-overlapping, any order).
    static func apply(_ edits: [PunctuationEdit], to text: String) -> String {
        var ns = text as NSString
        for edit in edits.sorted(by: { $0.range.location > $1.range.location }) {
            ns = ns.replacingCharacters(in: edit.range, with: edit.replacement) as NSString
        }
        return ns as String
    }

    // MARK: - Lines

    /// The whole lines `range` covers, without the final newline.
    static func lineSpan(of range: NSRange, in ns: NSString) -> NSRange {
        var start = min(range.location, ns.length)
        while start > 0, ns.character(at: start - 1) != newline { start -= 1 }
        var end = max(start, min(NSMaxRange(range), ns.length))
        if end > start, ns.character(at: end - 1) == newline { end -= 1 }
        while end < ns.length, ns.character(at: end) != newline { end += 1 }
        return NSRange(location: start, length: end - start)
    }

    /// Each line of `span` (without newlines).
    static func lines(in span: NSRange, of ns: NSString) -> [NSRange] {
        var result: [NSRange] = []
        var start = span.location
        var i = span.location
        while i < NSMaxRange(span) {
            if ns.character(at: i) == newline {
                result.append(NSRange(location: start, length: i - start))
                start = i + 1
            }
            i += 1
        }
        result.append(NSRange(location: start, length: NSMaxRange(span) - start))
        return result
    }

    private static let newline: unichar = 0x0A
    private static let space: unichar = 0x20
    private static let tab: unichar = 0x09

    private static func isBlank(_ line: NSRange, in ns: NSString) -> Bool {
        (0..<line.length).allSatisfy { let c = ns.character(at: line.location + $0); return c == space || c == tab }
    }

    private static func isLetter(_ c: unichar) -> Bool {
        guard let scalar = Unicode.Scalar(c) else { return false }
        return CharacterSet.letters.contains(scalar)
    }

    private static func isWordCharacter(_ c: unichar) -> Bool {
        guard let scalar = Unicode.Scalar(c) else { return false }
        return CharacterSet.alphanumerics.contains(scalar)
    }

    /// Every node under `node`, depth first.
    private static func descendants(of node: MarkdownNode) -> [MarkdownNode] {
        var out: [MarkdownNode] = []
        var stack = Array(node.children.reversed())
        while let next = stack.popLast() {
            out.append(next)
            stack.append(contentsOf: next.children.reversed())
        }
        return out
    }

    /// Paragraphs and headings in `block`, the only places prose fixes go.
    private static func proseBlocks(in block: MarkdownNode) -> [MarkdownNode] {
        ([block] + descendants(of: block)).filter {
            switch $0.kind {
            case .paragraph, .heading: return !$0.ancestors.contains { if case .table = $0.kind { return true }; return false }
            default: return false
            }
        }
    }

    // MARK: - Headings

    private static func headingEdits(_ block: MarkdownNode, ns: NSString) -> [PunctuationEdit] {
        let line = lineSpan(of: block.range, in: ns)
        let source = ns.substring(with: line)
        switch block.kind {
        case .heading(_, let setext) where !setext:
            // "#  Title ##" or "# Title." → "# Title"
            guard let match = source.range(of: "^( {0,3})(#{1,6})[ \\t]+(.*?)[ \\t]*$", options: .regularExpression) else { return [] }
            let parts = source[match]
            guard let hashes = parts.range(of: "#{1,6}", options: .regularExpression) else { return [] }
            let indent = String(parts[parts.startIndex..<hashes.lowerBound])
            var content = String(parts[hashes.upperBound...]).trimmingCharacters(in: .whitespaces)
            // Closing sequence: spaces then only #s
            if let closing = content.range(of: "(^|[ \\t]+)#+$", options: .regularExpression) {
                content.removeSubrange(closing)
            }
            if content.hasSuffix("."), !content.hasSuffix(".."), !endsWithAbbreviation(content) {
                content.removeLast()
            }
            guard !content.isEmpty else { return [] }
            let replacement = indent + String(parts[hashes]) + " " + content
            guard replacement != source else { return [] }
            return [PunctuationEdit(range: line, replacement: replacement, rules: [.formatHeadings])]
        case .paragraph:
            // "#Heading" on a line of its own was meant as a heading; "#tag" is left alone
            guard !source.contains("\n"),
                  let match = source.range(of: "^#{1,6}(?=[\\p{L}])", options: .regularExpression) else { return [] }
            let hashes = source[match]
            let rest = source[match.upperBound...]
            guard hashes.count > 1 || rest.first?.isUppercase == true, rest.contains(" ") || rest.count > 1,
                  !rest.contains("#") else { return [] }
            return [PunctuationEdit(range: NSRange(location: line.location + (String(hashes) as NSString).length, length: 0),
                                    replacement: " ", rules: [.formatHeadings])]
        default:
            return []
        }
    }

    /// Copyedit's auto-formatting (#229): a top-level paragraph that is one short line with no
    /// closing punctuation and no markup, set apart by blank lines, and followed by a longer
    /// paragraph or list that it introduces, becomes a heading. Its level follows the nearest
    /// heading before it (a sibling section, or `##` under a `#` title), else `#` at the top of the
    /// document and `##` below.
    /// Greetings and sign-offs ("Hi Sam", "Thanks") are left alone.
    private static func titleLineEdit(_ blocks: [MarkdownNode], index: Int, ns: NSString) -> PunctuationEdit? {
        let block = blocks[index]
        guard case .paragraph = block.kind, index + 1 < blocks.count,
              block.children.allSatisfy(isPlainText) else { return nil }
        let line = lineSpan(of: block.range, in: ns)
        let source = ns.substring(with: line)
        let title = source.trimmingCharacters(in: .whitespaces)
        guard !title.isEmpty, !source.hasPrefix(" "), !title.contains("\n"), title.count <= 60,
              let first = title.first, first.isUppercase,
              let last = title.unicodeScalars.last,
              !CharacterSet(charactersIn: ".,:;!?…)]\"'”’-–—*_`").contains(last) else { return nil }
        let words = title.split(separator: " ")
        guard (1...8).contains(words.count), !title.contains(","),
              !title.contains(where: \.isNumber) || words.count > 1 else { return nil }
        let lower = words.first.map { $0.lowercased() } ?? ""
        let openers: Set<String> = ["hi", "hello", "hey", "dear", "thanks", "thank", "cheers", "best", "regards",
                                    "love", "sincerely", "yours", "kind", "warm", "ok", "okay", "yes", "no", "sure"]
        guard !openers.contains(lower) else { return nil }

        // Blank lines on both sides: a line straight after a paragraph is part of it
        let next = blocks[index + 1]
        guard hasBlankLine(between: block, and: next, ns: ns),
              index == 0 || hasBlankLine(between: blocks[index - 1], and: block, ns: ns) else { return nil }
        // What follows is the text it introduces, longer than it
        switch next.kind {
        case .paragraph:
            let body = ns.substring(with: next.range).trimmingCharacters(in: .whitespacesAndNewlines)
            guard body.count >= max(2 * title.count, 24) else { return nil }
        case .list:
            break
        default:
            return nil
        }

        let level: Int
        if let previous = blocks[..<index].last(where: { if case .heading = $0.kind { return true }; return false }),
           case .heading(let previousLevel, _) = previous.kind {
            // Under the document's title (`#`) a section is `##`; otherwise a sibling of the last one
            level = previousLevel == 1 ? 2 : previousLevel
        } else {
            level = index == 0 ? 1 : 2
        }
        return PunctuationEdit(range: NSRange(location: line.location, length: 0),
                               replacement: String(repeating: "#", count: level) + " ", rules: [.formatTitleLines])
    }

    /// Whether a blank line separates `a` and `b`.
    private static func hasBlankLine(between a: MarkdownNode, and b: MarkdownNode, ns: NSString) -> Bool {
        let start = NSMaxRange(lineSpan(of: a.range, in: ns))
        let end = lineSpan(of: b.range, in: ns).location
        guard end > start else { return false }
        return ns.substring(with: NSRange(location: start, length: end - start)).filter { $0 == "\n" }.count >= 2
    }

    private static func endsWithAbbreviation(_ text: String) -> Bool {
        let word = text.split(separator: " ").last.map { String($0).lowercased() } ?? ""
        return ["etc.", "e.g.", "i.e.", "inc.", "ltd.", "co.", "vs.", "st.", "dr.", "mr.", "mrs.", "ms.", "jr.", "sr."].contains(word)
            || word.range(of: "^([a-z]\\.)+$", options: .regularExpression) != nil
    }

    // MARK: - Lists

    private struct ItemMarker {
        var item: MarkdownNode
        var line: NSRange
        var indent: Int
        /// The bullet or number with its delimiter.
        var marker: NSRange
    }

    private static func itemMarkers(_ list: MarkdownNode, ns: NSString) -> [ItemMarker] {
        list.children.compactMap { item in
            let line = lineSpan(of: NSRange(location: item.range.location, length: 0), in: ns)
            var i = line.location
            while i < NSMaxRange(line), ns.character(at: i) == space { i += 1 }
            let indentStart = i
            var j = i
            while j < NSMaxRange(line) {
                let c = ns.character(at: j)
                if c >= 0x30 && c <= 0x39 { j += 1; continue }
                if c == 0x2D || c == 0x2A || c == 0x2B { j += 1; break }
                if (c == 0x2E || c == 0x29) && j > i { j += 1; break }
                return nil
            }
            guard j > i, j <= NSMaxRange(line) else { return nil }
            return ItemMarker(item: item, line: line, indent: indentStart - line.location, marker: NSRange(location: i, length: j - i))
        }
    }

    /// One line per item, with nothing nested under it.
    private static func isSingleLine(_ item: MarkdownNode, ns: NSString) -> Bool {
        let span = lineSpan(of: item.range, in: ns)
        return !ns.substring(with: span).contains("\n")
    }

    private static func listEdits(_ block: MarkdownNode, ns: NSString, siblings: [MarkdownNode], index: Int, caretBlock: Int?) -> [PunctuationEdit] {
        var edits: [PunctuationEdit] = []
        let lists = ([block] + descendants(of: block)).filter { if case .list = $0.kind { return true }; return false }
        for list in lists {
            guard case .list(let ordered, let start, _, let bullet, _) = list.kind else { continue }
            let markers = itemMarkers(list, ns: ns)
            guard markers.count == list.children.count, let first = markers.first else { continue }

            // Consistent indentation: an item a space or two out of line with the first, on a line of its own
            for marker in markers.dropFirst() where marker.indent != first.indent && marker.indent <= 3 && first.indent <= 3
                && isSingleLine(marker.item, ns: ns) {
                edits.append(PunctuationEdit(range: NSRange(location: marker.line.location, length: marker.indent),
                                             replacement: String(repeating: " ", count: first.indent), rules: [.formatLists]))
            }

            if ordered {
                // Renumber after an insert or a delete; "1. 1. 1." is deliberate and stays
                let numbers = markers.map { Int(ns.substring(with: NSRange(location: $0.marker.location, length: $0.marker.length - 1))) ?? -1 }
                let allSame = Set(numbers).count == 1
                let sequential = numbers.enumerated().allSatisfy { $0.element == start + $0.offset }
                if !allSame, !sequential {
                    for (offset, marker) in markers.enumerated() {
                        let wanted = start + offset
                        guard numbers[offset] != wanted else { continue }
                        let digits = String(wanted)
                        let old = marker.marker.length - 1
                        if digits.count != old, !isSingleLine(marker.item, ns: ns) { continue }
                        edits.append(PunctuationEdit(range: NSRange(location: marker.marker.location, length: old),
                                                     replacement: digits, rules: [.formatLists]))
                    }
                }
            } else if list === block {
                // A bullet list right after one with another bullet, with no blank line between, is
                // the same list to the person: give it the first list's bullet
                guard let previous = list.previousSibling, case .list(false, _, _, let previousBullet, true) = previous.kind,
                      previousBullet != bullet, case .list(false, _, _, _, true) = list.kind else { continue }
                if let caretBlock, caretBlock == index - 1 { continue }
                let gapStart = NSMaxRange(lineSpan(of: previous.range, in: ns))
                let gapEnd = lineSpan(of: NSRange(location: list.range.location, length: 0), in: ns).location
                guard gapEnd - gapStart <= 1 else { continue }
                for marker in markers {
                    edits.append(PunctuationEdit(range: marker.marker, replacement: String(previousBullet), rules: [.formatLists]))
                }
            }
        }
        return edits
    }

    // MARK: - Tasks

    private static func taskEdits(_ block: MarkdownNode, ns: NSString, siblings: [MarkdownNode], index: Int) -> [PunctuationEdit] {
        var edits: [PunctuationEdit] = []
        let lists = ([block] + descendants(of: block)).filter { if case .list(false, _, _, _, _) = $0.kind { return true }; return false }
        for list in lists {
            guard case .list(_, _, _, let bullet, _) = list.kind else { continue }
            let markers = itemMarkers(list, ns: ns)
            guard markers.count == list.children.count else { continue }
            var allTasks = true
            for marker in markers {
                // "[]", "[ ]", "[x]" or "[X]" just after the bullet
                let after = NSMaxRange(marker.marker)
                let rest = ns.substring(with: NSRange(location: after, length: NSMaxRange(marker.line) - after))
                guard let match = rest.range(of: "^ +\\[( ?|x|X)\\](?= |$)", options: .regularExpression) else {
                    allTasks = false
                    continue
                }
                let box = String(rest[match]).trimmingCharacters(in: .whitespaces)
                let wanted = box == "[X]" || box == "[x]" ? "[x]" : "[ ]"
                if box != wanted {
                    let offset = (String(rest[rest.startIndex..<match.lowerBound]) as NSString).length
                        + (String(rest[match]) as NSString).length - (box as NSString).length
                    edits.append(PunctuationEdit(range: NSRange(location: after + offset, length: (box as NSString).length),
                                                 replacement: wanted, rules: [.formatTasks]))
                }
            }
            // A task list takes "-" bullets, unless that would join it to a neighbouring list
            guard allTasks, bullet != "-" else { continue }
            let neighbours = [list.previousSibling, list.nextSibling].compactMap { $0 }
            if neighbours.contains(where: { if case .list(false, _, _, _, _) = $0.kind { return true }; return false }) { continue }
            for marker in markers {
                edits.append(PunctuationEdit(range: marker.marker, replacement: "-", rules: [.formatTasks]))
            }
        }
        return edits
    }

    // MARK: - Spacing

    /// The gap between two top-level blocks: runs of blank lines become one, and headings, lists,
    /// quotes and code blocks get a blank line before and after.
    private static func gapEdit(between a: MarkdownNode, and b: MarkdownNode, ns: NSString, caret: Int?) -> PunctuationEdit? {
        let aEnd = NSMaxRange(lineSpan(of: a.range, in: ns))
        let bStart = lineSpan(of: NSRange(location: b.range.location, length: 0), in: ns).location
        guard aEnd < bStart, aEnd < ns.length else { return nil }
        let gap = NSRange(location: aEnd, length: bStart - aEnd)
        if let caret, caret >= gap.location, caret <= NSMaxRange(gap) { return nil }
        let gapText = ns.substring(with: gap)
        guard gapText.allSatisfy({ $0 == "\n" || $0 == " " || $0 == "\t" }) else { return nil }
        let blankLines = gapText.filter { $0 == "\n" }.count - 1
        let kinds = [a.kind, b.kind]
        if kinds.contains(where: { if case .frontMatter = $0 { return true }; if case .htmlBlock = $0 { return true }
            if case .linkReferenceDefinition = $0 { return true }; return false }) { return nil }
        let wantsBlank = kinds.contains { kind in
            switch kind {
            case .heading, .list, .blockQuote, .alert, .codeBlock, .table: return true
            default: return false
            }
        }
        // Two lists side by side are one list in waiting (see listEdits), not a gap to open
        if case .list = a.kind, case .list = b.kind, blankLines == 0 { return nil }
        if blankLines == 0, wantsBlank {
            return PunctuationEdit(range: gap, replacement: "\n\n", rules: [.formatSpacing])
        }
        if blankLines >= 1, gapText != "\n\n" {
            return PunctuationEdit(range: gap, replacement: "\n\n", rules: [.formatSpacing])
        }
        return nil
    }

    private static func spacingEdits(_ block: MarkdownNode, ns: NSString) -> [PunctuationEdit] {
        var edits: [PunctuationEdit] = []
        for prose in proseBlocks(in: block) {
            let span = lineSpan(of: prose.range, in: ns)
            let proseLines = lines(in: span, of: ns)
            for (offset, line) in proseLines.enumerated() {
                // Trailing spaces, keeping a deliberate two-space line break inside a paragraph
                var end = NSMaxRange(line)
                while end > line.location, ns.character(at: end - 1) == space || ns.character(at: end - 1) == tab { end -= 1 }
                let trailing = NSMaxRange(line) - end
                let isLast = offset == proseLines.count - 1
                let inSpan = node(at: end, under: prose).ancestors.contains { ancestor in
                    switch ancestor.kind {
                    case .code, .math, .htmlInline: return true
                    default: return false
                    }
                } || { if case .code = node(at: end, under: prose).kind { return true }; return false }()
                if trailing > 0, end > line.location, isLast || trailing == 1, !inSpan {
                    edits.append(PunctuationEdit(range: NSRange(location: end, length: trailing), replacement: "", rules: [.formatSpacing]))
                }
            }
            // Runs of spaces between words in the text itself
            for text in descendants(of: prose) where isPlainText(text) {
                var i = text.range.location
                let limit = min(NSMaxRange(text.range), ns.length)
                while i < limit {
                    guard ns.character(at: i) == space else { i += 1; continue }
                    var j = i
                    while j < limit, ns.character(at: j) == space { j += 1 }
                    if j - i >= 2, i > 0, j < ns.length,
                       ns.character(at: i - 1) != space, ns.character(at: i - 1) != newline, ns.character(at: i - 1) != tab,
                       ns.character(at: j) != newline, ns.character(at: j) != space {
                        edits.append(PunctuationEdit(range: NSRange(location: i, length: j - i), replacement: " ", rules: [.formatSpacing]))
                    }
                    i = j
                }
            }
        }
        return edits
    }

    private static func isPlainText(_ node: MarkdownNode) -> Bool {
        guard case .text = node.kind else { return false }
        return !node.ancestors.contains { ancestor in
            switch ancestor.kind {
            case .code, .codeBlock, .math, .htmlInline, .htmlBlock, .link, .image, .table, .tableCell, .frontMatter: return true
            default: return false
            }
        }
    }

    private static let strayMarkerPattern = try! NSRegularExpression(
        pattern: "(?<![\\\\*_~\\p{L}\\p{N}])(\\*\\*|__|~~)( *)([^\\s*_~](?:[^*_~\\n]*?[^\\s*_~])?)( *)\\1(?![*_~\\p{L}\\p{N}])")

    private static func strayMarkerSpaceEdits(line: NSRange, ns: NSString, prose: MarkdownNode) -> [PunctuationEdit] {
        var edits: [PunctuationEdit] = []
        for match in strayMarkerPattern.matches(in: ns as String, range: line) {
            let leading = match.range(at: 2)
            let trailing = match.range(at: 4)
            guard leading.length > 0 || trailing.length > 0 else { continue }
            let inner = ns.substring(with: match.range(at: 3))
            guard inner.rangeOfCharacter(from: .letters) != nil else { continue }
            // Only where the markers are plain text (they didn't parse as emphasis)
            let node = node(at: match.range.location, under: prose)
            guard case .text = node.kind, isPlainText(node) else { continue }
            let marker = ns.substring(with: match.range(at: 1))
            edits.append(PunctuationEdit(range: match.range, replacement: marker + inner + marker, rules: [.formatSpans]))
        }
        return edits
    }

    // MARK: - Span wrapping

    private static func spanEdits(_ block: MarkdownNode, ns: NSString) -> [PunctuationEdit] {
        var edits: [PunctuationEdit] = []
        for prose in proseBlocks(in: block) {
            for node in descendants(of: prose) {
                switch node.kind {
                case .code, .emphasis, .strong, .strikethrough: break
                default: continue
                }
                guard !node.ancestors.contains(where: { if case .link = $0.kind { return true }; if case .image = $0.kind { return true }; return false }),
                      NSMaxRange(node.range) <= ns.length, node.range.length >= 3 else { continue }
                let open = openingMarker(of: node, ns: ns)
                let close = closingMarker(of: node, ns: ns)
                guard open.length > 0, close.length > 0, NSMaxRange(open) <= close.location else { continue }
                let markerChar = ns.character(at: node.range.location)
                if markerChar == 0x5F { continue } // "_" emphasis can't be inside a word
                let inner = NSRange(location: NSMaxRange(open), length: close.location - NSMaxRange(open))
                guard inner.length > 0 else { continue }
                if let edit = wrapEdit(span: node.range, open: open, inner: inner, close: close, ns: ns,
                                       isCode: { if case .code = node.kind { return true }; return false }()) {
                    edits.append(edit)
                }
            }
            edits += htmlWrapEdits(prose, ns: ns)
            // Spaces just inside ** … **, __ … __ and ~~ … ~~ that kept them from being markers
            for line in lines(in: lineSpan(of: prose.range, in: ns), of: ns) {
                edits += strayMarkerSpaceEdits(line: line, ns: ns, prose: prose)
            }
        }
        return edits
    }

    private static func openingMarker(of node: MarkdownNode, ns: NSString) -> NSRange {
        let first = ns.character(at: node.range.location)
        var end = node.range.location
        while end < NSMaxRange(node.range), ns.character(at: end) == first { end += 1 }
        return NSRange(location: node.range.location, length: end - node.range.location)
    }

    private static func closingMarker(of node: MarkdownNode, ns: NSString) -> NSRange {
        let last = ns.character(at: NSMaxRange(node.range) - 1)
        var start = NSMaxRange(node.range)
        while start > node.range.location, ns.character(at: start - 1) == last { start -= 1 }
        return NSRange(location: start, length: NSMaxRange(node.range) - start)
    }

    /// A span that splits a word (`` `hell`o ``, `h**ello**`) widened to wrap the whole word, keeping
    /// deliberate suffixes outside (`` `int`s ``, `` `foo`'s ``, `` `foo`-bar ``).
    private static func wrapEdit(span: NSRange, open: NSRange, inner: NSRange, close: NSRange, ns: NSString, isCode: Bool) -> PunctuationEdit? {
        var after = NSMaxRange(span)
        while after < ns.length, isLetter(ns.character(at: after)) { after += 1 }
        var before = span.location
        while before > 0, isLetter(ns.character(at: before - 1)) { before -= 1 }
        let suffix = NSRange(location: NSMaxRange(span), length: after - NSMaxRange(span))
        let prefix = NSRange(location: before, length: span.location - before)
        let openText = ns.substring(with: open)
        let innerText = ns.substring(with: inner)
        let closeText = ns.substring(with: close)
        if suffix.length > 0, prefix.length == 0 {
            let tail = ns.substring(with: suffix)
            guard !["s", "es"].contains(tail), isLetter(ns.character(at: NSMaxRange(inner) - 1)) else { return nil }
            // Not "word"s' or similar: the word must end after the suffix
            if after < ns.length, ns.character(at: after) == 0x27 || ns.character(at: after) == 0x2019 || isWordCharacter(ns.character(at: after)) { return nil }
            if isCode, innerText.contains(" ") { return nil }
            return PunctuationEdit(range: NSUnionRange(span, suffix), replacement: openText + innerText + tail + closeText, rules: [.formatSpans])
        }
        if prefix.length > 0, suffix.length == 0 {
            let head = ns.substring(with: prefix)
            guard isLetter(ns.character(at: inner.location)) else { return nil }
            if before > 0, isWordCharacter(ns.character(at: before - 1)) || ns.character(at: before - 1) == 0x27 { return nil }
            if NSMaxRange(span) < ns.length, isWordCharacter(ns.character(at: NSMaxRange(span))) { return nil }
            if isCode, innerText.contains(" ") { return nil }
            return PunctuationEdit(range: NSUnionRange(prefix, span), replacement: openText + head + innerText + closeText, rules: [.formatSpans])
        }
        return nil
    }

    private static let htmlSpanPattern = try! NSRegularExpression(
        pattern: "<(em|strong|b|i|u|s|del|ins|mark|code|kbd|sub|sup|small)>([^<>\\n]+)</\\1>", options: [.caseInsensitive])

    private static func htmlWrapEdits(_ prose: MarkdownNode, ns: NSString) -> [PunctuationEdit] {
        let span = lineSpan(of: prose.range, in: ns)
        var edits: [PunctuationEdit] = []
        for match in htmlSpanPattern.matches(in: ns as String, range: span) {
            // Both tags must be inline HTML in this paragraph, not text in code
            let openTag = descendants(of: prose).first { if case .htmlInline = $0.kind { return $0.range.location == match.range.location }; return false }
            guard openTag != nil else { continue }
            let tag = ns.substring(with: match.range(at: 1))
            let open = NSRange(location: match.range.location, length: (tag as NSString).length + 2)
            let close = NSRange(location: NSMaxRange(match.range) - (tag as NSString).length - 3, length: (tag as NSString).length + 3)
            if let edit = wrapEdit(span: match.range, open: open, inner: match.range(at: 2), close: close, ns: ns, isCode: tag.lowercased() == "code") {
                edits.append(edit)
            }
        }
        return edits
    }

    // MARK: - Emphasis

    /// The emphasis marker the document already uses most: `*` or `_`, or nil when it has none.
    static func documentEmphasisMarker(_ root: MarkdownNode, ns: NSString) -> unichar? {
        var stars = 0
        var underscores = 0
        for node in descendants(of: root) {
            guard case .emphasis = node.kind, node.range.location < ns.length else { continue }
            if node.ancestors.contains(where: { if case .codeBlock = $0.kind { return true }; return false }) { continue }
            let c = ns.character(at: node.range.location)
            if c == 0x2A { stars += 1 } else if c == 0x5F { underscores += 1 }
        }
        if stars == 0 && underscores == 0 { return nil }
        return underscores > stars ? 0x5F : 0x2A
    }

    private static func emphasisEdits(_ block: MarkdownNode, ns: NSString, marker: unichar) -> [PunctuationEdit] {
        var edits: [PunctuationEdit] = []
        let wanted = String(utf16CodeUnits: [marker], count: 1)
        for node in descendants(of: block) {
            guard case .emphasis = node.kind, node.range.length >= 3, NSMaxRange(node.range) <= ns.length else { continue }
            let first = ns.character(at: node.range.location)
            let last = ns.character(at: NSMaxRange(node.range) - 1)
            guard first == last, first != marker, first == 0x2A || first == 0x5F else { continue }
            // A single marker each side (not "***both***"), and no wanted marker inside to pair with
            guard ns.character(at: node.range.location + 1) != first, ns.character(at: NSMaxRange(node.range) - 2) != first else { continue }
            let inner = ns.substring(with: NSRange(location: node.range.location + 1, length: node.range.length - 2))
            guard !inner.contains(wanted) else { continue }
            // Nor one just outside, which would join it into a strong marker ("*_foo_*")
            if node.range.location > 0, ns.character(at: node.range.location - 1) == marker { continue }
            if NSMaxRange(node.range) < ns.length, ns.character(at: NSMaxRange(node.range)) == marker { continue }
            if marker == 0x5F {
                // "_" can't open or close inside a word
                if node.range.location > 0, isWordCharacter(ns.character(at: node.range.location - 1)) { continue }
                if NSMaxRange(node.range) < ns.length, isWordCharacter(ns.character(at: NSMaxRange(node.range))) { continue }
            }
            edits.append(PunctuationEdit(range: node.range, replacement: wanted + inner + wanted, rules: [.formatEmphasis]))
        }
        return edits
    }

    // MARK: - Tables

    private static func tableEdits(_ block: MarkdownNode, ns: NSString) -> [PunctuationEdit] {
        guard case .table(let alignments) = block.kind else { return [] }
        let span = lineSpan(of: block.range, in: ns)
        let rows = lines(in: span, of: ns).map { ns.substring(with: $0) }
        guard rows.count >= 2, rows.allSatisfy({ !$0.hasPrefix(" ") && !$0.hasPrefix("\t") }) else { return [] }
        let cells = rows.map(splitRow)
        let columns = alignments.count
        guard columns > 0, cells[1].count == columns, cells.allSatisfy({ $0.count <= columns }), cells[0].count == columns else { return [] }
        var widths = Array(repeating: 3, count: columns)
        for (index, row) in cells.enumerated() where index != 1 {
            for (column, cell) in row.enumerated() { widths[column] = max(widths[column], cell.count) }
        }
        func pad(_ cell: String, _ column: Int) -> String {
            let room = widths[column] - cell.count
            switch alignments[column] {
            case .right: return String(repeating: " ", count: room) + cell
            case .center: return String(repeating: " ", count: room / 2) + cell + String(repeating: " ", count: room - room / 2)
            default: return cell + String(repeating: " ", count: room)
            }
        }
        var out: [String] = []
        for (index, row) in cells.enumerated() {
            if index == 1 {
                let delimiters = (0..<columns).map { column -> String in
                    let width = widths[column]
                    switch alignments[column] {
                    case .left: return ":" + String(repeating: "-", count: width - 1)
                    case .right: return String(repeating: "-", count: width - 1) + ":"
                    case .center: return ":" + String(repeating: "-", count: width - 2) + ":"
                    case .defaultAlignment: return String(repeating: "-", count: width)
                    }
                }
                out.append("| " + delimiters.joined(separator: " | ") + " |")
            } else {
                let filled = row + Array(repeating: "", count: columns - row.count)
                out.append("| " + filled.enumerated().map { pad($0.element, $0.offset) }.joined(separator: " | ") + " |")
            }
        }
        let replacement = out.joined(separator: "\n")
        guard replacement != ns.substring(with: span) else { return [] }
        return [PunctuationEdit(range: span, replacement: replacement, rules: [.formatTables])]
    }

    /// A table row's cells, trimmed, split at pipes that aren't escaped.
    static func splitRow(_ row: String) -> [String] {
        var cells: [String] = []
        var current = ""
        var escaped = false
        for character in row {
            if escaped { current.append(character); escaped = false; continue }
            if character == "\\" { current.append(character); escaped = true; continue }
            if character == "|" { cells.append(current); current = ""; continue }
            current.append(character)
        }
        cells.append(current)
        var trimmed = cells.map { $0.trimmingCharacters(in: .whitespaces) }
        if trimmed.first == "", row.trimmingCharacters(in: .whitespaces).hasPrefix("|") { trimmed.removeFirst() }
        if trimmed.last == "", row.trimmingCharacters(in: .whitespaces).hasSuffix("|"), !row.trimmingCharacters(in: .whitespaces).hasSuffix("\\|") { trimmed.removeLast() }
        return trimmed
    }

    // MARK: - Links

    private static func linkEdits(_ block: MarkdownNode, ns: NSString, flavor: MarkdownFlavor) -> [PunctuationEdit] {
        var edits: [PunctuationEdit] = []
        for prose in proseBlocks(in: block) {
            guard case .paragraph = prose.kind else { continue }
            let span = lineSpan(of: prose.range, in: ns)
            let line = ns.substring(with: span)
            guard let match = line.range(of: "(?<=^|[ >*+-]|\\d[.)])\\s*https?://[^\\s<>]+$", options: .regularExpression) else { continue }
            let url = line[match].trimmingCharacters(in: .whitespaces)
            // The paragraph is the URL alone
            guard prose.range.location == span.location + (String(line[line.startIndex..<match.lowerBound]) as NSString).length
                    + (String(line[match]) as NSString).length - (url as NSString).length,
                  let last = url.unicodeScalars.last, !CharacterSet(charactersIn: ".,:;!?)'\"*_~").contains(last) else { continue }
            let location = NSMaxRange(span) - (url as NSString).length
            edits.append(PunctuationEdit(range: NSRange(location: location, length: (url as NSString).length),
                                         replacement: "<\(url)>", rules: [.formatLinks]))
        }
        return edits
    }

    /// The deepest node at `location` under `root`.
    private static func node(at location: Int, under root: MarkdownNode) -> MarkdownNode {
        var node = root
        descend: while true {
            for child in node.children where NSLocationInRange(location, child.range) {
                node = child
                continue descend
            }
            return node
        }
    }
}

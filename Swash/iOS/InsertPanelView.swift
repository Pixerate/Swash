//
//  InsertPanelView.swift
//  Swash
//
//  The Insert panel (tables, callouts, code, math, Mermaid, images) for iOS and iPadOS, and
//  the Markdown it inserts.
//

#if os(iOS)
import SwiftUI
import UIKit
import PixerateMarkdown

/// Block insert types available in the Insert panel.
public enum BlockInsertKind: String, CaseIterable, Identifiable, Sendable {
    case table
    case callout
    case codeBlock
    case math
    case mermaid
    case image

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .table: return "Table"
        case .callout: return "Callout"
        case .codeBlock: return "Code Block"
        case .math: return "Math"
        case .mermaid: return "Mermaid"
        case .image: return "Image"
        }
    }

    public var symbolName: String {
        switch self {
        case .table: return "tablecells"
        case .callout: return "info.circle"
        case .codeBlock: return "curlybraces"
        case .math: return "function"
        case .mermaid: return "point.3.connected.trianglepath.dotted"
        case .image: return "photo"
        }
    }
}

// MARK: - Block Insertion Command

extension MarkdownEditingCommands {
    /// Inserts a block template of the given kind at the line holding `location`. A blank line is
    /// replaced by the block; after a line with text, the block goes below it, so nothing is lost.
    /// Blank lines separate the block from text above and below it, so a table or callout doesn't
    /// take the next paragraph in as a row or a lazy continuation, and an image isn't inline.
    ///
    /// The Insert panel's own kinds rather than `BlockInsert` (the "/" menu's): that one has no
    /// math, Mermaid or image, and `insertBlock(_:text:slashLocation:)` needs a typed "/".
    static func insertBlock(_ kind: BlockInsertKind, text: String, at location: Int) -> MarkdownEdit {
        let ns = text as NSString
        let boundedLocation = max(0, min(location, ns.length))
        var lineStart = 0
        var lineEnd = 0
        var contentsEnd = 0
        ns.getLineStart(&lineStart, end: &lineEnd, contentsEnd: &contentsEnd, for: NSRange(location: boundedLocation, length: 0))
        let lineText = ns.substring(with: NSRange(location: lineStart, length: contentsEnd - lineStart))
        let structure = MarkdownFormatting.structure(of: lineText)
        let prefix = structure.quotePrefix + structure.indent
        // A blank line inside a quote keeps its ">" so the block stays in the quote
        let separator = structure.quotePrefix.trimmingCharacters(in: .whitespaces)

        let (blockText, caretOffset) = template(kind, prefix: prefix)

        let replacesLine = isBlank(lineText) || (structure.content.trimmingCharacters(in: .whitespaces).isEmpty && !isHeading(structure))
        let target: NSRange
        var leading = ""
        if replacesLine {
            target = NSRange(location: lineStart, length: contentsEnd - lineStart)
            if lineStart > 0, !isBlank(line(before: lineStart, in: ns)) { leading = separator + "\n" }
        } else {
            // Below the line, after a blank one
            target = NSRange(location: contentsEnd, length: 0)
            leading = "\n" + separator + "\n"
        }
        // The line after the target, if any: a blank one already separates the block
        var trailing = ""
        if lineEnd < ns.length {
            var nextEnd = 0, nextContentsEnd = 0
            ns.getLineStart(nil, end: &nextEnd, contentsEnd: &nextContentsEnd, for: NSRange(location: lineEnd, length: 0))
            let next = ns.substring(with: NSRange(location: lineEnd, length: nextContentsEnd - lineEnd))
            if !isBlank(next) { trailing = "\n" + separator }
        }

        let inserted = leading + blockText + trailing
        let edited = ns.replacingCharacters(in: target, with: inserted)
        let caret = target.location + (leading as NSString).length + caretOffset
        return MarkdownEdit(text: edited, selection: NSRange(location: caret, length: 0))
    }

    /// The block's Markdown, each line starting with `prefix`, and the caret's offset in it.
    private static func template(_ kind: BlockInsertKind, prefix: String) -> (text: String, caret: Int) {
        func length(_ string: String) -> Int { (string as NSString).length }
        switch kind {
        case .table:
            let header = prefix + "| Column 1 | Column 2 |"
            let separator = prefix + "| --- | --- |"
            let row = prefix + "|  |  |"
            return ("\(header)\n\(separator)\n\(row)", length(header + "\n" + separator + "\n" + prefix + "| "))
        case .callout:
            let open = prefix + "> [!NOTE]\n" + prefix + "> "
            return (open, length(open))
        case .codeBlock:
            let open = prefix + "```\n" + prefix
            return (open + "\n" + prefix + "```", length(open))
        case .math:
            let open = prefix + "$$\n" + prefix
            return (open + "\n" + prefix + "$$", length(open))
        case .mermaid:
            let open = prefix + "```mermaid\n" + prefix + "graph TD\n" + prefix + "    "
            return (open + "\n" + prefix + "```", length(open))
        case .image:
            return (prefix + "![Image]()", length(prefix + "![Image]("))
        }
    }

    /// Blank, or only a quote marker: a line that already separates blocks.
    private static func isBlank(_ line: String) -> Bool {
        let structure = MarkdownFormatting.structure(of: line)
        return structure.marker.trimmingCharacters(in: .whitespaces).isEmpty
            && structure.content.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private static func isHeading(_ structure: MarkdownFormatting.LineStructure) -> Bool {
        if case .heading = structure.format { return true }
        return false
    }

    /// The line ending just before `lineStart`.
    private static func line(before lineStart: Int, in ns: NSString) -> String {
        let previous = ns.lineRange(for: NSRange(location: lineStart - 1, length: 0))
        return ns.substring(with: previous).trimmingCharacters(in: .newlines)
    }
}

/// The insert panel shown in place of the keyboard (on iPhone and iPad alike), matching
/// FormatPanel's glass background styling (`.ultraThinMaterial`).
public struct InsertPanelView: View {
    public let onSelect: (BlockInsertKind) -> Void
    public let close: () -> Void

    private let columns = [
        GridItem(.flexible(), spacing: 12),
        GridItem(.flexible(), spacing: 12),
    ]

    public init(
        onSelect: @escaping (BlockInsertKind) -> Void = { _ in },
        close: @escaping () -> Void = {}
    ) {
        self.onSelect = onSelect
        self.close = close
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Insert")
                    .font(.headline)
                Spacer()
                Button(action: close) {
                    Image(systemName: "xmark")
                        .frame(width: 20, height: 20)
                }
                .buttonStyle(.glass)
                .buttonBorderShape(.circle)
                .accessibilityLabel("Close Insert Panel")
            }

            LazyVGrid(columns: columns, spacing: 12) {
                ForEach(BlockInsertKind.allCases) { kind in
                    Button {
                        onSelect(kind)
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: kind.symbolName)
                                .font(.system(size: 20, weight: .medium))
                                .frame(width: 28, height: 28)
                                .foregroundStyle(Color.accentColor)
                            Text(kind.title)
                                .font(.body.weight(.medium))
                                .foregroundStyle(Color.primary)
                                .lineLimit(1)
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                        .frame(maxWidth: .infinity, minHeight: 48)
                    }
                    .buttonStyle(.glass)
                    .accessibilityLabel(kind.title)
                }
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .background(.ultraThinMaterial)
    }
}

// MARK: - Previews

#Preview("Insert Panel - iPhone Light") {
    InsertPanelView()
        .frame(width: 393, height: 260)
        .preferredColorScheme(.light)
}

#Preview("Insert Panel - iPhone Dark") {
    InsertPanelView()
        .frame(width: 393, height: 260)
        .preferredColorScheme(.dark)
}

#Preview("Insert Panel - iPad Light") {
    InsertPanelView()
        .frame(width: 360, height: 260)
        .preferredColorScheme(.light)
}

#Preview("Insert Panel - iPad Dark") {
    InsertPanelView()
        .frame(width: 360, height: 260)
        .preferredColorScheme(.dark)
}
#endif

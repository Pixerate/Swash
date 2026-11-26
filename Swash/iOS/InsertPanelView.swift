//
//  InsertPanelView.swift
//  Swash
//
//  Glass-styled block insert panel and keyboard bar toggle button for iOS and iPadOS.
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
    /// Inserts a block template of the given kind replacing the line at `location`.
    public static func insertBlock(_ kind: BlockInsertKind, text: String, at location: Int) -> MarkdownEdit {
        let ns = text as NSString
        let boundedLocation = max(0, min(location, ns.length))
        var lineStart = 0
        var lineEnd = 0
        var contentsEnd = 0
        ns.getLineStart(&lineStart, end: &lineEnd, contentsEnd: &contentsEnd, for: NSRange(location: boundedLocation, length: 0))
        let lineRange = NSRange(location: lineStart, length: contentsEnd - lineStart)
        let lineText = ns.substring(with: lineRange)
        let structure = MarkdownFormatting.structure(of: lineText)
        let prefix = structure.quotePrefix + structure.indent

        let blockText: String
        let caretOffset: Int
        switch kind {
        case .table:
            let header = prefix + "| Column 1 | Column 2 |"
            let separator = prefix + "| --- | --- |"
            let row = prefix + "|  |  |"
            blockText = "\(header)\n\(separator)\n\(row)"
            caretOffset = (header + "\n" + separator + "\n" + prefix + "| ").utf16.count
        case .callout:
            let open = prefix + "> [!NOTE]\n" + prefix + "> "
            blockText = open
            caretOffset = (open as NSString).length
        case .codeBlock:
            let open = prefix + "```\n" + prefix
            blockText = open + "\n" + prefix + "```"
            caretOffset = (open as NSString).length
        case .math:
            let open = prefix + "$$\n" + prefix
            blockText = open + "\n" + prefix + "$$"
            caretOffset = (open as NSString).length
        case .mermaid:
            let open = prefix + "```mermaid\ngraph TD\n" + prefix + "    "
            blockText = open + "\n" + prefix + "```"
            caretOffset = (open as NSString).length
        case .image:
            let open = prefix + "![Image]()"
            blockText = open
            caretOffset = (prefix + "![Image](").utf16.count
        }

        let edited = ns.replacingCharacters(in: lineRange, with: blockText)
        let caret = lineRange.location + caretOffset
        return MarkdownEdit(text: edited, selection: NSRange(location: caret, length: 0))
    }
}

/// The insert panel presented in place of the keyboard on iPhone or as a popover on iPad,
/// matching FormatPanel's liquid glass background styling (`.ultraThinMaterial`).
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

/// SwiftUI component representing the editor's glass keyboard accessory bar.
public struct EditorKeyboardBarView: View {
    public var isFormatActive: Bool = false
    public var isInsertActive: Bool = false
    public var onToggleFormat: () -> Void = {}
    public var onToggleInsert: () -> Void = {}
    public var onDismissKeyboard: () -> Void = {}

    public init(
        isFormatActive: Bool = false,
        isInsertActive: Bool = false,
        onToggleFormat: @escaping () -> Void = {},
        onToggleInsert: @escaping () -> Void = {},
        onDismissKeyboard: @escaping () -> Void = {}
    ) {
        self.isFormatActive = isFormatActive
        self.isInsertActive = isInsertActive
        self.onToggleFormat = onToggleFormat
        self.onToggleInsert = onToggleInsert
        self.onDismissKeyboard = onDismissKeyboard
    }

    public var body: some View {
        HStack(spacing: 8) {
            HStack(spacing: 4) {
                Button(action: onToggleFormat) {
                    Image(systemName: "textformat")
                        .font(.body.weight(.medium))
                        .frame(width: 32, height: 32)
                        .foregroundStyle(isFormatActive ? Color.accentColor : Color.primary)
                }
                .buttonStyle(.glass)
                .accessibilityLabel("Format")
                .accessibilityAddTraits(isFormatActive ? .isSelected : [])

                Button(action: onToggleInsert) {
                    Image(systemName: "plus")
                        .font(.body.weight(.medium))
                        .frame(width: 32, height: 32)
                        .foregroundStyle(isInsertActive ? Color.accentColor : Color.primary)
                }
                .buttonStyle(.glass)
                .accessibilityLabel("Insert")
                .accessibilityAddTraits(isInsertActive ? .isSelected : [])
            }

            Spacer()

            Button(action: onDismissKeyboard) {
                Image(systemName: "keyboard.chevron.compact.down")
                    .font(.body.weight(.medium))
                    .frame(width: 32, height: 32)
                    .foregroundStyle(Color.primary)
            }
            .buttonStyle(.glass)
            .buttonBorderShape(.circle)
            .accessibilityLabel("Hide Keyboard")
        }
        .padding(.horizontal, 12)
        .frame(height: 60)
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

#Preview("Keyboard Bar - Default") {
    EditorKeyboardBarView()
        .preferredColorScheme(.light)
}

#Preview("Keyboard Bar - Insert Active") {
    EditorKeyboardBarView(isInsertActive: true)
        .preferredColorScheme(.dark)
}
#endif

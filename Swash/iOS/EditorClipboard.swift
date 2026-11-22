//
//  EditorClipboard.swift
//  Swash
//
//  Copy and paste for the iOS Edit Text editor, matching the macOS SwashNSTextView: copies carry
//  rich text (RTF and HTML) for other apps, plus the raw Markdown for Swash and plain-text apps;
//  pasted HTML or RTF is converted to Markdown.
//

#if os(iOS)
import UIKit
import UniformTypeIdentifiers
import PixerateMarkdown

enum EditorClipboard {
    /// Raw Markdown written by Swash's own copy, so copy and paste between Swash documents is lossless.
    static let swashMarkdownType = "com.pixerate.swash.markdown"

    /// Markdown to insert for the pasteboard's contents, or nil to paste its plain text as usual.
    static func markdownForPaste(from pasteboard: UIPasteboard) -> String? {
        if let data = pasteboard.data(forPasteboardType: swashMarkdownType), let own = String(data: data, encoding: .utf8) { return own }
        let plain = pasteboard.string
        var html = pasteboard.data(forPasteboardType: UTType.html.identifier).flatMap { String(data: $0, encoding: .utf8) }
        if html == nil, let rtf = pasteboard.data(forPasteboardType: UTType.rtf.identifier),
           let attributed = try? NSAttributedString(data: rtf, options: [.documentType: NSAttributedString.DocumentType.rtf], documentAttributes: nil),
           let data = try? attributed.data(from: NSRange(location: 0, length: attributed.length), documentAttributes: [.documentType: NSAttributedString.DocumentType.html]) {
            html = String(data: data, encoding: .utf8)
        }
        guard let source = html else { return nil }
        // Code editors put pre-formatted HTML on the pasteboard: keep their plain text (indentation intact)
        if plain != nil, source.range(of: "white-space:\\s*pre", options: [.regularExpression, .caseInsensitive]) != nil { return nil }
        let sourceURL = pasteboard.data(forPasteboardType: HTMLToMarkdown.chromiumSourceURLType).flatMap { String(data: $0, encoding: .utf8) }.flatMap(URL.init(string:))
        guard let markdown = HTMLToMarkdown.convert(source, sourceURL: sourceURL) else { return nil }
        // No formatting gained over the plain text: paste it as-is rather than backslash-escaped
        if let plain = plain {
            let unescaped = markdown.replacingOccurrences(of: "\\\\([\\\\*_`\\[\\]])", with: "$1", options: .regularExpression)
            func normalized(_ s: String) -> String { s.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ") }
            if normalized(unescaped) == normalized(plain) { return nil }
        }
        return markdown
    }

    /// Puts the selection on the pasteboard as rich text plus its raw Markdown.
    /// `flavor` and `folder` (the document's folder, for relative images) shape the HTML and RTF.
    static func copy(_ range: NSRange, from storage: NSTextStorage, to pasteboard: UIPasteboard = .general,
                     flavor: MarkdownFlavor = .github, folder: URL? = nil) {
        guard range.length > 0, NSMaxRange(range) <= storage.length else { return }
        // Plain text and Markdown are exactly the selection; the rich copy widens to whole list
        // items and table rows so they paste as real lists and tables.
        let raw = swashRawMarkdown(from: storage.attributedSubstring(from: range))
        let richRange = expandedRangeForClipboardCopy(in: storage, range: range)
        let richRaw = richRange == range ? raw : swashRawMarkdown(from: storage.attributedSubstring(from: richRange))
        var item: [String: Any] = [
            swashMarkdownType: Data(raw.utf8),
            UTType.utf8PlainText.identifier: raw,
        ]
        let html = DocumentExporter.clipboardHTML(for: richRaw, flavor: flavor, folder: folder)
        if let htmlData = html.data(using: .utf8) {
            item[UTType.html.identifier] = htmlData
        }
        if let rtfData = DocumentExporter.rtfData(from: html) {
            item[UTType.rtf.identifier] = rtfData
        }
        pasteboard.setItems([item])
    }
}
#endif

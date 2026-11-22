//
//  ShareContentConverter.swift
//  SwashShareExtension
//
//  Extracts and converts formatted rich text (HTML, RTF, RTFD) and Markdown from
//  NSExtensionItems into clean Markdown for Swash notes.
//

import Foundation
import UniformTypeIdentifiers
import PixerateMarkdown

#if canImport(AppKit)
import AppKit
#endif
#if canImport(UIKit)
import UIKit
#endif

public enum ShareContentConverter {
    /// Converts an HTML string to Markdown.
    /// If the converted Markdown adds no formatting over the plain text, returns the plain text
    /// to avoid unnecessary backslash escaping.
    public static func markdownFromHTML(_ html: String, plainText: String? = nil, sourceURL: URL? = nil) -> String {
        // Code editors put pre-formatted HTML on the pasteboard/share: keep plain text (indentation intact)
        if let plain = plainText, html.range(of: "white-space:\\s*pre", options: [.regularExpression, .caseInsensitive]) != nil {
            return plain
        }
        let resolvedHTML: String
        if let sourceURL = sourceURL {
            resolvedHTML = resolveRelativeURLs(in: html, baseURL: sourceURL)
        } else {
            resolvedHTML = html
        }
        guard let markdown = HTMLToMarkdown.convert(resolvedHTML, sourceURL: sourceURL) else {
            return plainText ?? html
        }
        // No formatting gained over the plain text: keep plain text as-is rather than backslash-escaped
        if let plain = plainText {
            let unescaped = markdown.replacingOccurrences(of: "\\\\([\\\\*_`\\[\\]])", with: "$1", options: .regularExpression)
            func normalized(_ s: String) -> String { s.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ") }
            if normalized(unescaped) == normalized(plain) {
                return plain
            }
        }
        return markdown
    }

    /// Resolves relative `href` and `src` links against the base page URL.
    private static func resolveRelativeURLs(in html: String, baseURL: URL) -> String {
        let pattern = #"(?<=\b(?:href|src)=["'])([^"']+)(?=["'])"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { return html }
        let ns = html as NSString
        var result = ""
        var last = 0
        for match in regex.matches(in: html, range: NSRange(location: 0, length: ns.length)) {
            result += ns.substring(with: NSRange(location: last, length: match.range.location - last))
            let relativePath = ns.substring(with: match.range)
            if !relativePath.hasPrefix("#"),
               !relativePath.hasPrefix("javascript:"),
               let url = URL(string: relativePath),
               url.scheme == nil {
                if let resolved = URL(string: relativePath, relativeTo: baseURL)?.absoluteURL.absoluteString {
                    result += resolved
                } else {
                    result += relativePath
                }
            } else {
                result += relativePath
            }
            last = NSMaxRange(match.range)
        }
        return result + ns.substring(from: last)
    }

    /// Converts RTF or RTFD data to HTML, then converts that HTML to Markdown.
    public static func markdownFromRTF(_ rtfData: Data, isRTFD: Bool = false, plainText: String? = nil, sourceURL: URL? = nil) -> String? {
        let docType = isRTFD ? NSAttributedString.DocumentType.rtfd : NSAttributedString.DocumentType.rtf
        guard let attributed = try? NSAttributedString(data: rtfData, options: [.documentType: docType], documentAttributes: nil) else {
            return nil
        }
        return markdownFromAttributedString(attributed, plainText: plainText, sourceURL: sourceURL)
    }

    /// Converts an NSAttributedString to HTML, then converts that HTML to Markdown.
    public static func markdownFromAttributedString(_ attributed: NSAttributedString, plainText: String? = nil, sourceURL: URL? = nil) -> String? {
        let plain = plainText ?? attributed.string
        guard attributed.length > 0 else { return plain }
        guard let data = try? attributed.data(from: NSRange(location: 0, length: attributed.length), documentAttributes: [.documentType: NSAttributedString.DocumentType.html]),
              let html = String(data: data, encoding: .utf8) else {
            return plain
        }
        return markdownFromHTML(html, plainText: plain, sourceURL: sourceURL)
    }

    /// Appends a source link (`[Title](url)`) under the converted text.
    public static func appendingSourceLink(to markdown: String, url: URL, title: String?) -> String {
        let trimmed = markdown.trimmingCharacters(in: .whitespacesAndNewlines)
        let linkText: String
        if let title = title?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty {
            linkText = title
        } else if let host = url.host(), !host.isEmpty {
            linkText = host
        } else if !url.lastPathComponent.isEmpty {
            linkText = url.lastPathComponent
        } else {
            linkText = url.absoluteString
        }
        let sourceLink = "[\(linkText)](\(url.absoluteString))"
        if trimmed.isEmpty {
            return sourceLink
        } else {
            return "\(trimmed)\n\n\(sourceLink)"
        }
    }
}

public enum ShareContentExtractor {
    /// Extracts shared content from extension items in priority order:
    /// Markdown → HTML → RTF/RTFD → Plain Text → URL alone.
    /// When both a selection and a URL arrive (e.g. from Safari), adds a source link under the converted text.
    public static func extract(from items: [NSExtensionItem]) async -> (text: String, title: String?) {
        let itemTitle = items.compactMap { $0.attributedTitle?.string }.first {
            !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }

        let providers = items.flatMap { $0.attachments ?? [] }
        guard !providers.isEmpty else {
            return ("", itemTitle)
        }

        // 1. Discover any web URL (http or https)
        var webURL: URL?
        for provider in providers where provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
            if let url = await loadURL(from: provider), !url.isFileURL {
                webURL = url
                break
            }
        }

        // 2. Discover plain text (for comparison or fallback)
        var plainText: String?
        for provider in providers where provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) {
            if let text = await loadString(from: provider, type: UTType.plainText.identifier),
               !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                plainText = text
                break
            }
        }

        // Priority 1: Markdown (as-is)
        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier("net.daringfireball.markdown") {
                if let md = await loadString(from: provider, type: "net.daringfireball.markdown"),
                   !md.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    let text = appendSourceLinkIfNeeded(markdown: md, url: webURL, title: itemTitle)
                    return (text, itemTitle)
                }
            }
            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                if let url = await loadURL(from: provider), url.isFileURL,
                   ["md", "markdown"].contains(url.pathExtension.lowercased()),
                   let md = try? String(contentsOf: url, encoding: .utf8),
                   !md.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    let text = appendSourceLinkIfNeeded(markdown: md, url: webURL, title: itemTitle)
                    let fileTitle = url.deletingPathExtension().lastPathComponent
                    return (text, itemTitle ?? (fileTitle.isEmpty ? nil : fileTitle))
                }
            }
        }

        // Priority 2: HTML
        for provider in providers where provider.hasItemConformingToTypeIdentifier(UTType.html.identifier) {
            if let html = await loadString(from: provider, type: UTType.html.identifier),
               !html.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                let md = ShareContentConverter.markdownFromHTML(html, plainText: plainText, sourceURL: webURL)
                let text = appendSourceLinkIfNeeded(markdown: md, url: webURL, title: itemTitle)
                return (text, itemTitle)
            }
        }

        // Priority 3: RTF / RTFD / NSAttributedString
        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier("com.apple.flat-rtfd") || provider.hasItemConformingToTypeIdentifier(UTType.rtfd.identifier) {
                let type = provider.hasItemConformingToTypeIdentifier("com.apple.flat-rtfd") ? "com.apple.flat-rtfd" : UTType.rtfd.identifier
                if let data = await loadData(from: provider, type: type) {
                    if let md = ShareContentConverter.markdownFromRTF(data, isRTFD: true, plainText: plainText, sourceURL: webURL) {
                        let text = appendSourceLinkIfNeeded(markdown: md, url: webURL, title: itemTitle)
                        return (text, itemTitle)
                    }
                }
            }
            if provider.hasItemConformingToTypeIdentifier(UTType.rtf.identifier) {
                if let data = await loadData(from: provider, type: UTType.rtf.identifier) {
                    if let md = ShareContentConverter.markdownFromRTF(data, isRTFD: false, plainText: plainText, sourceURL: webURL) {
                        let text = appendSourceLinkIfNeeded(markdown: md, url: webURL, title: itemTitle)
                        return (text, itemTitle)
                    }
                }
            }
        }

        // Priority 4: Plain text
        if let plain = plainText {
            // If plain text is merely the URL string itself, treat as URL alone
            if let webURL = webURL, plain.trimmingCharacters(in: .whitespacesAndNewlines) == webURL.absoluteString {
                let linkTitle = (itemTitle?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false) ? itemTitle! : (webURL.host() ?? webURL.lastPathComponent)
                return ("[\(linkTitle)](\(webURL.absoluteString))", itemTitle)
            }
            let text = appendSourceLinkIfNeeded(markdown: plain, url: webURL, title: itemTitle)
            return (text, itemTitle)
        }

        // Priority 5: URL alone
        if let webURL = webURL {
            let linkText = (itemTitle?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false) ? itemTitle! : (webURL.host() ?? webURL.lastPathComponent)
            return ("[\(linkText)](\(webURL.absoluteString))", itemTitle)
        }

        return ("", itemTitle)
    }

    private static func appendSourceLinkIfNeeded(markdown: String, url: URL?, title: String?) -> String {
        guard let url = url else { return markdown }
        return ShareContentConverter.appendingSourceLink(to: markdown, url: url, title: title)
    }

    private static func loadString(from provider: NSItemProvider, type: String) async -> String? {
        guard let item = try? await provider.loadItem(forTypeIdentifier: type, options: nil) else { return nil }
        if let str = item as? String {
            return str
        } else if let data = item as? Data {
            return String(data: data, encoding: .utf8) ?? String(data: data, encoding: .utf16)
        } else if let url = item as? URL, url.isFileURL {
            return (try? String(contentsOf: url, encoding: .utf8)) ?? (try? String(contentsOf: url, encoding: .utf16))
        } else if let attr = item as? NSAttributedString {
            return attr.string
        }
        return nil
    }

    private static func loadData(from provider: NSItemProvider, type: String) async -> Data? {
        guard let item = try? await provider.loadItem(forTypeIdentifier: type, options: nil) else { return nil }
        if let data = item as? Data {
            return data
        } else if let str = item as? String {
            return str.data(using: .utf8)
        } else if let url = item as? URL, url.isFileURL {
            return try? Data(contentsOf: url)
        } else if let attr = item as? NSAttributedString {
            let docType: NSAttributedString.DocumentType = type.contains("rtfd") ? .rtfd : .rtf
            return try? attr.data(from: NSRange(location: 0, length: attr.length), documentAttributes: [.documentType: docType])
        }
        return nil
    }

    private static func loadURL(from provider: NSItemProvider) async -> URL? {
        guard let item = try? await provider.loadItem(forTypeIdentifier: UTType.url.identifier, options: nil) else { return nil }
        if let url = item as? URL {
            return url
        } else if let nsURL = item as? NSURL {
            return nsURL as URL
        } else if let str = item as? String, let url = URL(string: str) {
            return url
        }
        return nil
    }
}

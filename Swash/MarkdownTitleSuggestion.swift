//
//  MarkdownTitleSuggestion.swift
//  Swash
//

import Foundation
#if os(macOS)
import AppKit
import ObjectiveC
#endif

/// Derives a clean document title suggestion from Markdown text.
///
/// Priority:
/// 1. YAML front matter `title:` field, if present.
/// 2. First-line ATX `# Heading` or setext heading.
/// 3. First H1 heading anywhere in the first ~20 lines.
/// 4. First non-empty line with Markdown stripped (emphasis, links, lists, blockquotes), skipping front matter.
///
/// Cleaned up:
/// - Strips Markdown syntax (emphasis, links, code, HTML).
/// - Strips characters `/ : \`.
/// - Collapses whitespace.
/// - Trimmed to about 60 characters on a word boundary.
public enum MarkdownTitleSuggestion {
    /// How much of the document `suggest(from:)` reads.
    static let maxScannedCharacters = 4000

    /// Suggests a document title from the given Markdown text. Returns nil if empty.
    public static func suggest(from text: String) -> String? {
        // Only the start matters (front matter, then the first ~20 lines), and this runs as the
        // person types: split just the first few thousand characters, not the whole document
        // (`prefix` stops after that many characters; `count` would walk the whole document)
        let head = String(text.prefix(maxScannedCharacters))
        let rawLines = head.components(separatedBy: .newlines)

        // 1. Check YAML front matter at the start of the document
        var startIndex = 0
        if let firstLine = rawLines.first?.trimmingCharacters(in: .whitespaces), firstLine == "---" {
            if let closingOffset = rawLines.dropFirst().firstIndex(where: { line in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                return trimmed == "---" || trimmed == "..."
            }) {
                // Front matter lines: 1..<closingOffset
                for idx in 1..<closingOffset {
                    let line = rawLines[idx].trimmingCharacters(in: .whitespaces)
                    if line.lowercased().hasPrefix("title:") {
                        var val = line.dropFirst(6).trimmingCharacters(in: .whitespaces)
                        if (val.hasPrefix("\"") && val.hasSuffix("\"")) || (val.hasPrefix("'") && val.hasSuffix("'")), val.count >= 2 {
                            val = String(val.dropFirst().dropLast())
                        }
                        if let cleaned = cleanTitle(val) {
                            return cleaned
                        }
                    }
                }
                startIndex = closingOffset + 1
            }
        }

        let lines = Array(rawLines[startIndex...])
        guard !lines.isEmpty else { return nil }

        // Find the index of the first non-empty line
        guard let firstNonEmptyIndex = lines.firstIndex(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) else {
            return nil
        }

        // 2. Check if the first line is an ATX `# Heading` or a setext heading
        if let firstHeading = headingTextIfH1(at: firstNonEmptyIndex, in: lines) {
            if let cleaned = cleanTitle(firstHeading) {
                return cleaned
            }
        }

        // 3. Otherwise, search for the first H1 anywhere in the first ~20 lines
        let limit = min(lines.count, 20)
        for idx in 0..<limit {
            if let h1Text = headingTextIfH1(at: idx, in: lines) {
                if let cleaned = cleanTitle(h1Text) {
                    return cleaned
                }
            }
        }

        // 4. Otherwise, the first non-empty line with Markdown stripped
        let firstLine = lines[firstNonEmptyIndex]
        let stripped = stripBlockMarkers(from: firstLine)
        return cleanTitle(stripped)
    }

    /// Checks if line at `index` is an H1 heading (ATX `# ...` or setext with `===`).
    private static func headingTextIfH1(at index: Int, in lines: [String]) -> String? {
        let line = lines[index]
        let trimmed = line.trimmingCharacters(in: .whitespaces)

        // ATX H1: starts with `#` followed by a space or tab, or is just `#`
        if trimmed == "#" {
            return ""
        }
        if trimmed.hasPrefix("#") && !trimmed.hasPrefix("##") {
            let afterHash = trimmed.dropFirst()
            if afterHash.first?.isWhitespace == true {
                var content = afterHash.trimmingCharacters(in: .whitespaces)
                // Remove optional closing `#` sequence
                while content.hasSuffix("#") {
                    content.removeLast()
                }
                return content.trimmingCharacters(in: .whitespaces)
            }
        }

        // Setext H1: current line followed by a line of `===...`
        if index + 1 < lines.count && !trimmed.isEmpty {
            let nextTrimmed = lines[index + 1].trimmingCharacters(in: .whitespaces)
            if !nextTrimmed.isEmpty && nextTrimmed.allSatisfy({ $0 == "=" }) {
                // Ensure the current line is not an ATX heading or code fence
                if !trimmed.hasPrefix("#") && !trimmed.hasPrefix("```") && !trimmed.hasPrefix("~~~") {
                    return trimmed
                }
            }
        }

        return nil
    }

    /// Strips leading blockquote, list, task, and heading markers from a line.
    private static func stripBlockMarkers(from line: String) -> String {
        var text = line.trimmingCharacters(in: .whitespaces)

        // Strip leading blockquotes `> ` or `>> `
        while text.hasPrefix(">") {
            text.removeFirst()
            text = text.trimmingCharacters(in: .whitespaces)
        }

        // Strip task list marker `[ ] ` or `[x] `
        if text.hasPrefix("[ ] ") || text.hasPrefix("[x] ") || text.hasPrefix("[X] ") {
            text = String(text.dropFirst(4)).trimmingCharacters(in: .whitespaces)
        }

        // Strip list marker `- `, `* `, `+ `
        if (text.hasPrefix("- ") || text.hasPrefix("* ") || text.hasPrefix("+ ")) {
            text = String(text.dropFirst(2)).trimmingCharacters(in: .whitespaces)
        } else if let match = text.range(of: #"^\d+[\.\)]\s+"#, options: .regularExpression) {
            text = String(text[match.upperBound...]).trimmingCharacters(in: .whitespaces)
        }

        // Strip task list marker again if it followed a bullet e.g. `- [ ] `
        if text.hasPrefix("[ ] ") || text.hasPrefix("[x] ") || text.hasPrefix("[X] ") {
            text = String(text.dropFirst(4)).trimmingCharacters(in: .whitespaces)
        }

        // Strip leading heading hashes `## ` or `### `
        while text.hasPrefix("#") {
            text.removeFirst()
        }
        text = text.trimmingCharacters(in: .whitespaces)

        // Strip trailing hashes
        while text.hasSuffix("#") {
            text.removeLast()
        }
        return text.trimmingCharacters(in: .whitespaces)
    }

    /// Strips inline Markdown syntax (emphasis, links, code, HTML tags).
    public static func stripMarkdownInlines(_ text: String) -> String {
        var result = text

        // Images: ![alt](url) -> alt
        result = replacingRegex(result, pattern: #"!\[([^\]]*)\]\([^)]*\)"#, template: "$1")
        // Links: [text](url) -> text
        result = replacingRegex(result, pattern: #"\[([^\]]*)\]\([^)]*\)"#, template: "$1")
        // Reference links: [text][ref] -> text
        result = replacingRegex(result, pattern: #"\[([^\]]*)\]\[[^\]]*\]"#, template: "$1")
        // Shortcut reference links: [text] -> text
        result = replacingRegex(result, pattern: #"\[([^\]]*)\]"#, template: "$1")
        // Autolinks: <https://...> -> https://...
        result = replacingRegex(result, pattern: #"<([a-zA-Z][a-zA-Z0-9+.-]{1,31}:[^>]+)>"#, template: "$1")
        // HTML tags: <tag> -> ""
        result = replacingRegex(result, pattern: #"<[^>]+>"#, template: "")
        // Code spans: `code` -> code
        result = replacingRegex(result, pattern: #"`([^`]+)`"#, template: "$1")
        // Strikethrough: ~~text~~ -> text
        result = replacingRegex(result, pattern: #"~~([^~]+)~~"#, template: "$1")
        // Bold/Italic triple: ***text*** or ___text___ -> text
        result = replacingRegex(result, pattern: #"\*\*\*([^*]+)\*\*\*"#, template: "$1")
        result = replacingRegex(result, pattern: #"___([^_]+)___"#, template: "$1")
        // Bold double: **text** or __text__ -> text
        result = replacingRegex(result, pattern: #"\*\*([^*]+)\*\*"#, template: "$1")
        result = replacingRegex(result, pattern: #"__([^_]+)__"#, template: "$1")
        // Italic single: *text* or _text_ -> text
        result = replacingRegex(result, pattern: #"\*([^*]+)\*"#, template: "$1")
        result = replacingRegex(result, pattern: #"(?<!\w)_([^_]+)_(?!\w)"#, template: "$1")

        return result
    }

    /// Cleans up a title: strips inlines, removes `/ : \`, collapses spaces, and truncates to ~60 chars on word boundary.
    public static func cleanTitle(_ raw: String) -> String? {
        var text = stripMarkdownInlines(raw)

        // Remove / : \ characters
        let invalidChars = CharacterSet(charactersIn: "/:\\")
        text = text.components(separatedBy: invalidChars).joined(separator: "")

        // Collapse multiple whitespace/newlines into single spaces
        let words = text.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }
        text = words.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)

        guard !text.isEmpty else { return nil }
        text = truncate(text, limit: 60)
        return text.isEmpty ? nil : text
    }

    /// Truncates text to at most `limit` characters on a word boundary.
    public static func truncate(_ text: String, limit: Int = 60) -> String {
        guard text.count > limit else { return text }
        let prefix = String(text.prefix(limit))
        if let lastSpace = prefix.lastIndex(where: { $0.isWhitespace }) {
            let truncated = prefix[..<lastSpace].trimmingCharacters(in: .whitespacesAndNewlines)
            if !truncated.isEmpty {
                return String(truncated)
            }
        }
        return prefix.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// A file name without characters Files / Finder won't accept.
    public static func cleanFileName(_ title: String) -> String {
        let invalid = CharacterSet(charactersIn: "/:\\").union(.newlines).union(.controlCharacters)
        let cleaned = title.components(separatedBy: invalid).joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? "Untitled" : cleaned
    }

    /// Compiled once: suggestions are recomputed as the person types.
    private static let regexCache = NSCache<NSString, NSRegularExpression>()

    private static func replacingRegex(_ text: String, pattern: String, template: String) -> String {
        let regex: NSRegularExpression
        if let cached = regexCache.object(forKey: pattern as NSString) {
            regex = cached
        } else {
            guard let compiled = try? NSRegularExpression(pattern: pattern) else { return text }
            regexCache.setObject(compiled, forKey: pattern as NSString)
            regex = compiled
        }
        let range = NSRange(location: 0, length: (text as NSString).length)
        return regex.stringByReplacingMatches(in: text, options: [], range: range, withTemplate: template)
    }
}

// MARK: - macOS Draft Name Hook

#if os(macOS)
extension MarkdownTitleSuggestion {
    private static var swizzled = false
    fileprivate static var draftNameKey: UInt8 = 0

    /// Installs swizzling on `NSDocument.defaultDraftName` and `NSDocument.prepareSavePanel` so untitled
    /// documents prefill the suggested title in the Save panel.
    public static func installMacDraftNameHook() {
        guard !swizzled else { return }
        swizzled = true

        let docClass = NSDocument.self
        if let original = class_getInstanceMethod(docClass, #selector(NSDocument.defaultDraftName)),
           let replacement = class_getInstanceMethod(docClass, #selector(NSDocument.swash_defaultDraftName)) {
            method_exchangeImplementations(original, replacement)
        }
        if let original = class_getInstanceMethod(docClass, #selector(NSDocument.prepareSavePanel(_:))),
           let replacement = class_getInstanceMethod(docClass, #selector(NSDocument.swash_prepareSavePanel(_:))) {
            method_exchangeImplementations(original, replacement)
        }
    }
}

extension NSDocument {
    var swashSuggestedDraftName: String? {
        get { objc_getAssociatedObject(self, &MarkdownTitleSuggestion.draftNameKey) as? String }
        set { objc_setAssociatedObject(self, &MarkdownTitleSuggestion.draftNameKey, newValue, .OBJC_ASSOCIATION_RETAIN_NONATOMIC) }
    }

    @objc func swash_defaultDraftName() -> String {
        if self.fileURL == nil, let suggested = self.swashSuggestedDraftName, !suggested.isEmpty {
            return suggested
        }
        return self.swash_defaultDraftName()
    }

    @objc func swash_prepareSavePanel(_ savePanel: NSSavePanel) -> Bool {
        let result = self.swash_prepareSavePanel(savePanel)
        if self.fileURL == nil, let suggested = self.swashSuggestedDraftName, !suggested.isEmpty {
            savePanel.nameFieldStringValue = suggested
        }
        return result
    }
}
#endif

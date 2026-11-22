//
//  SwashAppIntents.swift
//  Swash
//
//  Shortcuts, Siri and Spotlight support across macOS, iOS and iPadOS (#196):
//  - `SwashDocumentEntity` (`AppEntity` + `IndexedEntity` + `EntityStringQuery`) for picking,
//    searching and indexing Markdown notes across the app's Documents folder, iCloud container
//    and user-granted folders.
//  - Background-capable intents (`openAppWhenRun = false`) for finding or creating notes,
//    expanding templates, reading contents as Markdown/Plain Text/HTML, appending or prepending
//    entries (at the end, beginning or under a specific heading; as plain text, bullet, to-do
//    or timestamped item), full-text search, HTML ↔ Markdown and Markdown flavor conversion,
//    PDF export, task roll-ups (`- [ ]` / `- [x]`), heading outlines, document statistics, and
//    writing mode / Focus Filter automation.
//

import Foundation
import UniformTypeIdentifiers
import PixerateMarkdown
import MacAppKitExtras
#if !SWASH_SHORTCUTS_TEST_RUNNER
import AppIntents
import CoreSpotlight
#endif
#if os(macOS)
import AppKit
#else
import UIKit
#endif

// MARK: - Shared Option Enums

nonisolated enum MarkdownWrapperStyle: String, CaseIterable, Sendable {
    case codeBlock = "Code Block"
    case quoteBlock = "Quote Block"
    case header = "Header"
}

nonisolated enum SwashContentFormat: String, CaseIterable, Sendable {
    case markdown = "Markdown"
    case plainText = "Plain Text"
    case html = "HTML"
    case standaloneHTML = "Standalone HTML"
}

nonisolated enum SwashInsertPosition: String, CaseIterable, Sendable {
    case end = "End of Document"
    case beginning = "Beginning of Document"
    case underHeading = "Under Heading"
}

nonisolated enum SwashAppendStyle: String, CaseIterable, Sendable {
    case plain = "Plain Text"
    case bullet = "Bullet"
    case todo = "To-Do"
    case timestampedBullet = "Timestamped Bullet"
    case timestampedTodo = "Timestamped To-Do"
}

nonisolated enum SwashSearchScope: String, CaseIterable, Sendable {
    case nameAndContent = "Name and Content"
    case nameOnly = "Name Only"
    case contentOnly = "Content Only"
}

nonisolated enum SwashTodoStatusFilter: String, CaseIterable, Sendable {
    case open = "Open"
    case completed = "Completed"
    case all = "All"
}

nonisolated enum SwashDocumentTemplate: String, CaseIterable, Sendable {
    case dailyJournal = "Daily Journal"
    case meetingNotes = "Meeting Notes"
    case inboxCapture = "Inbox"
    case projectPlan = "Project Plan"
    case custom = "Custom"
}

nonisolated enum SwashMarkdownFlavorOption: String, CaseIterable, Sendable {
    case github = "GitHub"
    case commonMark = "CommonMark"
    case original = "Original"
    case slack = "Slack"

    var markdownFlavor: MarkdownFlavor {
        switch self {
        case .github: return .github
        case .commonMark: return .commonMark
        case .original: return .original
        case .slack: return .slack
        }
    }

    init(_ flavor: MarkdownFlavor) {
        switch flavor {
        case .github: self = .github
        case .commonMark: self = .commonMark
        case .original: self = .original
        case .slack: self = .slack
        }
    }
}

nonisolated enum SwashFocusUnitOption: String, CaseIterable, Sendable {
    case paragraph = "Paragraph"
    case sentence = "Sentence"
}

// MARK: - Pure Data Models & Engine

nonisolated struct SwashDocumentSummary: Identifiable, Equatable, Sendable {
    let id: String
    let url: URL
    let title: String
    let folder: String
    let modified: Date?
    let wordCount: Int
}

nonisolated struct SwashTodoItem: Equatable, Sendable {
    let text: String
    let isCompleted: Bool
    let line: Int
    let file: URL?

    var markdownLine: String {
        "- [\(isCompleted ? "x" : " ")] \(text)"
    }
}

nonisolated struct SwashStatisticsSummary: Equatable, Sendable {
    let words: Int
    let characters: Int
    let charactersExcludingSpaces: Int
    let lines: Int
    let paragraphs: Int
    let readingMinutes: Int
    let headings: Int
    let openTodos: Int
    let completedTodos: Int

    var summaryString: String {
        "\(words) words, \(characters) characters, \(lines) lines"
    }

    var detailedSummaryString: String {
        "\(words) words, \(characters) characters (\(charactersExcludingSpaces) without spaces), \(paragraphs) paragraphs, \(headings) headings, \(openTodos) open to-dos"
    }
}

nonisolated enum SwashShortcutsError: LocalizedError {
    case documentNotFound(String)
    case invalidPath(String)
    case unreadableDocument(String)

    var errorDescription: String? {
        switch self {
        case .documentNotFound(let name):
            return "Could not find a Markdown document matching “\(name)”."
        case .invalidPath(let path):
            return "“\(path)” is not a valid Markdown document name or path."
        case .unreadableDocument(let name):
            return "Could not read “\(name)”."
        }
    }
}

/// Pure, cross-platform engine backing Swash's Shortcuts App Intents and AppleScript commands.
nonisolated enum SwashShortcutsEngine {

    // MARK: Document Discovery & Resolution

    /// Returns the candidate root directories where Swash looks for Markdown documents:
    /// any caller-supplied roots, the app's Documents directory, the iCloud ubiquity container's
    /// Documents directory, and any security-scoped folders granted in `FolderAccessManager`.
    static func defaultRootFolders(extraRoots: [URL] = [], defaults: UserDefaults = .standard) -> [URL] {
        var roots: [URL] = []
        var seen: Set<String> = []

        func add(_ url: URL?) {
            guard let url = url?.standardizedFileURL else { return }
            let path = url.path
            guard !path.isEmpty, !seen.contains(path) else { return }
            seen.insert(path)
            roots.append(url)
        }

        for extra in extraRoots { add(extra) }

        if let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first {
            add(docs)
        }
        if let ubiquity = FileManager.default.url(forUbiquityContainerIdentifier: nil)?
            .appendingPathComponent("Documents", isDirectory: true) {
            add(ubiquity)
        }
        if let bookmarked = defaults.dictionary(forKey: "swash_security_scoped_folder_bookmarks") as? [String: Data] {
            for path in bookmarked.keys.sorted() {
                let folderURL = URL(fileURLWithPath: path)
                _ = FolderAccessManager.shared.ensureAccess(for: folderURL)
                add(folderURL)
            }
        }
        return roots
    }

    /// Primary writable folder for new notes when no folder is explicitly provided.
    static func defaultWritableRoot(from roots: [URL]? = nil) throws -> URL {
        if let first = roots?.first {
            let std = first.standardizedFileURL
            _ = FolderAccessManager.shared.ensureAccess(for: std)
            try FileManager.default.createDirectory(at: std, withIntermediateDirectories: true)
            return std
        }
        let docs = try FileManager.default.url(for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        return docs.standardizedFileURL
    }

    /// Discovers all Markdown files in `roots` (or `defaultRootFolders()` when nil).
    static func discoverFiles(in roots: [URL]? = nil, extraFiles: [URL] = []) -> [URL] {
        let effectiveRoots = roots ?? defaultRootFolders()
        var urls: [URL] = []
        var seen: Set<String> = []

        func addFile(_ url: URL) {
            let std = url.standardizedFileURL
            guard FolderScanner.isMarkdown(std), !seen.contains(std.path) else { return }
            guard FileManager.default.fileExists(atPath: std.path) else { return }
            seen.insert(std.path)
            urls.append(std)
        }

        for file in extraFiles { addFile(file) }

        for root in effectiveRoots {
            let std = root.standardizedFileURL
            _ = FolderAccessManager.shared.ensureAccess(for: std)
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: std.path, isDirectory: &isDir) else { continue }
            if isDir.boolValue {
                for file in FolderScanner.scan(std).files {
                    addFile(file)
                }
            } else {
                addFile(std)
            }
        }
        return urls
    }

    /// Builds a `SwashDocumentSummary` for `url`, computing its relative folder and word count.
    static func documentSummary(for url: URL, text: String? = nil, roots: [URL] = []) -> SwashDocumentSummary {
        let std = url.standardizedFileURL
        let parent = std.deletingLastPathComponent()
        _ = FolderAccessManager.shared.ensureAccess(for: parent)
        let content = text ?? (try? readText(at: std)) ?? ""
        let values = try? std.resourceValues(forKeys: [.contentModificationDateKey])
        let modified = values?.contentModificationDate
        let title = std.deletingPathExtension().lastPathComponent
        let folder: String = {
            for root in roots {
                let stdRoot = root.standardizedFileURL
                if FolderScanner.contains(stdRoot, std) {
                    let rel = FolderScanner.relativePath(of: parent, in: stdRoot)
                    if parent.path == stdRoot.path {
                        return stdRoot.lastPathComponent
                    }
                    return "\(stdRoot.lastPathComponent)/\(rel)"
                }
            }
            return parent.lastPathComponent
        }()
        let stats = MarkdownStatistics(text: content)
        return SwashDocumentSummary(
            id: std.path,
            url: std,
            title: title.isEmpty ? std.lastPathComponent : title,
            folder: folder,
            modified: modified,
            wordCount: stats.words
        )
    }

    /// Finds documents matching `query` by filename, full-text content, or both.
    static func findDocuments(
        query: String,
        scope: SwashSearchScope = .nameAndContent,
        in roots: [URL]? = nil,
        extraFiles: [URL] = [],
        texts: [URL: String] = [:],
        limit: Int = 50
    ) -> [SwashDocumentSummary] {
        guard limit > 0 else { return [] }
        let effectiveRoots = roots ?? defaultRootFolders()
        let files = discoverFiles(in: effectiveRoots, extraFiles: extraFiles)
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)

        if trimmed.isEmpty {
            let summaries = files.map { documentSummary(for: $0, text: texts[$0], roots: effectiveRoots) }
            let sorted = summaries.sorted { lhs, rhs in
                let lDate = lhs.modified ?? .distantPast
                let rDate = rhs.modified ?? .distantPast
                if lDate != rDate { return lDate > rDate }
                return lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
            }
            return Array(sorted.prefix(limit))
        }

        var matchedURLs: [URL] = []
        var seen: Set<String> = []

        func appendMatch(_ url: URL) {
            let std = url.standardizedFileURL
            guard !seen.contains(std.path), matchedURLs.count < limit else { return }
            seen.insert(std.path)
            matchedURLs.append(std)
        }

        if scope == .nameOnly || scope == .nameAndContent {
            for file in files {
                let title = file.deletingPathExtension().lastPathComponent
                let matchesTitle = title.localizedStandardContains(trimmed)
                let matchesPath = effectiveRoots.contains { root in
                    FolderScanner.contains(root, file)
                        && FolderScanner.relativePath(of: file, in: root).localizedStandardContains(trimmed)
                }
                if matchesTitle || matchesPath {
                    appendMatch(file)
                }
            }
        }

        if (scope == .contentOnly || scope == .nameAndContent) && matchedURLs.count < limit {
            let contentMatches = FolderSearch.search(trimmed, in: files, texts: texts, limit: max(limit * 4, 100))
            for match in contentMatches {
                appendMatch(match.file)
                if matchedURLs.count >= limit { break }
            }
        }

        return matchedURLs.map { documentSummary(for: $0, text: texts[$0], roots: effectiveRoots) }
    }

    /// Normalizes a relative path or note title into safe path components with a `.md` extension.
    static func normalizedRelativePath(_ raw: String) -> String? {
        let cleaned = raw
            .replacingOccurrences(of: "\\", with: "/")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return nil }

        let rawSegments = cleaned.split(separator: "/", omittingEmptySubsequences: true).map { segment -> String in
            segment
                .replacingOccurrences(of: ":", with: "-")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }.filter { !$0.isEmpty && $0 != "." && $0 != ".." && !$0.hasPrefix(".") }

        guard !rawSegments.isEmpty else { return nil }
        var segments = rawSegments
        let last = segments[segments.count - 1]
        if !FolderScanner.isMarkdown(URL(fileURLWithPath: last)) {
            segments[segments.count - 1] = last + ".md"
        }
        return segments.joined(separator: "/")
    }

    /// Resolves an existing document from an absolute path, relative path (`Journal/2026-11-21.md`)
    /// or note title (`Inbox`).
    static func resolveExistingDocument(pathOrTitle: String, in roots: [URL]? = nil, extraFiles: [URL] = []) -> URL? {
        let trimmed = pathOrTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        // 1. Absolute or tilde path
        if trimmed.hasPrefix("/") || trimmed.hasPrefix("~") {
            let expanded = (trimmed as NSString).expandingTildeInPath
            let direct = URL(fileURLWithPath: expanded).standardizedFileURL
            _ = FolderAccessManager.shared.ensureAccess(for: direct.deletingLastPathComponent())
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: direct.path, isDirectory: &isDir), !isDir.boolValue {
                return direct
            }
            if direct.pathExtension.isEmpty {
                let withMD = direct.appendingPathExtension("md")
                if FileManager.default.fileExists(atPath: withMD.path, isDirectory: &isDir), !isDir.boolValue {
                    return withMD
                }
            }
        }

        let effectiveRoots = roots ?? defaultRootFolders()
        guard let relative = normalizedRelativePath(trimmed) else { return nil }

        // 2. Direct relative path under any root
        for root in effectiveRoots {
            let candidate = root.standardizedFileURL.appendingPathComponent(relative).standardizedFileURL
            _ = FolderAccessManager.shared.ensureAccess(for: candidate.deletingLastPathComponent())
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: candidate.path, isDirectory: &isDir), !isDir.boolValue {
                return candidate
            }
        }

        // 3. Case-insensitive relative path or title match across discovered files
        let files = discoverFiles(in: effectiveRoots, extraFiles: extraFiles)
        let wantedPath = (relative as NSString).deletingPathExtension.lowercased()
        let wantedName = URL(fileURLWithPath: relative).deletingPathExtension().lastPathComponent.lowercased()

        if wantedPath.contains("/") {
            if let match = files.first(where: { file in
                effectiveRoots.contains { root in
                    let rel = (FolderScanner.relativePath(of: file, in: root) as NSString).deletingPathExtension.lowercased()
                    return rel == wantedPath || rel.hasSuffix("/" + wantedPath)
                }
            }) {
                return match
            }
        }

        return files.first { $0.deletingPathExtension().lastPathComponent.lowercased() == wantedName }
    }

    /// Finds an existing document matching `pathOrTitle`, or creates it (including intermediate
    /// folders such as `Journal/`) with `initialContent`.
    static func findOrCreateDocument(
        pathOrTitle: String,
        initialContent: String = "",
        in root: URL? = nil,
        roots: [URL]? = nil
    ) throws -> (url: URL, created: Bool) {
        let searchRoots = root.map { [$0] } ?? roots
        if let existing = resolveExistingDocument(pathOrTitle: pathOrTitle, in: searchRoots) {
            return (existing, false)
        }
        guard let relative = normalizedRelativePath(pathOrTitle) else {
            throw SwashShortcutsError.invalidPath(pathOrTitle)
        }
        let targetRoot = try defaultWritableRoot(from: searchRoots)
        let targetURL = targetRoot.appendingPathComponent(relative).standardizedFileURL
        try FileManager.default.createDirectory(at: targetURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let contentToWrite: String
        if initialContent.isEmpty {
            contentToWrite = ""
        } else {
            contentToWrite = initialContent.hasSuffix("\n") ? initialContent : initialContent + "\n"
        }
        try writeText(contentToWrite, to: targetURL)
        return (targetURL, true)
    }

    // MARK: Coordinated File I/O

    /// Reads a Markdown document from disk using `NSFileCoordinator` and `SwashDocument.decode`.
    static func readText(at url: URL) throws -> String {
        let std = url.standardizedFileURL
        _ = FolderAccessManager.shared.ensureAccess(for: std.deletingLastPathComponent())
        var coordinatorError: NSError?
        var readResult: Result<String, Error> = .failure(SwashShortcutsError.unreadableDocument(std.lastPathComponent))
        let coordinator = NSFileCoordinator(filePresenter: nil)
        coordinator.coordinate(readingItemAt: std, options: .withoutChanges, error: &coordinatorError) { coordinatedURL in
            do {
                let data = try Data(contentsOf: coordinatedURL)
                if let decoded = SwashDocument.decode(data) {
                    readResult = .success(decoded)
                } else {
                    readResult = .failure(CocoaError(.fileReadUnknownStringEncoding))
                }
            } catch {
                readResult = .failure(error)
            }
        }
        if let coordinatorError { throw coordinatorError }
        return try readResult.get()
    }

    /// Writes `text` as UTF-8 to `url` using `NSFileCoordinator` so any open document window or
    /// folder workspace reloads automatically.
    static func writeText(_ text: String, to url: URL) throws {
        let std = url.standardizedFileURL
        let folder = std.deletingLastPathComponent()
        _ = FolderAccessManager.shared.ensureAccess(for: folder)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var coordinatorError: NSError?
        var writeError: Error?
        let coordinator = NSFileCoordinator(filePresenter: nil)
        coordinator.coordinate(writingItemAt: std, options: .forReplacing, error: &coordinatorError) { coordinatedURL in
            do {
                try Data(text.utf8).write(to: coordinatedURL, options: .atomic)
            } catch {
                writeError = error
            }
        }
        if let coordinatorError { throw coordinatorError }
        if let writeError { throw writeError }
    }

    /// Reads, changes and writes `url` in one coordinated write, so an edit another app or an
    /// open window makes between the read and the write can't be lost. A read that fails is an
    /// error, never an empty document: writing the change over it would wipe the file.
    @discardableResult
    static func modifyText(at url: URL, _ change: (String) -> String) throws -> String {
        let std = url.standardizedFileURL
        _ = FolderAccessManager.shared.ensureAccess(for: std.deletingLastPathComponent())
        var coordinatorError: NSError?
        var result: Result<String, Error> = .failure(SwashShortcutsError.unreadableDocument(std.lastPathComponent))
        let coordinator = NSFileCoordinator(filePresenter: nil)
        coordinator.coordinate(writingItemAt: std, options: .forMerging, error: &coordinatorError) { coordinatedURL in
            do {
                let data = try Data(contentsOf: coordinatedURL)
                guard let existing = SwashDocument.decode(data) else { throw CocoaError(.fileReadUnknownStringEncoding) }
                let updated = change(existing)
                try Data(updated.utf8).write(to: coordinatedURL, options: .atomic)
                result = .success(updated)
            } catch {
                result = .failure(error)
            }
        }
        if let coordinatorError { throw coordinatorError }
        return try result.get()
    }

    // MARK: Appending & Prepending

    private static let bulletPrefixRegex = try! NSRegularExpression(pattern: #"^\s*(?:[-*+]|\d+[.)])\s+"#)
    private static let todoPrefixRegex = try! NSRegularExpression(pattern: #"^\s*[-*+]\s+\[[ xX]\]\s+"#)

    static func timestampString(for date: Date, timeZone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: date)
    }

    static func dateString(for date: Date, timeZone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    /// Formats `text` according to `style` (plain text, bullet, to-do, or timestamped item).
    static func formatEntry(
        _ text: String,
        style: SwashAppendStyle,
        date: Date = Date(),
        timeZone: TimeZone = .current
    ) -> String {
        let normalized = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return "" }
        let lines = normalized.components(separatedBy: "\n")
        let time = timestampString(for: date, timeZone: timeZone)

        switch style {
        case .plain:
            return normalized
        case .bullet:
            return lines.map { line in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.isEmpty { return "" }
                if isListLine(trimmed) { return line }
                return "- \(trimmed)"
            }.joined(separator: "\n")
        case .todo:
            return lines.map { line in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.isEmpty { return "" }
                if isTodoLine(trimmed) { return line }
                if let stripped = stripBulletMarker(trimmed) {
                    return "- [ ] \(stripped)"
                }
                return "- [ ] \(trimmed)"
            }.joined(separator: "\n")
        case .timestampedBullet:
            let first = stripBulletMarker(lines[0].trimmingCharacters(in: .whitespaces)) ?? lines[0].trimmingCharacters(in: .whitespaces)
            let head = "- **\(time)** \(first)"
            if lines.count == 1 { return head }
            let rest = lines.dropFirst().map { $0.isEmpty ? "" : "  \($0)" }
            return ([head] + rest).joined(separator: "\n")
        case .timestampedTodo:
            let rawFirst = lines[0].trimmingCharacters(in: .whitespaces)
            let first = stripTodoMarker(rawFirst) ?? stripBulletMarker(rawFirst) ?? rawFirst
            let head = "- [ ] **\(time)** \(first)"
            if lines.count == 1 { return head }
            let rest = lines.dropFirst().map { $0.isEmpty ? "" : "  \($0)" }
            return ([head] + rest).joined(separator: "\n")
        }
    }

    private static func isListLine(_ line: String) -> Bool {
        let ns = line as NSString
        return bulletPrefixRegex.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)) != nil
    }

    private static func isTodoLine(_ line: String) -> Bool {
        let ns = line as NSString
        return todoPrefixRegex.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)) != nil
    }

    private static func stripBulletMarker(_ line: String) -> String? {
        let ns = line as NSString
        guard let match = bulletPrefixRegex.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)) else {
            return nil
        }
        return ns.substring(from: NSMaxRange(match.range))
    }

    private static func stripTodoMarker(_ line: String) -> String? {
        let ns = line as NSString
        guard let match = todoPrefixRegex.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)) else {
            return nil
        }
        return ns.substring(from: NSMaxRange(match.range))
    }

    /// Inserts `entry` into `existing` at the requested `position` (`end`, `beginning`, or
    /// `underHeading`), formatted with `style`.
    static func insert(
        _ entry: String,
        into existing: String,
        position: SwashInsertPosition = .end,
        heading: String = "",
        style: SwashAppendStyle = .plain,
        date: Date = Date(),
        timeZone: TimeZone = .current
    ) -> String {
        let formatted = formatEntry(entry, style: style, date: date, timeZone: timeZone)
        guard !formatted.isEmpty else { return existing }
        let normalizedExisting = existing
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")

        switch position {
        case .end:
            return appendBlock(formatted, to: normalizedExisting)

        case .beginning:
            if normalizedExisting.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return formatted + "\n"
            }
            if let fmEnd = frontMatterEndOffset(in: normalizedExisting) {
                let ns = normalizedExisting as NSString
                let frontMatter = ns.substring(to: fmEnd).replacingOccurrences(of: #"\n+$"#, with: "", options: .regularExpression)
                let remainder = ns.substring(from: fmEnd).drop(while: { $0 == "\n" })
                if remainder.isEmpty {
                    return frontMatter + "\n\n" + formatted + "\n"
                }
                return frontMatter + "\n\n" + formatted + "\n\n" + String(remainder)
            }
            let strippedLeading = String(normalizedExisting.drop(while: { $0 == "\n" }))
            let result = formatted + "\n\n" + strippedLeading
            return result.hasSuffix("\n") ? result : result + "\n"

        case .underHeading:
            let targetHeading = heading.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !targetHeading.isEmpty else {
                return appendBlock(formatted, to: normalizedExisting)
            }
            return insertUnderHeading(formatted, headingQuery: targetHeading, in: normalizedExisting)
        }
    }

    private static func appendBlock(_ block: String, to existing: String) -> String {
        let trimmedExisting = existing.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedExisting.isEmpty {
            return block + "\n"
        }
        let withoutTrailingNewlines = existing.replacingOccurrences(of: #"\n+$"#, with: "", options: .regularExpression)
        let lastLine = withoutTrailingNewlines.components(separatedBy: "\n").last ?? ""
        let firstNewLine = block.components(separatedBy: "\n").first ?? ""
        // Keep adjacent list items tight when appending a bullet or to-do to an existing list
        let separator = (isListLine(lastLine) && isListLine(firstNewLine)) ? "\n" : "\n\n"
        return withoutTrailingNewlines + separator + block + "\n"
    }

    private static func frontMatterEndOffset(in text: String) -> Int? {
        let document = MarkdownDocument.parse(text)
        guard let first = document.root.children.first, case .frontMatter = first.kind else { return nil }
        return NSMaxRange(first.range)
    }

    private static func insertUnderHeading(_ formatted: String, headingQuery: String, in existing: String) -> String {
        let wantedTitle = headingQuery
            .replacingOccurrences(of: #"^#{1,6}\s*"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let outline = MarkdownOutline(text: existing)
        let ns = existing as NSString

        if let index = outline.headings.firstIndex(where: {
            $0.title.trimmingCharacters(in: .whitespacesAndNewlines).localizedCaseInsensitiveCompare(wantedTitle) == .orderedSame
        }) {
            let matched = outline.headings[index]
            let nextIndex = outline.headings[(index + 1)...].firstIndex(where: { $0.level <= matched.level })
            let sectionEnd = nextIndex.map { outline.headings[$0].range.location } ?? ns.length
            let beforeSectionEnd = ns.substring(to: sectionEnd)
            let afterSectionEnd = ns.substring(from: sectionEnd)

            // If the heading line is immediately followed by an empty task placeholder `- [ ] `, replace it
            let headingEnd = NSMaxRange(matched.range)
            if sectionEnd >= headingEnd {
                let bodyRange = NSRange(location: headingEnd, length: sectionEnd - headingEnd)
                let bodyText = ns.substring(with: bodyRange)
                if let emptyTodoRange = bodyText.range(of: #"^\n*[-*+]\s+\[ \]\s*\n*$"#, options: .regularExpression),
                   isTodoLine(formatted) {
                    let prefix = ns.substring(to: headingEnd)
                    let suffix = afterSectionEnd.isEmpty ? "\n" : "\n\n" + afterSectionEnd
                    let _ = emptyTodoRange
                    return prefix + "\n\n" + formatted + suffix
                }
            }

            let updatedBefore = appendBlock(formatted, to: beforeSectionEnd)
            if afterSectionEnd.isEmpty {
                return updatedBefore
            }
            let strippedAfter = String(afterSectionEnd.drop(while: { $0 == "\n" }))
            return updatedBefore + "\n" + strippedAfter
        }

        // Heading not found: append the heading and the entry at the end of the document
        let headingLine = headingQuery.hasPrefix("#") ? headingQuery : "## \(wantedTitle)"
        return appendBlock("\(headingLine)\n\n\(formatted)", to: existing)
    }

    // MARK: Templates

    /// Parses `key=value` or `key: value` lines into a lowercase-keyed dictionary.
    static func parseVariables(_ raw: String) -> [String: String] {
        var result: [String: String] = [:]
        for line in raw.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            if let eq = trimmed.firstIndex(of: "=") {
                let key = trimmed[..<eq].trimmingCharacters(in: .whitespaces).lowercased()
                let value = trimmed[trimmed.index(after: eq)...].trimmingCharacters(in: .whitespaces)
                if !key.isEmpty { result[key] = value }
            } else if let colon = trimmed.firstIndex(of: ":") {
                let key = trimmed[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
                let value = trimmed[trimmed.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                if !key.isEmpty { result[key] = value }
            }
        }
        return result
    }

    /// Default title / relative path pattern for a built-in template.
    static func defaultTitlePattern(for template: SwashDocumentTemplate) -> String {
        switch template {
        case .dailyJournal: return "Journal/{{date}}"
        case .meetingNotes: return "Meetings/{{date}} - {{title}}"
        case .inboxCapture: return "Inbox"
        case .projectPlan: return "{{title}}"
        case .custom: return "{{title}}"
        }
    }

    /// Built-in Markdown body for `template`.
    static func templateBody(for template: SwashDocumentTemplate, customBody: String = "") -> String {
        switch template {
        case .dailyJournal:
            return """
            # {{date}}

            ## Notes

            ## Tasks
            - [ ] 
            """
        case .meetingNotes:
            return """
            # {{title}}

            - **Date:** {{date}} {{time}}
            - **Attendees:** {{attendees}}

            ## Agenda
            - {{agenda}}

            ## Notes

            ## Action Items
            - [ ] 
            """
        case .inboxCapture:
            return """
            # Inbox

            - [ ] {{clipboard}}
            """
        case .projectPlan:
            return """
            # {{title}}

            ## Overview

            ## Tasks
            - [ ] 

            ## Notes
            """
        case .custom:
            return customBody
        }
    }

    private static let placeholderRegex = try! NSRegularExpression(pattern: #"\{\{\s*([a-zA-Z0-9_-]+)\s*\}\}"#)

    /// Expands `{{date}}`, `{{time}}`, `{{datetime}}`, `{{title}}`, `{{clipboard}}`, and custom
    /// variables inside `templateText`.
    static func expandTemplate(
        _ templateText: String,
        title: String = "",
        variables: [String: String] = [:],
        clipboard: String = "",
        date: Date = Date(),
        timeZone: TimeZone = .current
    ) -> String {
        let dateStr = dateString(for: date, timeZone: timeZone)
        let timeStr = timestampString(for: date, timeZone: timeZone)
        var lookup: [String: String] = [
            "date": dateStr,
            "time": timeStr,
            "datetime": "\(dateStr) \(timeStr)",
            "title": title.isEmpty ? dateStr : title,
            "clipboard": clipboard,
        ]
        for (k, v) in variables {
            lookup[k.lowercased()] = v
        }

        let ns = templateText as NSString
        let matches = placeholderRegex.matches(in: templateText, range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return templateText }

        let result = NSMutableString(string: templateText)
        for match in matches.reversed() {
            let key = ns.substring(with: match.range(at: 1)).lowercased()
            let replacement = lookup[key] ?? ""
            result.replaceCharacters(in: match.range, with: replacement)
        }
        return result as String
    }

    // MARK: Format & Flavor Conversion

    /// Converts HTML (or plain text fallback) to Markdown, optionally appending a `Source:` link.
    static func convertHTMLToMarkdown(
        _ input: String,
        sourceURL: URL? = nil,
        includeSourceLink: Bool = false
    ) -> String {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            if includeSourceLink, let url = sourceURL {
                let label = url.host ?? url.absoluteString
                return "Source: [\(label)](\(url.absoluteString))\n"
            }
            return ""
        }

        let converted = HTMLToMarkdown.convert(trimmed, sourceURL: sourceURL)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        var markdown = (converted?.isEmpty == false) ? converted! : trimmed

        if let base = sourceURL {
            markdown = resolveRelativeMarkdownLinks(in: markdown, baseURL: base)
        }

        if includeSourceLink, let url = sourceURL {
            let urlString = url.absoluteString
            if !markdown.contains(urlString) {
                let label = (url.host?.isEmpty == false) ? url.host! : urlString
                markdown += "\n\nSource: [\(label)](\(urlString))"
            }
        }
        return markdown.hasSuffix("\n") ? markdown : markdown + "\n"
    }

    private static let relativeLinkRegex = try! NSRegularExpression(pattern: #"(\[[^\]]*\]\()(/[^)\s]+)(\))"#)

    private static func resolveRelativeMarkdownLinks(in markdown: String, baseURL: URL) -> String {
        let ns = markdown as NSString
        let matches = relativeLinkRegex.matches(in: markdown, range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return markdown }
        let out = NSMutableString(string: markdown)
        for match in matches.reversed() {
            let relPath = ns.substring(with: match.range(at: 2))
            if let resolved = URL(string: relPath, relativeTo: baseURL)?.absoluteURL.absoluteString {
                out.replaceCharacters(in: match.range(at: 2), with: resolved)
            }
        }
        return out as String
    }

    /// Converts Markdown text into `.markdown`, `.plainText`, `.html`, or `.standaloneHTML`.
    static func convertMarkdown(
        _ markdown: String,
        to format: SwashContentFormat,
        flavor: MarkdownFlavor? = nil,
        title: String = "Document"
    ) -> String {
        let effectiveFlavor = flavor ?? MarkdownParser.detectFlavor(markdown)
        switch format {
        case .markdown:
            return markdown
        case .plainText:
            return plainText(from: markdown, flavor: effectiveFlavor)
        case .html:
            let doc = MarkdownDocument.parse(markdown, flavor: effectiveFlavor)
            var options = MarkdownHTMLRenderer.Options()
            options.alertMarkup = true
            options.highlightCode = true
            return MarkdownHTMLRenderer.render(doc, options: options)
        case .standaloneHTML:
            let body = convertMarkdown(markdown, to: .html, flavor: effectiveFlavor, title: title)
            return """
            <!DOCTYPE html>
            <html>
            <head>
            <meta charset="utf-8">
            <meta name="viewport" content="width=device-width, initial-scale=1">
            <meta name="generator" content="Swash">
            <title>\(MarkdownSyntax.escapeHTML(title))</title>
            </head>
            <body>
            <article class="swash-document">
            \(body)
            </article>
            </body>
            </html>
            """
        }
    }

    /// Extracts plain text from leaf blocks without Markdown syntax.
    static func plainText(from markdown: String, flavor: MarkdownFlavor? = nil) -> String {
        let effectiveFlavor = flavor ?? MarkdownParser.detectFlavor(markdown)
        var lines: [String] = []
        func visit(_ node: MarkdownNode) {
            switch node.kind {
            case .paragraph, .heading, .tableCell:
                lines.append(node.plainText)
            case .codeBlock, .htmlBlock:
                lines.append(node.literal.hasSuffix("\n") ? String(node.literal.dropLast()) : node.literal)
            case .frontMatter, .linkReferenceDefinition, .thematicBreak:
                break
            default:
                for child in node.children where child.kind.isBlock {
                    visit(child)
                }
            }
        }
        visit(MarkdownDocument.parse(markdown, flavor: effectiveFlavor).root)
        return lines.joined(separator: "\n")
    }

    /// Converts Markdown between flavors (GitHub, CommonMark, Original, Slack mrkdwn).
    static func convertFlavor(
        _ markdown: String,
        from source: MarkdownFlavor? = nil,
        to target: MarkdownFlavor
    ) -> String {
        let effectiveSource = source ?? MarkdownParser.detectFlavor(markdown)
        return MarkdownParser.convert(markdown, from: effectiveSource, to: target)
    }

    // MARK: To-Dos, Outline & Statistics

    private static let taskLineRegex = try! NSRegularExpression(pattern: #"^\s*[-*+]\s+\[([ xX])\]\s+(.*)$"#)

    /// Extracts `- [ ]` and `- [x]` task items from `markdown`, ignoring tasks inside code blocks.
    static func extractTodos(
        from markdown: String,
        status: SwashTodoStatusFilter = .open,
        file: URL? = nil
    ) -> [SwashTodoItem] {
        let normalized = markdown
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let codeRanges = MarkdownParser.codeRanges(in: normalized)
        let lines = normalized.components(separatedBy: "\n")
        var items: [SwashTodoItem] = []
        var offset = 0

        for (index, line) in lines.enumerated() {
            let length = (line as NSString).length
            let lineRange = NSRange(location: offset, length: length)
            defer { offset += length + 1 }

            guard !codeRanges.blockIntersects(lineRange) else { continue }
            let nsLine = line as NSString
            guard let match = taskLineRegex.firstMatch(in: line, range: NSRange(location: 0, length: nsLine.length)) else {
                continue
            }
            let marker = nsLine.substring(with: match.range(at: 1))
            let isCompleted = marker.lowercased() == "x"
            switch status {
            case .open where isCompleted: continue
            case .completed where !isCompleted: continue
            default: break
            }
            let taskText = nsLine.substring(with: match.range(at: 2)).trimmingCharacters(in: .whitespaces)
            guard !taskText.isEmpty else { continue }
            items.append(SwashTodoItem(text: taskText, isCompleted: isCompleted, line: index + 1, file: file))
        }
        return items
    }

    /// Extracts task items across multiple Markdown files.
    static func extractTodos(
        in files: [URL],
        status: SwashTodoStatusFilter = .open,
        texts: [URL: String] = [:]
    ) -> [SwashTodoItem] {
        var all: [SwashTodoItem] = []
        for file in files {
            let std = file.standardizedFileURL
            guard let text = texts[std] ?? (try? readText(at: std)) else { continue }
            all.append(contentsOf: extractTodos(from: text, status: status, file: std))
        }
        return all
    }

    /// Returns the document's headings formatted as an indented outline list.
    static func formattedOutline(from markdown: String) -> [String] {
        let outline = MarkdownOutline(text: markdown)
        guard let minLevel = outline.headings.map(\.level).min() else { return [] }
        return outline.headings.map { heading in
            let indent = String(repeating: "  ", count: max(0, heading.level - minLevel))
            let title = heading.title.isEmpty ? "Untitled" : heading.title
            return "\(indent)\(String(repeating: "#", count: heading.level)) \(title)"
        }
    }

    /// Computes word, character, line, paragraph, reading time, heading and task counts for `markdown`.
    static func calculateStatistics(for markdown: String) -> SwashStatisticsSummary {
        let stats = MarkdownStatistics(text: markdown)
        let outline = MarkdownOutline(text: markdown)
        let todos = extractTodos(from: markdown, status: .all)
        let openCount = todos.filter { !$0.isCompleted }.count
        let completedCount = todos.filter(\.isCompleted).count
        let lines = markdown.isEmpty ? 0 : markdown.components(separatedBy: .newlines).count
        return SwashStatisticsSummary(
            words: stats.words,
            characters: stats.characters,
            charactersExcludingSpaces: stats.charactersExcludingSpaces,
            lines: lines,
            paragraphs: stats.paragraphs,
            readingMinutes: stats.readingMinutes,
            headings: outline.headings.count,
            openTodos: openCount,
            completedTodos: completedCount
        )
    }

    /// Aggregates statistics across multiple Markdown files.
    static func calculateStatistics(forFiles files: [URL], texts: [URL: String] = [:]) -> SwashStatisticsSummary {
        var words = 0
        var characters = 0
        var charactersExcludingSpaces = 0
        var lines = 0
        var paragraphs = 0
        var headings = 0
        var openTodos = 0
        var completedTodos = 0

        for file in files {
            let std = file.standardizedFileURL
            guard let text = texts[std] ?? (try? readText(at: std)) else { continue }
            let item = calculateStatistics(for: text)
            words += item.words
            characters += item.characters
            charactersExcludingSpaces += item.charactersExcludingSpaces
            lines += item.lines
            paragraphs += item.paragraphs
            headings += item.headings
            openTodos += item.openTodos
            completedTodos += item.completedTodos
        }
        let readingMinutes = words == 0 ? 0 : max(1, Int((Double(words) / 200.0).rounded()))
        return SwashStatisticsSummary(
            words: words,
            characters: characters,
            charactersExcludingSpaces: charactersExcludingSpaces,
            lines: lines,
            paragraphs: paragraphs,
            readingMinutes: readingMinutes,
            headings: headings,
            openTodos: openTodos,
            completedTodos: completedTodos
        )
    }
}

// MARK: - App Intents, Entities & Shortcuts

#if !SWASH_SHORTCUTS_TEST_RUNNER

nonisolated extension MarkdownWrapperStyle: AppEnum {
    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Markdown Style"
    static var caseDisplayRepresentations: [MarkdownWrapperStyle: DisplayRepresentation] = [
        .codeBlock: "Code Block",
        .quoteBlock: "Quote Block",
        .header: "Header",
    ]
}

nonisolated extension SwashContentFormat: AppEnum {
    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Document Format"
    static var caseDisplayRepresentations: [SwashContentFormat: DisplayRepresentation] = [
        .markdown: "Markdown",
        .plainText: "Plain Text",
        .html: "HTML",
        .standaloneHTML: "Standalone HTML",
    ]
}

nonisolated extension SwashInsertPosition: AppEnum {
    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Insert Position"
    static var caseDisplayRepresentations: [SwashInsertPosition: DisplayRepresentation] = [
        .end: "End of Document",
        .beginning: "Beginning of Document",
        .underHeading: "Under Heading",
    ]
}

nonisolated extension SwashAppendStyle: AppEnum {
    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Entry Style"
    static var caseDisplayRepresentations: [SwashAppendStyle: DisplayRepresentation] = [
        .plain: "Plain Text",
        .bullet: "Bullet (- item)",
        .todo: "To-Do (- [ ] item)",
        .timestampedBullet: "Timestamped Bullet (- HH:mm item)",
        .timestampedTodo: "Timestamped To-Do (- [ ] HH:mm item)",
    ]
}

nonisolated extension SwashSearchScope: AppEnum {
    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Search Scope"
    static var caseDisplayRepresentations: [SwashSearchScope: DisplayRepresentation] = [
        .nameAndContent: "Name and Content",
        .nameOnly: "Name Only",
        .contentOnly: "Content Only",
    ]
}

nonisolated extension SwashTodoStatusFilter: AppEnum {
    static var typeDisplayRepresentation: TypeDisplayRepresentation = "To-Do Status"
    static var caseDisplayRepresentations: [SwashTodoStatusFilter: DisplayRepresentation] = [
        .open: "Open (- [ ])",
        .completed: "Completed (- [x])",
        .all: "All",
    ]
}

nonisolated extension SwashDocumentTemplate: AppEnum {
    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Document Template"
    static var caseDisplayRepresentations: [SwashDocumentTemplate: DisplayRepresentation] = [
        .dailyJournal: "Daily Journal",
        .meetingNotes: "Meeting Notes",
        .inboxCapture: "Inbox",
        .projectPlan: "Project Plan",
        .custom: "Custom Template",
    ]
}

nonisolated extension SwashMarkdownFlavorOption: AppEnum {
    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Markdown Flavor"
    static var caseDisplayRepresentations: [SwashMarkdownFlavorOption: DisplayRepresentation] = [
        .github: "GitHub Markdown",
        .commonMark: "CommonMark",
        .original: "Original Markdown",
        .slack: "Slack mrkdwn",
    ]
}

nonisolated extension SwashFocusUnitOption: AppEnum {
    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Focus Unit"
    static var caseDisplayRepresentations: [SwashFocusUnitOption: DisplayRepresentation] = [
        .paragraph: "Paragraph",
        .sentence: "Sentence",
    ]
}

// MARK: - SwashDocumentEntity & Query

struct SwashDocumentEntity: AppEntity, IndexedEntity {
    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Markdown Document"
    static var defaultQuery = SwashDocumentQuery()

    var id: String

    @Property(title: "Title")
    var title: String

    @Property(title: "Folder")
    var folder: String

    @Property(title: "Path")
    var path: String

    @Property(title: "Last Modified")
    var modified: Date?

    @Property(title: "Word Count")
    var wordCount: Int

    var fileURL: URL {
        URL(fileURLWithPath: path)
    }

    init(summary: SwashDocumentSummary) {
        self.id = summary.id
        self.title = summary.title
        self.folder = summary.folder
        self.path = summary.url.path
        self.modified = summary.modified
        self.wordCount = summary.wordCount
    }

    init(url: URL, text: String? = nil, roots: [URL] = []) {
        let summary = SwashShortcutsEngine.documentSummary(for: url, text: text, roots: roots)
        self.init(summary: summary)
    }

    var displayRepresentation: DisplayRepresentation {
        let subtitle: String
        if folder.isEmpty {
            subtitle = "\(wordCount) words"
        } else {
            subtitle = "\(folder) · \(wordCount) words"
        }
        return DisplayRepresentation(
            title: "\(title)",
            subtitle: "\(subtitle)",
            image: .init(systemName: "doc.text")
        )
    }

    var attributeSet: CSSearchableItemAttributeSet {
        let attributes = CSSearchableItemAttributeSet(contentType: .plainText)
        attributes.title = title
        attributes.contentDescription = folder.isEmpty ? "\(wordCount) words" : "\(folder) · \(wordCount) words"
        attributes.contentModificationDate = modified
        attributes.path = path
        return attributes
    }
}

struct SwashDocumentQuery: EntityStringQuery {
    @MainActor
    private static func extraKnownFiles() -> [URL] {
        #if os(macOS)
        let open = NSDocumentController.shared.documents.compactMap(\.fileURL)
        let recent = NSDocumentController.shared.recentDocumentURLs
        return open + recent
        #else
        return []
        #endif
    }

    func entities(for identifiers: [String]) async throws -> [SwashDocumentEntity] {
        let extra = await Self.extraKnownFiles()
        let roots = SwashShortcutsEngine.defaultRootFolders()
        var results: [SwashDocumentEntity] = []
        for id in identifiers {
            if let url = SwashShortcutsEngine.resolveExistingDocument(pathOrTitle: id, in: roots, extraFiles: extra) {
                results.append(SwashDocumentEntity(url: url, roots: roots))
            }
        }
        return results
    }

    func entities(matching string: String) async throws -> [SwashDocumentEntity] {
        let extra = await Self.extraKnownFiles()
        let roots = SwashShortcutsEngine.defaultRootFolders()
        let summaries = SwashShortcutsEngine.findDocuments(
            query: string,
            scope: .nameAndContent,
            in: roots,
            extraFiles: extra,
            limit: 30
        )
        return summaries.map(SwashDocumentEntity.init(summary:))
    }

    func suggestedEntities() async throws -> [SwashDocumentEntity] {
        let extra = await Self.extraKnownFiles()
        let roots = SwashShortcutsEngine.defaultRootFolders()
        let summaries = SwashShortcutsEngine.findDocuments(
            query: "",
            scope: .nameOnly,
            in: roots,
            extraFiles: extra,
            limit: 20
        )
        return summaries.map(SwashDocumentEntity.init(summary:))
    }
}

// MARK: - Helpers for Live Open Documents

@MainActor
private enum SwashLiveDocuments {
    static func openFileMap() -> [URL: String] {
        #if os(macOS)
        var map: [URL: String] = [:]
        for doc in NSDocumentController.shared.documents {
            if let url = doc.fileURL?.standardizedFileURL,
               let text = try? SwashShortcutsEngine.readText(at: url) {
                map[url] = text
            }
        }
        return map
        #else
        return [:]
        #endif
    }

    static func open(url: URL) {
        #if os(macOS)
        DocumentOpener.shared.open([url])
        #else
        DocumentOpener.open(url)
        #endif
    }

    static func currentClipboardString() -> String {
        PlatformPasteboard.string ?? ""
    }
}

// MARK: - 1. Document Intents

struct CreateDocumentIntent: AppIntent {
    static var title: LocalizedStringResource = "Create Markdown Document"
    static var description = IntentDescription("Creates a new Markdown document in Swash and opens it.")
    static var openAppWhenRun: Bool = true

    @Parameter(title: "Title", default: "Untitled Note")
    var title: String

    @Parameter(title: "Content", default: "")
    var content: String

    @MainActor
    func perform() async throws -> some IntentResult & OpensIntent & ReturnsValue<SwashDocumentEntity> {
        let fileURL: URL
        #if os(macOS)
        let root = (try? SwashShortcutsEngine.defaultWritableRoot()) ?? FileManager.default.temporaryDirectory
        let relative = SwashShortcutsEngine.normalizedRelativePath(title) ?? "Untitled Note.md"
        var candidate = root.appendingPathComponent(relative)
        let base = candidate.deletingPathExtension().lastPathComponent
        let folder = candidate.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var counter = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = folder.appendingPathComponent("\(base) \(counter).md")
            counter += 1
        }
        try SwashShortcutsEngine.writeText(content, to: candidate)
        fileURL = candidate
        NSDocumentController.shared.openDocument(withContentsOf: fileURL, display: true) { _, _, _ in }
        #else
        fileURL = try DocumentOpener.createDocument(title: title, text: content)
        DocumentOpener.open(fileURL)
        #endif
        return .result(value: SwashDocumentEntity(url: fileURL, text: content))
    }
}

struct OpenDocumentIntent: AppIntent {
    static var title: LocalizedStringResource = "Open Markdown Document"
    static var description = IntentDescription("Opens a Markdown document in Swash, optionally enabling Focus Mode or Typewriter Scrolling.")
    static var openAppWhenRun: Bool = true

    @Parameter(title: "Document")
    var document: SwashDocumentEntity

    @Parameter(title: "Focus Mode")
    var focusMode: Bool?

    @Parameter(title: "Typewriter Scrolling")
    var typewriterScrolling: Bool?

    @MainActor
    func perform() async throws -> some IntentResult & OpensIntent {
        if let focusMode {
            UserDefaults.standard.set(focusMode, forKey: WritingDefaults.focusMode)
        }
        if let typewriterScrolling {
            UserDefaults.standard.set(typewriterScrolling, forKey: WritingDefaults.typewriterScrolling)
        }
        SwashLiveDocuments.open(url: document.fileURL)
        return .result()
    }
}

struct FindOrCreateDocumentIntent: AppIntent {
    static var title: LocalizedStringResource = "Find or Create Markdown Document"
    static var description = IntentDescription("Finds a Markdown document by relative path or title (such as 'Journal/2026-11-21.md' or 'Inbox.md'), creating it if it doesn't exist yet.")
    static var openAppWhenRun: Bool = false

    @Parameter(title: "Path or Title", default: "Inbox.md")
    var pathOrTitle: String

    @Parameter(title: "Initial Content", default: "")
    var initialContent: String

    @Parameter(title: "Folder")
    var folder: IntentFile?

    func perform() async throws -> some IntentResult & ReturnsValue<SwashDocumentEntity> {
        let rootURL = folder?.fileURL
        let (url, _) = try SwashShortcutsEngine.findOrCreateDocument(
            pathOrTitle: pathOrTitle,
            initialContent: initialContent,
            in: rootURL
        )
        return .result(value: SwashDocumentEntity(url: url))
    }
}

struct CreateDocumentFromTemplateIntent: AppIntent {
    static var title: LocalizedStringResource = "Create Document from Template"
    static var description = IntentDescription("Creates or finds a Markdown document from a built-in or custom template with variables ({{date}}, {{time}}, {{title}}, {{clipboard}}, or custom key=value lines).")
    static var openAppWhenRun: Bool = false

    @Parameter(title: "Template", default: .dailyJournal)
    var template: SwashDocumentTemplate

    @Parameter(title: "Title or Relative Path", default: "")
    var title: String

    @Parameter(title: "Custom Template Body", default: "")
    var customTemplate: String

    @Parameter(title: "Variables (key=value per line)", default: "")
    var variables: String

    @Parameter(title: "Folder")
    var folder: IntentFile?

    func perform() async throws -> some IntentResult & ReturnsValue<SwashDocumentEntity> {
        let clipboard = await SwashLiveDocuments.currentClipboardString()
        let parsedVars = SwashShortcutsEngine.parseVariables(variables)
        let now = Date()
        let rawTitlePattern = title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? SwashShortcutsEngine.defaultTitlePattern(for: template)
            : title
        let expandedPath = SwashShortcutsEngine.expandTemplate(
            rawTitlePattern,
            title: title,
            variables: parsedVars,
            clipboard: clipboard,
            date: now
        )
        let noteTitle = URL(fileURLWithPath: expandedPath).deletingPathExtension().lastPathComponent
        let bodyTemplate = SwashShortcutsEngine.templateBody(for: template, customBody: customTemplate)
        let expandedBody = SwashShortcutsEngine.expandTemplate(
            bodyTemplate,
            title: noteTitle,
            variables: parsedVars,
            clipboard: clipboard,
            date: now
        )
        let (url, _) = try SwashShortcutsEngine.findOrCreateDocument(
            pathOrTitle: expandedPath,
            initialContent: expandedBody,
            in: folder?.fileURL
        )
        return .result(value: SwashDocumentEntity(url: url))
    }
}

struct GetDocumentContentsIntent: AppIntent {
    static var title: LocalizedStringResource = "Get Document Contents"
    static var description = IntentDescription("Returns a Swash document's contents as Markdown, plain text, HTML, or standalone styled HTML.")
    static var openAppWhenRun: Bool = false

    @Parameter(title: "Document")
    var document: SwashDocumentEntity

    @Parameter(title: "Format", default: .markdown)
    var format: SwashContentFormat

    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        let text = try SwashShortcutsEngine.readText(at: document.fileURL)
        let output = SwashShortcutsEngine.convertMarkdown(text, to: format, title: document.title)
        return .result(value: output)
    }
}

struct AppendToDocumentIntent: AppIntent {
    static var title: LocalizedStringResource = "Append or Prepend to Document"
    static var description = IntentDescription("Appends or prepends text to a Swash Markdown document (at the end, beginning, or under a heading; as plain text, a bullet, a to-do, or a timestamped item).")
    static var openAppWhenRun: Bool = false

    @Parameter(title: "Text")
    var text: String

    @Parameter(title: "Document")
    var document: SwashDocumentEntity?

    @Parameter(title: "Path or Name (if no Document)", default: "Inbox.md")
    var pathOrName: String

    @Parameter(title: "Position", default: .end)
    var position: SwashInsertPosition

    @Parameter(title: "Heading", default: "")
    var heading: String

    @Parameter(title: "Style", default: .plain)
    var style: SwashAppendStyle

    @Parameter(title: "Create if Missing", default: true)
    var createIfMissing: Bool

    func perform() async throws -> some IntentResult & ReturnsValue<SwashDocumentEntity> {
        let targetURL: URL
        if let document {
            targetURL = document.fileURL
        } else if let existing = SwashShortcutsEngine.resolveExistingDocument(pathOrTitle: pathOrName) {
            targetURL = existing
        } else if createIfMissing {
            let title = URL(fileURLWithPath: pathOrName).deletingPathExtension().lastPathComponent
            let initial = title.isEmpty ? "" : "# \(title)\n"
            targetURL = try SwashShortcutsEngine.findOrCreateDocument(
                pathOrTitle: pathOrName,
                initialContent: initial
            ).url
        } else {
            throw SwashShortcutsError.documentNotFound(pathOrName)
        }

        let updatedText = try SwashShortcutsEngine.modifyText(at: targetURL) { existingText in
            SwashShortcutsEngine.insert(text, into: existingText, position: position, heading: heading, style: style)
        }
        return .result(value: SwashDocumentEntity(url: targetURL, text: updatedText))
    }
}

struct FindDocumentsIntent: AppIntent {
    static var title: LocalizedStringResource = "Find Markdown Documents"
    static var description = IntentDescription("Searches your Swash Markdown documents by filename, full-text content, or both.")
    static var openAppWhenRun: Bool = false

    @Parameter(title: "Query", default: "")
    var query: String

    @Parameter(title: "Search Scope", default: .nameAndContent)
    var scope: SwashSearchScope

    @Parameter(title: "Folder")
    var folder: IntentFile?

    @Parameter(title: "Limit", default: 20)
    var limit: Int

    func perform() async throws -> some IntentResult & ReturnsValue<[SwashDocumentEntity]> {
        let roots = folder?.fileURL.map { [$0] }
        let summaries = SwashShortcutsEngine.findDocuments(
            query: query,
            scope: scope,
            in: roots,
            limit: max(1, min(limit, 200))
        )
        return .result(value: summaries.map(SwashDocumentEntity.init(summary:)))
    }
}

#if os(macOS)
/// Opens the macOS Quick Note panel (iOS has the Quick Note widget instead).
struct QuickNoteIntent: AppIntent {
    static var title: LocalizedStringResource = "Quick Note"
    static var description = IntentDescription("Opens Swash's Quick Note panel to jot something down.")
    static var openAppWhenRun: Bool = true

    @MainActor
    func perform() async throws -> some IntentResult {
        QuickCaptureController.shared.show()
        return .result()
    }
}
#endif

// MARK: - 2. Convert & Export Intents

struct ConvertTextToMarkdownIntent: AppIntent {
    static var title: LocalizedStringResource = "Convert Text to Markdown Format"
    static var description = IntentDescription("Formats plain text as a Markdown code block, quote, or header.")
    static var openAppWhenRun: Bool = false

    @Parameter(title: "Text")
    var text: String

    @Parameter(title: "Style", default: .codeBlock)
    var style: MarkdownWrapperStyle

    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        let formatted: String
        switch style {
        case .codeBlock:
            formatted = "```\n\(text)\n```"
        case .quoteBlock:
            formatted = text.components(separatedBy: .newlines).map { "> \($0)" }.joined(separator: "\n")
        case .header:
            formatted = "# \(text)"
        }
        return .result(value: formatted)
    }
}

struct ConvertHTMLToMarkdownIntent: AppIntent {
    static var title: LocalizedStringResource = "Convert HTML to Markdown"
    static var description = IntentDescription("Converts HTML or web page content to clean Markdown, optionally appending a link to the source URL.")
    static var openAppWhenRun: Bool = false

    @Parameter(title: "HTML or Text")
    var html: String

    @Parameter(title: "Source URL")
    var sourceURL: URL?

    @Parameter(title: "Include Source Link", default: false)
    var includeSourceLink: Bool

    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        let markdown = SwashShortcutsEngine.convertHTMLToMarkdown(
            html,
            sourceURL: sourceURL,
            includeSourceLink: includeSourceLink
        )
        return .result(value: markdown)
    }
}

struct ConvertMarkdownIntent: AppIntent {
    static var title: LocalizedStringResource = "Convert Markdown to HTML or Plain Text"
    static var description = IntentDescription("Converts Markdown text to HTML, standalone styled HTML, or plain text.")
    static var openAppWhenRun: Bool = false

    @Parameter(title: "Markdown")
    var markdown: String

    @Parameter(title: "Format", default: .html)
    var format: SwashContentFormat

    @Parameter(title: "Flavor", default: .github)
    var flavor: SwashMarkdownFlavorOption

    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        let converted = SwashShortcutsEngine.convertMarkdown(
            markdown,
            to: format,
            flavor: flavor.markdownFlavor
        )
        return .result(value: converted)
    }
}

struct ChangeMarkdownFlavorIntent: AppIntent {
    static var title: LocalizedStringResource = "Convert Markdown Flavor"
    static var description = IntentDescription("Converts Markdown text between GitHub Flavored Markdown, Slack mrkdwn, CommonMark, and Original Markdown.")
    static var openAppWhenRun: Bool = false

    @Parameter(title: "Markdown")
    var markdown: String

    @Parameter(title: "From Flavor")
    var sourceFlavor: SwashMarkdownFlavorOption?

    @Parameter(title: "To Flavor", default: .slack)
    var targetFlavor: SwashMarkdownFlavorOption

    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        let converted = SwashShortcutsEngine.convertFlavor(
            markdown,
            from: sourceFlavor?.markdownFlavor,
            to: targetFlavor.markdownFlavor
        )
        return .result(value: converted)
    }
}

struct ExportPDFIntent: AppIntent {
    static var title: LocalizedStringResource = "Export Document as PDF"
    static var description = IntentDescription("Renders a Swash Markdown document (or Markdown text) to a paginated PDF file.")
    static var openAppWhenRun: Bool = false

    @Parameter(title: "Document")
    var document: SwashDocumentEntity?

    @Parameter(title: "Markdown Text (if no Document)", default: "")
    var markdown: String

    @Parameter(title: "Title", default: "Document")
    var title: String

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<IntentFile> {
        let text: String
        let fileURL: URL?
        let docTitle: String
        if let document {
            fileURL = document.fileURL
            text = try SwashShortcutsEngine.readText(at: document.fileURL)
            docTitle = document.title
        } else {
            fileURL = nil
            text = markdown
            docTitle = title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Document" : title
        }
        let source = DocumentExporter.Source(
            text: text,
            flavor: MarkdownParser.detectFlavor(text),
            fileURL: fileURL,
            title: docTitle
        )
        let safeName = docTitle.replacingOccurrences(of: "/", with: "-")
        #if os(macOS)
        let outURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString)-\(safeName).pdf")
        try await DocumentExporter.exportPDF(source, to: outURL)
        let pdfData = try Data(contentsOf: outURL)
        try? FileManager.default.removeItem(at: outURL)
        #else
        let pdfData = try await DocumentExporter.exportPDF(source)
        #endif
        let intentFile = IntentFile(data: pdfData, filename: "\(safeName).pdf", type: .pdf)
        return .result(value: intentFile)
    }
}

// MARK: - 3. Tasks, Outline & Statistics Intents

struct GetTodosIntent: AppIntent {
    static var title: LocalizedStringResource = "Get To-Dos from Markdown"
    static var description = IntentDescription("Finds open or completed Markdown task list items (- [ ] / - [x]) in a document or across a folder.")
    static var openAppWhenRun: Bool = false

    @Parameter(title: "Document")
    var document: SwashDocumentEntity?

    @Parameter(title: "Folder")
    var folder: IntentFile?

    @Parameter(title: "Status", default: .open)
    var status: SwashTodoStatusFilter

    func perform() async throws -> some IntentResult & ReturnsValue<[String]> {
        let items: [SwashTodoItem]
        if let document {
            let text = try SwashShortcutsEngine.readText(at: document.fileURL)
            items = SwashShortcutsEngine.extractTodos(from: text, status: status, file: document.fileURL)
        } else {
            let roots = folder?.fileURL.map { [$0] }
            let files = SwashShortcutsEngine.discoverFiles(in: roots)
            items = SwashShortcutsEngine.extractTodos(in: files, status: status)
        }
        return .result(value: items.map(\.text))
    }
}

struct GetDocumentOutlineIntent: AppIntent {
    static var title: LocalizedStringResource = "Get Document Outline"
    static var description = IntentDescription("Returns the headings of a Swash Markdown document as an indented outline list.")
    static var openAppWhenRun: Bool = false

    @Parameter(title: "Document")
    var document: SwashDocumentEntity?

    @Parameter(title: "Markdown Text (if no Document)", default: "")
    var markdown: String

    func perform() async throws -> some IntentResult & ReturnsValue<[String]> {
        let sourceText: String
        if let document {
            sourceText = try SwashShortcutsEngine.readText(at: document.fileURL)
        } else {
            sourceText = markdown
        }
        return .result(value: SwashShortcutsEngine.formattedOutline(from: sourceText))
    }
}

struct GetWordCountIntent: AppIntent {
    static var title: LocalizedStringResource = "Get Word & Character Count"
    static var description = IntentDescription("Calculates word, character, and line count for a Swash document or input Markdown text.")
    static var openAppWhenRun: Bool = false

    @Parameter(title: "Text", default: "")
    var text: String

    @Parameter(title: "Document")
    var document: SwashDocumentEntity?

    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        let targetText: String
        if let document {
            targetText = try SwashShortcutsEngine.readText(at: document.fileURL)
        } else {
            targetText = text
        }
        let stats = SwashShortcutsEngine.calculateStatistics(for: targetText)
        return .result(value: stats.summaryString)
    }
}

struct GetDocumentStatisticsIntent: AppIntent {
    static var title: LocalizedStringResource = "Get Document Statistics"
    static var description = IntentDescription("Returns the word count for a Swash document, folder, or Markdown text, for logging writing streaks.")
    static var openAppWhenRun: Bool = false

    @Parameter(title: "Document")
    var document: SwashDocumentEntity?

    @Parameter(title: "Folder")
    var folder: IntentFile?

    @Parameter(title: "Markdown Text (if no Document or Folder)", default: "")
    var text: String

    func perform() async throws -> some IntentResult & ReturnsValue<Int> {
        let stats: SwashStatisticsSummary
        if let document {
            let content = try SwashShortcutsEngine.readText(at: document.fileURL)
            stats = SwashShortcutsEngine.calculateStatistics(for: content)
        } else if let folderURL = folder?.fileURL {
            let files = SwashShortcutsEngine.discoverFiles(in: [folderURL])
            stats = SwashShortcutsEngine.calculateStatistics(forFiles: files)
        } else {
            stats = SwashShortcutsEngine.calculateStatistics(for: text)
        }
        return .result(value: stats.words)
    }
}

// MARK: - 4. Writing Modes & Focus Filter

struct SetWritingModeIntent: AppIntent {
    static var title: LocalizedStringResource = "Set Writing Mode"
    static var description = IntentDescription("Turns Focus Mode or Typewriter Scrolling on or off in Swash.")
    static var openAppWhenRun: Bool = false

    @Parameter(title: "Focus Mode", default: true)
    var focusMode: Bool

    @Parameter(title: "Focus Unit", default: .paragraph)
    var focusUnit: SwashFocusUnitOption

    @Parameter(title: "Typewriter Scrolling", default: false)
    var typewriterScrolling: Bool

    func perform() async throws -> some IntentResult {
        UserDefaults.standard.set(focusMode, forKey: WritingDefaults.focusMode)
        UserDefaults.standard.set(focusUnit.rawValue.lowercased(), forKey: WritingDefaults.focusUnit)
        UserDefaults.standard.set(typewriterScrolling, forKey: WritingDefaults.typewriterScrolling)
        return .result()
    }
}

struct SwashFocusFilterIntent: SetFocusFilterIntent {
    static var title: LocalizedStringResource = "Swash Writing Focus"
    static var description: IntentDescription? = IntentDescription("Automatically enables Focus Mode or Typewriter Scrolling in Swash while this system Focus is active.")

    @Parameter(title: "Focus Mode", default: true)
    var focusMode: Bool

    @Parameter(title: "Focus Unit", default: .paragraph)
    var focusUnit: SwashFocusUnitOption

    @Parameter(title: "Typewriter Scrolling", default: false)
    var typewriterScrolling: Bool

    var displayRepresentation: DisplayRepresentation {
        var active: [String] = []
        if focusMode { active.append("Focus Mode (\(focusUnit.rawValue))") }
        if typewriterScrolling { active.append("Typewriter Scrolling") }
        let subtitle = active.isEmpty ? "Standard editing" : active.joined(separator: ", ")
        return DisplayRepresentation(title: "Swash Writing Focus", subtitle: "\(subtitle)")
    }

    func perform() async throws -> some IntentResult {
        UserDefaults.standard.set(focusMode, forKey: WritingDefaults.focusMode)
        UserDefaults.standard.set(focusUnit.rawValue.lowercased(), forKey: WritingDefaults.focusUnit)
        UserDefaults.standard.set(typewriterScrolling, forKey: WritingDefaults.typewriterScrolling)
        return .result()
    }
}

// MARK: - 5. AppShortcutsProvider (Siri & Spotlight)

struct SwashShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: CreateDocumentIntent(),
            phrases: [
                "Create a new document in \(.applicationName)",
                "New \(.applicationName) note",
            ],
            shortTitle: "Create Document",
            systemImageName: "square.and.pencil"
        )
        AppShortcut(
            intent: OpenDocumentIntent(),
            phrases: [
                "Open \(\.$document) in \(.applicationName)",
                "Open a note in \(.applicationName)",
            ],
            shortTitle: "Open Document",
            systemImageName: "doc.text"
        )
        AppShortcut(
            intent: AppendToDocumentIntent(),
            phrases: [
                "Append to a note in \(.applicationName)",
                "Add to \(.applicationName) inbox",
            ],
            shortTitle: "Append to Note",
            systemImageName: "text.append"
        )
        AppShortcut(
            intent: FindDocumentsIntent(),
            phrases: [
                "Find notes in \(.applicationName)",
                "Search \(.applicationName) documents",
            ],
            shortTitle: "Find Documents",
            systemImageName: "doc.text.magnifyingglass"
        )
        AppShortcut(
            intent: GetTodosIntent(),
            phrases: [
                "Get open to-dos in \(.applicationName)",
                "List tasks in \(.applicationName)",
            ],
            shortTitle: "Get To-Dos",
            systemImageName: "checklist"
        )
        #if os(macOS)
        AppShortcut(
            intent: QuickNoteIntent(),
            phrases: [
                "Quick note in \(.applicationName)",
                "Jot something down in \(.applicationName)",
            ],
            shortTitle: "Quick Note",
            systemImageName: "note.text.badge.plus"
        )
        #endif
        AppShortcut(
            intent: GetWordCountIntent(),
            phrases: [
                "Count words with \(.applicationName)",
                "Get word count in \(.applicationName)",
            ],
            shortTitle: "Word Count",
            systemImageName: "text.word.spacing"
        )
    }
}

#endif

//
//  DocumentOpening.swift
//  Swash
//
//  Opening, reopening and importing documents: open requests from Finder and URLs are coalesced
//  and checked first so failures get a specific explanation; closed documents can be reopened;
//  Word, RTF and HTML files are imported as new Markdown documents.
//

#if os(macOS)
import AppKit
import SwiftUI
import UniformTypeIdentifiers
import Combine
import OSLog
import PixerateMarkdown

// MARK: - Opening

enum DocumentOpenFailure: Equatable {
    case missing, folder, unreadable, tooLarge(Int64), notText

    var explanation: String {
        switch self {
        case .missing: return "The file no longer exists."
        case .folder: return "It is a folder, not a document."
        case .unreadable: return "Swash doesn't have permission to read it."
        case .tooLarge(let bytes):
            return "It is too large to edit (\(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)))."
        case .notText: return "It isn't a text file."
        }
    }
}

@MainActor
final class DocumentOpener {
    static let shared = DocumentOpener()

    /// Opening more documents than this at once asks first.
    static let confirmationThreshold = 10
    nonisolated static let maximumFileSize: Int64 = 50 * 1024 * 1024

    private var pending: [URL] = []
    private var flushScheduled = false

    /// Queues `urls` for opening. Requests arriving within a moment of each other (a Finder
    /// multi-selection is delivered as several events) are handled together.
    func open(_ urls: [URL]) {
        for url in urls where !pending.contains(url) { pending.append(url) }
        guard !flushScheduled else { return }
        flushScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in self?.flush() }
    }

    private func flush() {
        flushScheduled = false
        let urls = pending
        pending = []
        guard !urls.isEmpty else { return }

        if urls.count > Self.confirmationThreshold {
            let alert = NSAlert()
            alert.messageText = "Open \(urls.count) documents?"
            alert.informativeText = "Each document opens in its own window."
            alert.addButton(withTitle: "Open All")
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }

        var failures: [(URL, DocumentOpenFailure)] = []
        for url in urls {
            if let failure = Self.check(url) {
                failures.append((url, failure))
                continue
            }
            NSDocumentController.shared.openDocument(withContentsOf: url, display: true) { _, _, error in
                guard let error = error else { return }
                let nsError = error as NSError
                if nsError.domain == NSCocoaErrorDomain && nsError.code == NSUserCancelledError { return }
                NSApp.presentError(error)
            }
        }
        if !failures.isEmpty { Self.report(failures) }
    }

    /// Why `url` can't be opened as a document, or nil when it looks fine.
    nonisolated static func check(_ url: URL) -> DocumentOpenFailure? {
        let manager = FileManager.default
        var isDirectory: ObjCBool = false
        guard manager.fileExists(atPath: url.path, isDirectory: &isDirectory) else { return .missing }
        if isDirectory.boolValue { return .folder }
        guard manager.isReadableFile(atPath: url.path),
              let handle = try? FileHandle(forReadingFrom: url) else { return .unreadable }
        defer { try? handle.close() }
        if let size = (try? manager.attributesOfItem(atPath: url.path))?[.size] as? Int64, size > maximumFileSize {
            return .tooLarge(size)
        }
        let head = (try? handle.read(upToCount: 8192)) ?? Data()
        return looksLikeText(head) ? nil : .notText
    }

    /// Text has no NUL bytes, unless it is UTF-16 (which starts with a byte-order mark).
    nonisolated static func looksLikeText(_ head: Data) -> Bool {
        if head.starts(with: [0xFF, 0xFE]) || head.starts(with: [0xFE, 0xFF]) { return true }
        return !head.contains(0)
    }

    private static func report(_ failures: [(URL, DocumentOpenFailure)]) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        if failures.count == 1, let (url, failure) = failures.first {
            alert.messageText = "“\(url.lastPathComponent)” can't be opened."
            alert.informativeText = failure.explanation
        } else {
            alert.messageText = "\(failures.count) files can't be opened."
            alert.informativeText = failures.map { "\($0.0.lastPathComponent): \($0.1.explanation)" }.joined(separator: "\n")
        }
        alert.runModal()
    }
}

// MARK: - New documents with content

/// Initial text for untitled documents (quick capture, import). Each seed is bound to the specific
/// `NSDocument` (and `NSWindow`, once known) created for it, so a concurrent ⌘N or restored window
/// never claims another document's seed.
///
/// Seeds hold their document and window weakly and are matched by identity (`===`), not by
/// `ObjectIdentifier`: an identifier can be reused by a later object at the same address
/// (GOTCHAS #13), which would hand a stale seed to an unrelated window. A seed whose window closes
/// before it is claimed is dropped, and seeds whose document and window are both gone are pruned.
@MainActor
enum NewDocumentSeed {
    private struct Seed {
        weak var document: NSDocument?
        weak var window: NSWindow?
        let text: String
        var isOrphaned: Bool { document == nil && window == nil }
    }

    private static var seeds: [Seed] = []
    private static var closeObserver: NSObjectProtocol?
    private static let logger = Logger(subsystem: "com.pixerate.Swash", category: "Document")

    static func createDocument(with text: String) {
        do {
            let document = try NSDocumentController.shared.openUntitledDocumentAndDisplay(true)
            let window = document.windowControllers.lazy.compactMap(\.window).first
            register(text: text, document: document, window: window)
        } catch {
            logger.error("Failed to open untitled document: \(error.localizedDescription)")
        }
    }

    /// The seed bound to `window` or to its document, removed so it is applied once.
    static func take(for window: NSWindow) -> String? {
        pruneOrphans()
        let document = document(for: window)
        guard let index = seeds.firstIndex(where: { seed in
            seed.window === window || (document != nil && seed.document === document)
        }) else { return nil }
        return seeds.remove(at: index).text
    }

    private static func register(text: String, document: NSDocument?, window: NSWindow?) {
        installCloseObserver()
        pruneOrphans()
        seeds.append(Seed(document: document, window: window, text: text))
    }

    private static func document(for window: NSWindow) -> NSDocument? {
        (window.windowController?.document as? NSDocument) ?? NSDocumentController.shared.document(for: window)
    }

    private static func pruneOrphans() {
        seeds.removeAll(where: \.isOrphaned)
    }

    /// Drops the seeds bound to `window`, or to its document, when the window closes unclaimed.
    private static func discardSeeds(forClosing window: NSWindow) {
        let document = document(for: window)
        seeds.removeAll { seed in
            seed.isOrphaned || seed.window === window || (document != nil && seed.document === document)
        }
    }

    private static func installCloseObserver() {
        guard closeObserver == nil else { return }
        // `queue: nil` delivers on the posting thread; windows close on the main thread.
        closeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: nil, queue: nil
        ) { notification in
            guard let window = notification.object as? NSWindow else { return }
            MainActor.assumeIsolated { discardSeeds(forClosing: window) }
        }
    }

    #if DEBUG
    static func registerForTesting(text: String, document: NSDocument? = nil, window: NSWindow? = nil) {
        register(text: text, document: document, window: window)
    }

    /// Seeds still waiting to be claimed, after pruning those whose document and window are gone.
    static var pendingCountForTesting: Int {
        pruneOrphans()
        return seeds.count
    }

    static func clearForTesting() {
        seeds.removeAll()
    }
    #endif
}

// MARK: - Reopening

/// Recently closed document files, most recent last, for File ▸ Reopen Closed Document.
@MainActor
final class RecentlyClosedDocuments: ObservableObject {
    static let shared = RecentlyClosedDocuments()
    @Published private(set) var urls: [URL] = []
    private let limit = 20

    func push(_ url: URL) {
        urls.removeAll { $0 == url }
        urls.append(url)
        if urls.count > limit { urls.removeFirst(urls.count - limit) }
    }

    /// Reopens the most recently closed document that isn't open again already and still exists.
    func reopenLast() {
        let open = Set(NSDocumentController.shared.documents.compactMap { $0.fileURL?.standardizedFileURL })
        while let url = urls.popLast() {
            if open.contains(url.standardizedFileURL) { continue }
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            DocumentOpener.shared.open([url])
            return
        }
        NSSound.beep()
    }
}

// MARK: - Importing

enum DocumentImporter {
    static let importableTypes: [UTType] = [
        .rtf, .rtfd, .flatRTFD, .html, .webArchive,
        UTType("org.openxmlformats.wordprocessingml.document"),
        UTType("com.microsoft.word.doc"),
        UTType("org.oasis-open.opendocument.text"),
    ].compactMap { $0 }

    /// Asks for Word, RTF, HTML or OpenDocument files and opens each as a new Markdown document.
    @MainActor
    static func runImportPanel() {
        let panel = NSOpenPanel()
        panel.title = "Import"
        panel.message = "Choose Word, RTF, HTML or OpenDocument files to convert to Markdown."
        panel.prompt = "Import"
        panel.allowedContentTypes = importableTypes
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        var failed: [String] = []
        for url in panel.urls {
            if let markdown = markdown(from: url) {
                NewDocumentSeed.createDocument(with: markdown)
            } else {
                failed.append(url.lastPathComponent)
            }
        }
        if !failed.isEmpty {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = failed.count == 1 ? "“\(failed[0])” couldn't be imported." : "\(failed.count) files couldn't be imported."
            alert.informativeText = "Swash couldn't read any text from \(failed.count == 1 ? "it" : failed.joined(separator: ", "))."
            alert.runModal()
        }
    }

    /// Converts a rich-text document to Markdown through HTML, the same path as pasting rich text.
    static func markdown(from url: URL) -> String? {
        let html: String
        if let type = UTType(filenameExtension: url.pathExtension), type.conforms(to: .html),
           let source = try? String(contentsOf: url, encoding: .utf8) {
            html = source
        } else {
            guard let attributed = try? NSAttributedString(url: url, options: [:], documentAttributes: nil),
                  attributed.length > 0,
                  let data = try? attributed.data(from: NSRange(location: 0, length: attributed.length),
                                                  documentAttributes: [.documentType: NSAttributedString.DocumentType.html]),
                  let converted = String(data: data, encoding: .utf8) else { return nil }
            html = converted
        }
        guard let markdown = HTMLToMarkdown.convert(html)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !markdown.isEmpty else { return nil }
        return markdown + "\n"
    }
}

// MARK: - Menu commands

struct FileMenuCommands: Commands {
    @ObservedObject private var recentlyClosed = RecentlyClosedDocuments.shared

    var body: some Commands {
        CommandGroup(after: .newItem) {
            Button("Reopen Closed Document") { recentlyClosed.reopenLast() }
                .keyboardShortcut("t", modifiers: [.command, .shift])
                .disabled(recentlyClosed.urls.isEmpty)
        }
        CommandGroup(after: .importExport) {
            Button("Import…") { DocumentImporter.runImportPanel() }
                .keyboardShortcut("i", modifiers: [.command, .shift])
        }
    }
}
#endif

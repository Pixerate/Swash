//
//  DocumentOpener.swift
//  Swash
//
//  Opens documents from code on iOS, where SwiftUI offers no openDocument / newDocument action:
//  swash:// links, the Create Document shortcut and notes saved by the share extension. New
//  notes are written to the app's Documents folder (On My iPhone › Swash) and handed to the
//  document browser that DocumentGroup hosts, as UIDocumentBrowserViewController apps do.
//

#if os(iOS)
import UIKit

@MainActor
enum DocumentOpener {
    /// Shared with the share extension, which leaves notes in its `Inbox` folder.
    nonisolated static let appGroupIdentifier = "group.com.pixerate.Swash"

    static var documentsFolder: URL {
        get throws {
            try FileManager.default.url(for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        }
    }

    /// The share extension's drop folder, or nil when the App Group isn't available (unsigned builds).
    nonisolated static var inboxFolder: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupIdentifier)?
            .appendingPathComponent("Inbox", isDirectory: true)
    }

    /// Handles `swash://new?title=…&text=…` and `swash://open?path=…`. Returns false for other URLs.
    @discardableResult
    static func handle(_ url: URL) -> Bool {
        guard url.scheme == "swash" else { return false }
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func value(_ name: String) -> String? { items.first(where: { $0.name == name })?.value }
        switch url.host {
        case "new":
            guard let file = try? createDocument(title: value("title") ?? "Untitled", text: value("text") ?? "") else { return false }
            open(file)
            return true
        case "open":
            guard let path = value("path") else { return false }
            open(URL(fileURLWithPath: path))
            return true
        default:
            return false
        }
    }

    /// Writes a new note into Documents under a unique name and returns its URL.
    static func createDocument(title: String, text: String) throws -> URL {
        let folder = try documentsFolder
        let base = title.replacingOccurrences(of: "/", with: "-").trimmingCharacters(in: .whitespacesAndNewlines)
        let file = uniqueURL(in: folder, base: base.isEmpty ? "Untitled" : base)
        try text.write(to: file, atomically: true, encoding: .utf8)
        return file
    }

    /// Moves notes the share extension saved into Documents; returns the newest, if any.
    @discardableResult
    static func importInbox() -> URL? {
        guard let inbox = inboxFolder, let folder = try? documentsFolder,
              let files = try? FileManager.default.contentsOfDirectory(at: inbox, includingPropertiesForKeys: [.contentModificationDateKey]) else { return nil }
        var newest: (url: URL, date: Date)?
        for file in files where file.pathExtension.lowercased() == "md" {
            let destination = uniqueURL(in: folder, base: file.deletingPathExtension().lastPathComponent)
            guard (try? FileManager.default.moveItem(at: file, to: destination)) != nil else { continue }
            let date = (try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            if newest == nil || date > newest!.date { newest = (destination, date) }
        }
        return newest?.url
    }

    /// Opens `url` in the document browser, retrying briefly while the app finishes launching.
    /// Any open document is saved before the new document is picked, so unsaved edits are never lost.
    static func open(_ url: URL, attempts: Int = 10) {
        if let current = openDocuments().first, current.fileURL.standardizedFileURL == url.standardizedFileURL {
            return
        }

        guard let browser = documentBrowser() else {
            if attempts > 0 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { open(url, attempts: attempts - 1) }
            }
            return
        }
        Task { @MainActor in
            await saveOpenDocuments()
            reveal(url, in: browser)
        }
    }

    /// Finds all open `UIDocument`s in the given view controller hierarchy.
    static func findOpenDocuments(in controller: UIViewController?, into documents: inout [UIDocument]) {
        guard let controller = controller else { return }
        if let documentController = controller as? UIDocumentViewController,
           let document = documentController.document {
            if !documents.contains(where: { $0 === document }) {
                documents.append(document)
            }
        }
        for child in controller.children {
            findOpenDocuments(in: child, into: &documents)
        }
        if let presented = controller.presentedViewController, presented.presentingViewController === controller {
            findOpenDocuments(in: presented, into: &documents)
        }
    }

    /// Finds all open `UIDocument`s across all connected window scenes.
    static func openDocuments() -> [UIDocument] {
        var documents: [UIDocument] = []
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        for scene in scenes {
            for window in scene.windows {
                findOpenDocuments(in: window.rootViewController, into: &documents)
            }
        }
        return documents
    }

    /// Saves all open documents across all connected window scenes.
    @discardableResult
    static func saveOpenDocuments() async -> Bool {
        await save(openDocuments())
    }

    /// Saves those of `documents` that are open and have unsaved changes. Unchanged ones are left
    /// alone: this runs every time the app goes inactive (Control Centre, the app switcher), and
    /// rewriting unchanged files would touch them and sync them for nothing.
    @discardableResult
    static func save(_ documents: [UIDocument]) async -> Bool {
        var allSucceeded = true
        for document in documents where !document.documentState.contains(.closed) && document.hasUnsavedChanges {
            let success = await document.save(to: document.fileURL, for: .forOverwriting)
            if !success { allSucceeded = false }
        }
        return allSucceeded
    }

    /// Saves all open documents on scene backgrounding or deactivation, requesting background execution time.
    static func saveOpenDocumentsOnBackground() {
        var taskID: UIBackgroundTaskIdentifier = .invalid
        taskID = UIApplication.shared.beginBackgroundTask(withName: "SwashSaveOpenDocuments") {
            if taskID != .invalid {
                UIApplication.shared.endBackgroundTask(taskID)
                taskID = .invalid
            }
        }
        Task { @MainActor in
            await saveOpenDocuments()
            if taskID != .invalid {
                UIApplication.shared.endBackgroundTask(taskID)
                taskID = .invalid
            }
        }
    }

    /// Hands `url` to the browser as if the user had picked it. Files outside the app's own folder
    /// are revealed first, which gives the browser a URL it can open.
    private static func reveal(_ url: URL, in browser: UIDocumentBrowserViewController) {
        let local = (try? documentsFolder).map { url.standardizedFileURL.path.hasPrefix($0.standardizedFileURL.path) } ?? false
        if local {
            browser.delegate?.documentBrowser?(browser, didPickDocumentsAt: [url])
            return
        }
        browser.revealDocument(at: url, importIfNeeded: false) { revealed, error in
            guard let revealed = revealed, error == nil else { return }
            browser.delegate?.documentBrowser?(browser, didPickDocumentsAt: [revealed])
        }
    }

    /// The document browser of the foreground scene. DocumentGroup hosts its documents in a
    /// UIDocumentViewController whose launch options hold the browser, on screen or not.
    private static func documentBrowser() -> UIDocumentBrowserViewController? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let ordered = scenes.filter { $0.activationState == .foregroundActive } + scenes.filter { $0.activationState != .foregroundActive }
        for scene in ordered {
            for window in scene.windows {
                if let browser = findBrowser(in: window.rootViewController) { return browser }
            }
        }
        return nil
    }

    private static func findBrowser(in controller: UIViewController?) -> UIDocumentBrowserViewController? {
        guard let controller = controller else { return nil }
        if let documentController = controller as? UIDocumentViewController { return documentController.launchOptions.browserViewController }
        if let browser = controller as? UIDocumentBrowserViewController { return browser }
        for child in controller.children {
            if let browser = findBrowser(in: child) { return browser }
        }
        // DocumentGroup's launch screen presents the browser as a card
        if let presented = controller.presentedViewController, presented.presentingViewController === controller {
            return findBrowser(in: presented)
        }
        return nil
    }

    private static func uniqueURL(in folder: URL, base: String) -> URL {
        var candidate = folder.appendingPathComponent(base).appendingPathExtension("md")
        var counter = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = folder.appendingPathComponent("\(base) \(counter)").appendingPathExtension("md")
            counter += 1
        }
        return candidate
    }
}
#endif

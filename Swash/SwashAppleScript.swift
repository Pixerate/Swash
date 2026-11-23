//
//  SwashAppleScript.swift
//  Swash
//

#if os(macOS)
import AppKit
import Foundation

@objc(SwashCreateNoteCommand)
final class SwashCreateNoteCommand: NSScriptCommand {
    override func performDefaultImplementation() -> Any? {
        let title = (evaluatedArguments?["title"] as? String) ?? "Untitled Note"
        let content = (evaluatedArguments?["content"] as? String) ?? ""
        let fileName = "\(title).md".replacingOccurrences(of: "/", with: "-")
        let fileURL = FileManager.default.temporaryDirectory.appendingPathComponent(fileName)

        do {
            try content.write(to: fileURL, atomically: true, encoding: .utf8)
        } catch {
            scriptErrorNumber = NSInternalScriptError
            scriptErrorString = error.localizedDescription
            return nil
        }

        Task { @MainActor in
            NSDocumentController.shared.openDocument(withContentsOf: fileURL, display: true) { _, _, _ in }
        }
        return fileURL.path
    }
}

@objc(SwashQuickNoteCommand)
final class SwashQuickNoteCommand: NSScriptCommand {
    override func performDefaultImplementation() -> Any? {
        Task { @MainActor in
            QuickCaptureController.shared.show()
        }
        return nil
    }
}

@objc(SwashCountWordsCommand)
final class SwashCountWordsCommand: NSScriptCommand {
    override func performDefaultImplementation() -> Any? {
        let text = (directParameter as? String) ?? ""
        return SwashShortcutsEngine.calculateStatistics(for: text).summaryString
    }
}

@objc(SwashFormatMarkdownCommand)
final class SwashFormatMarkdownCommand: NSScriptCommand {
    override func performDefaultImplementation() -> Any? {
        let text = (directParameter as? String) ?? ""
        let rawStyle = ((evaluatedArguments?["style"] as? String) ?? "code block").lowercased()
        switch rawStyle {
        case "quote", "quote block", "quoteblock":
            return text.components(separatedBy: .newlines).map { "> \($0)" }.joined(separator: "\n")
        case "header", "heading":
            return "# \(text)"
        default:
            return "```\n\(text)\n```"
        }
    }
}

@objc(SwashAppendToNoteCommand)
final class SwashAppendToNoteCommand: NSScriptCommand {
    override func performDefaultImplementation() -> Any? {
        let entry = (directParameter as? String) ?? ""
        guard let pathOrTitle = (evaluatedArguments?["path"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !pathOrTitle.isEmpty else {
            scriptErrorNumber = NSRequiredArgumentsMissingScriptError
            scriptErrorString = SwashShortcutsError.noDocumentGiven.localizedDescription
            return nil
        }
        let heading = (evaluatedArguments?["heading"] as? String) ?? ""
        let rawStyle = ((evaluatedArguments?["style"] as? String) ?? "plain").lowercased()

        let style: SwashAppendStyle
        switch rawStyle {
        case "bullet", "list": style = .bullet
        case "todo", "to-do", "task": style = .todo
        case "timestamped bullet", "timestamp bullet": style = .timestampedBullet
        case "timestamped todo", "timestamped to-do", "timestamp todo": style = .timestampedTodo
        default: style = .plain
        }

        let position: SwashInsertPosition = heading.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? .end : .underHeading
        do {
            let (url, _) = try SwashShortcutsEngine.findOrCreateDocument(pathOrTitle: pathOrTitle)
            // One coordinated read-modify-write: a failed read throws instead of overwriting the
            // note with just this entry
            _ = try SwashShortcutsEngine.modifyText(at: url) { existing in
                SwashShortcutsEngine.insert(entry, into: existing, position: position, heading: heading, style: style)
            }
            return url.path
        } catch {
            scriptErrorNumber = NSInternalScriptError
            scriptErrorString = error.localizedDescription
            return nil
        }
    }
}

@objc(SwashGetNoteContentsCommand)
final class SwashGetNoteContentsCommand: NSScriptCommand {
    override func performDefaultImplementation() -> Any? {
        let pathOrTitle = (directParameter as? String) ?? ""
        let rawFormat = ((evaluatedArguments?["format"] as? String) ?? "markdown").lowercased()
        let format: SwashContentFormat
        switch rawFormat {
        case "plain", "plain text", "text": format = .plainText
        case "html": format = .html
        case "standalone html": format = .standaloneHTML
        default: format = .markdown
        }

        guard let url = SwashShortcutsEngine.resolveExistingDocument(pathOrTitle: pathOrTitle) else {
            scriptErrorNumber = NSInternalScriptError
            scriptErrorString = SwashShortcutsError.documentNotFound(pathOrTitle).localizedDescription
            return nil
        }
        do {
            let text = try SwashShortcutsEngine.readText(at: url)
            return SwashShortcutsEngine.convertMarkdown(text, to: format, title: url.deletingPathExtension().lastPathComponent)
        } catch {
            scriptErrorNumber = NSInternalScriptError
            scriptErrorString = error.localizedDescription
            return nil
        }
    }
}

@objc(SwashFindNotesCommand)
final class SwashFindNotesCommand: NSScriptCommand {
    override func performDefaultImplementation() -> Any? {
        let query = (directParameter as? String) ?? ""
        let folderPath = evaluatedArguments?["folder"] as? String
        let roots = folderPath.map { [URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath)] }
        let matches = SwashShortcutsEngine.findDocuments(query: query, scope: .nameAndContent, in: roots)
        return matches.map(\.url.path).joined(separator: "\n")
    }
}

@objc(SwashGetTodosCommand)
final class SwashGetTodosCommand: NSScriptCommand {
    override func performDefaultImplementation() -> Any? {
        let pathOrTitle = evaluatedArguments?["path"] as? String
        let rawStatus = ((evaluatedArguments?["status"] as? String) ?? "open").lowercased()
        let status: SwashTodoStatusFilter
        switch rawStatus {
        case "completed", "done", "checked": status = .completed
        case "all": status = .all
        default: status = .open
        }

        if let pathOrTitle, !pathOrTitle.isEmpty {
            let expanded = (pathOrTitle as NSString).expandingTildeInPath
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: expanded, isDirectory: &isDir), isDir.boolValue {
                let files = SwashShortcutsEngine.discoverFiles(in: [URL(fileURLWithPath: expanded)])
                return SwashShortcutsEngine.extractTodos(in: files, status: status).map(\.text).joined(separator: "\n")
            }
            if let url = SwashShortcutsEngine.resolveExistingDocument(pathOrTitle: pathOrTitle),
               let text = try? SwashShortcutsEngine.readText(at: url) {
                return SwashShortcutsEngine.extractTodos(from: text, status: status, file: url).map(\.text).joined(separator: "\n")
            }
        }
        let files = SwashShortcutsEngine.discoverFiles()
        return SwashShortcutsEngine.extractTodos(in: files, status: status).map(\.text).joined(separator: "\n")
    }
}

@objc(SwashConvertHTMLCommand)
final class SwashConvertHTMLCommand: NSScriptCommand {
    override func performDefaultImplementation() -> Any? {
        let html = (directParameter as? String) ?? ""
        let urlString = evaluatedArguments?["sourceURL"] as? String
        let sourceURL = urlString.flatMap { URL(string: $0) }
        return SwashShortcutsEngine.convertHTMLToMarkdown(html, sourceURL: sourceURL, includeSourceLink: sourceURL != nil)
    }
}
#endif

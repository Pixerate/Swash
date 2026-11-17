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
        let words = text.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.count
        let chars = text.count
        let lines = text.components(separatedBy: .newlines).count
        return "\(words) words, \(chars) characters, \(lines) lines"
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
#endif

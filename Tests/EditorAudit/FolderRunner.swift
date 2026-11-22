import Foundation
import SwiftUI
import AppKit

// Exercises folder windows: FolderWorkspace (scanning subfolders, search, links between notes,
// rename) and the editor hooks the window uses (relative and [[wiki]] link clicks, revealing a
// search result). Renders the real folder window to a PNG for a visual check. Moving to the
// Trash is not exercised here, so test runs don't fill the user's Trash.
// Run via ./Tests/EditorAudit/run_audit.sh folder.

func pump(_ s: Double = 0.2) { RunLoop.main.run(until: Date().addingTimeInterval(s)) }
func wait(_ timeout: Double = 3, until condition: () -> Bool) {
    let end = Date().addingTimeInterval(timeout)
    while !condition() && Date() < end { pump(0.05) }
}
func findTextView(in v: NSView) -> NSTextView? {
    if let tv = v as? NSTextView, tv.isEditable, tv.enclosingScrollView?.frame.width ?? 0 > 300 { return tv }
    for s in v.subviews { if let f = findTextView(in: s) { return f } }
    return nil
}
func snapshot(_ win: NSWindow, _ url: URL) {
    guard let v = win.contentView?.superview ?? win.contentView else { return }
    v.layoutSubtreeIfNeeded(); pump(0.1)
    guard let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { return }
    v.cacheDisplay(in: v.bounds, to: rep)
    try? rep.representation(using: .png, properties: [:])?.write(to: url)
}

var failures = 0
func check(_ name: String, _ ok: Bool, _ detail: @autoclosure () -> String = "") {
    let extra = ok ? "" : detail()
    print("\(ok ? "PASS" : "FAIL") \(name)\(extra.isEmpty ? "" : " — \(extra)")")
    if !ok { failures += 1 }
}

final class DocBox: ObservableObject { @Published var doc: SwashDocument; init(_ d: SwashDocument) { doc = d } }
var clicked: [URL] = []
struct EditorRoot: View {
    @ObservedObject var box: DocBox
    let file: URL
    let request: TextRevealRequest?
    var body: some View {
        ContentView(document: $box.doc, fileURL: file, documentID: file)
            .environment(\.noteLinkHandler, { url in clicked.append(url); return true })
            .environment(\.textRevealRequest, request)
    }
}

@main
enum FolderRunner {
    @MainActor
    static func main() {
        let outDir = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "build/editor-audit/folder-out").absoluteURL
        let root = outDir.appendingPathComponent("Notes").standardizedFileURL
        let fm = FileManager.default
        try? fm.removeItem(at: root)
        func write(_ path: String, _ text: String) {
            let url = root.appendingPathComponent(path)
            try! fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try! text.write(to: url, atomically: true, encoding: .utf8)
        }
        write("Welcome.md", "# Welcome\n\nSee the [plan](Projects/Plan.md) and [[Ideas]].\n\n`[[NotALink]]` stays code.\n")
        write("Ideas.md", "# Ideas\n\nA garden of thoughts.\n")
        write("Projects/Plan.md", "# Plan\n\nThe first milestone is a garden.\n\nBack to [welcome](../Welcome.md).\n")
        write("Projects/Archive/2025.md", "# 2025\n")
        write("node_modules/dep/README.md", "# Dependency\n")

        _ = NSApplication.shared
        NSApp.setActivationPolicy(.regular)

        // MARK: FolderWorkspace

        let workspace = FolderWorkspace(folderURL: root)
        workspace.open()
        wait { workspace.selectedFile != nil }
        check("the tree lists folders first", workspace.tree.map(\.displayName) == ["Projects", "Ideas", "Welcome"], "\(workspace.tree.map(\.displayName))")
        check("subfolders are scanned", workspace.files.contains { $0.lastPathComponent == "2025.md" })
        check("node_modules is skipped", !workspace.files.contains { $0.path.contains("node_modules") })
        check("a top-level file opens first", workspace.selectedFile?.lastPathComponent == "Ideas.md", workspace.selectedFile?.lastPathComponent ?? "-")

        let welcome = root.appendingPathComponent("Welcome.md")
        let plan = root.appendingPathComponent("Projects/Plan.md")
        workspace.select(welcome)
        check("a relative link opens the note", workspace.openLink(URL(string: "Projects/Plan.md")!) && workspace.selectedFile == plan)
        check("a parent-folder link opens the note", workspace.openLink(URL(string: "../Welcome.md")!) && workspace.selectedFile == welcome)
        check("web links are left to the system", !workspace.openLink(URL(string: "https://example.com")!))
        check("a wiki link opens the note", workspace.openLink(URL(string: "\(wikiLinkScheme):Ideas")!) && workspace.selectedFile?.lastPathComponent == "Ideas.md")
        workspace.select(welcome)

        workspace.search("garden")
        wait { !workspace.isSearching }
        check("search finds matches in subfolders", Set(workspace.searchResults.map(\.file.lastPathComponent)) == ["Ideas.md", "Plan.md"],
              "\(workspace.searchResults.map(\.file.lastPathComponent))")
        workspace.document.text += "\nA garden here too.\n"
        workspace.search("garden", debounce: false)
        wait { !workspace.isSearching }
        check("search sees unsaved edits to the open note", workspace.searchResults.contains { $0.file == welcome })
        workspace.save()

        if let match = workspace.searchResults.first(where: { $0.file == plan }) {
            workspace.select(match.file, revealing: match.range)
            check("choosing a result opens the file with a reveal request",
                  workspace.selectedFile == plan && workspace.revealRequest?.range == match.range)
        }

        let renamed = workspace.rename(plan, to: "Roadmap")
        check("rename keeps the extension and follows the open file",
              renamed?.lastPathComponent == "Roadmap.md" && workspace.selectedFile == renamed && fm.fileExists(atPath: renamed?.path ?? ""))
        wait { workspace.files.contains { $0.lastPathComponent == "Roadmap.md" } }
        check("the tree updates after a rename", !workspace.files.contains(plan))
        let movedFolder = workspace.rename(root.appendingPathComponent("Projects"), to: "Work")
        check("renaming a folder follows the open file inside it",
              movedFolder != nil && workspace.selectedFile == root.appendingPathComponent("Work/Roadmap.md").standardizedFileURL,
              workspace.selectedFile?.path ?? "-")
        check("rename refuses an existing name", workspace.rename(welcome, to: "Ideas") == nil && workspace.errorMessage != nil)
        workspace.errorMessage = nil
        _ = workspace.rename(root.appendingPathComponent("Work"), to: "Projects")
        _ = workspace.rename(root.appendingPathComponent("Projects/Roadmap.md"), to: "Plan")

        // Switching files or renaming aborts and keeps the current file open when saving fails
        let editedText = "# Important Ideas\nUnsaved content that should not be dropped.\n"
        let ideas = root.appendingPathComponent("Ideas.md")
        workspace.select(ideas)
        workspace.document.text = editedText
        try! fm.setAttributes([.immutable: true], ofItemAtPath: ideas.path)
        let selectFailed = !workspace.select(welcome)
        check("switching files aborts when save fails", selectFailed && workspace.selectedFile == ideas && workspace.document.text == editedText,
              "selected: \(workspace.selectedFile?.lastPathComponent ?? "nil"), text: \(workspace.document.text)")
        check("save failure reports an error message", workspace.errorMessage != nil && workspace.errorMessage!.contains("Ideas.md"),
              workspace.errorMessage ?? "nil")
        let linkHandled = workspace.openLink(URL(string: "Projects/Plan.md")!)
        check("openLink handles link but aborts switch on save failure", linkHandled && workspace.selectedFile == ideas && workspace.document.text == editedText)
        let renameFailed = workspace.rename(ideas, to: "Thoughts") == nil
        check("rename aborts when save fails", renameFailed && workspace.selectedFile == ideas && workspace.document.text == editedText)
        try! fm.setAttributes([.immutable: false], ofItemAtPath: ideas.path)
        workspace.errorMessage = nil
        check("save succeeds once permissions are restored", workspace.save() && !workspace.hasUnsavedChanges)
        check("selecting next file succeeds after successful save", workspace.select(welcome) && workspace.selectedFile == welcome)

        write("Added.md", "# Added elsewhere\n")
        wait(4) { workspace.files.contains { $0.lastPathComponent == "Added.md" } }
        check("files added by other apps appear", workspace.files.contains { $0.lastPathComponent == "Added.md" })

        // Conflict detection and resolution
        workspace.select(welcome)
        let initialWelcomeText = workspace.document.text
        workspace.document.text = "# Welcome\n\nLocal unsaved edit.\n"
        let externalText1 = "# Welcome\n\nExternal app edit.\n"
        try! externalText1.write(to: welcome, atomically: true, encoding: .utf8)
        workspace.save()
        check("conflict detected when disk changed while unsaved edits existed", workspace.activeConflict != nil)
        check("conflict preserves external text on disk", (try? String(contentsOf: welcome, encoding: .utf8)) == externalText1)
        check("conflict holds correct file URL", workspace.activeConflict?.file == welcome)
        check("conflict holds external disk text", workspace.activeConflict?.diskText == externalText1)
        check("conflict holds local unsaved text", workspace.activeConflict?.localText == "# Welcome\n\nLocal unsaved edit.\n")

        // Test navigation safety: navigating away with active conflict must abort
        workspace.select(plan)
        check("navigating away with a conflict aborts selection change", workspace.selectedFile == welcome && workspace.activeConflict != nil)

        // Resolve keeping theirs
        workspace.resolveConflict(keeping: .theirs)
        check("resolve with .theirs updates document text to external version", workspace.document.text == externalText1)
        check("resolve with .theirs clears active conflict", workspace.activeConflict == nil)
        check("resolve with .theirs clears unsaved changes", !workspace.hasUnsavedChanges)

        // Resolve keeping mine
        workspace.document.text = "# Welcome\n\nMine wins.\n"
        let externalText2 = "# Welcome\n\nAnother external write.\n"
        try! externalText2.write(to: welcome, atomically: true, encoding: .utf8)
        workspace.save()
        check("conflict detected on second external change", workspace.activeConflict != nil)
        workspace.resolveConflict(keeping: .mine)
        check("resolve with .mine clears active conflict", workspace.activeConflict == nil)
        check("resolve with .mine overwrites disk with local text", (try? String(contentsOf: welcome, encoding: .utf8)) == "# Welcome\n\nMine wins.\n")
        check("resolve with .mine clears unsaved changes", !workspace.hasUnsavedChanges)

        // Resolve keeping copy
        workspace.document.text = "# Welcome\n\nCopy this.\n"
        let externalText3 = "# Welcome\n\nThird external write.\n"
        try! externalText3.write(to: welcome, atomically: true, encoding: .utf8)
        workspace.save()
        check("conflict detected on third external change", workspace.activeConflict != nil)
        let copyURL = workspace.conflictCopyURL(for: welcome)
        check("conflictCopyURL computes non-colliding name", copyURL.lastPathComponent == "Welcome (Conflict).md")
        workspace.resolveConflict(keeping: .copy)
        check("resolve with .copy clears active conflict", workspace.activeConflict == nil)
        check("resolve with .copy leaves original file with external edits", (try? String(contentsOf: welcome, encoding: .utf8)) == externalText3)
        check("resolve with .copy writes copy file with local edits", (try? String(contentsOf: copyURL, encoding: .utf8)) == "# Welcome\n\nCopy this.\n")
        check("resolve with .copy switches selection to the new copy file", workspace.selectedFile == copyURL)
        check("selected copy file has local edits as document text", workspace.document.text == "# Welcome\n\nCopy this.\n")

        // Dismissing conflict
        workspace.document.text = "# Welcome (Conflict)\n\nUnsaved in copy.\n"
        let externalText4 = "# Welcome (Conflict)\n\nExternal in copy.\n"
        try! externalText4.write(to: copyURL, atomically: true, encoding: .utf8)
        workspace.save()
        check("conflict detected in copy file", workspace.activeConflict != nil)
        workspace.dismissConflict()
        check("dismissConflict clears activeConflict", workspace.activeConflict == nil)
        check("dismissConflict leaves local edits dirty in memory", workspace.hasUnsavedChanges)
        check("dismissConflict preserves disk content", (try? String(contentsOf: copyURL, encoding: .utf8)) == externalText4)
        check("autosave doesn't ask again after Cancel", !workspace.save(prompting: false) && workspace.activeConflict == nil)
        check("an explicit save asks again after Cancel", !workspace.save() && workspace.activeConflict != nil)
        workspace.resolveConflict(keeping: .theirs)

        // Closing with an unresolved conflict keeps the edits in a conflict copy
        workspace.document.text = "# Welcome (Conflict)\n\nEdits at close.\n"
        let externalText5 = "# Welcome (Conflict)\n\nExternal at close.\n"
        try! externalText5.write(to: copyURL, atomically: true, encoding: .utf8)
        let closeCopyURL = workspace.conflictCopyURL(for: copyURL)
        workspace.saveBeforeClosing()
        check("closing with a conflict keeps the other app's change", (try? String(contentsOf: copyURL, encoding: .utf8)) == externalText5)
        check("closing with a conflict writes the edits to a copy", (try? String(contentsOf: closeCopyURL, encoding: .utf8)) == "# Welcome (Conflict)\n\nEdits at close.\n")
        check("closing with a conflict leaves nothing unsaved", !workspace.hasUnsavedChanges && workspace.activeConflict == nil)

        // Restore welcome for subsequent tests
        try! initialWelcomeText.write(to: welcome, atomically: true, encoding: .utf8)
        workspace.select(welcome)
        try? fm.removeItem(at: closeCopyURL)
        try? fm.removeItem(at: copyURL)
        wait(4) { !workspace.files.contains(copyURL) }

        // External rename follows the open file
        let addedURL = root.appendingPathComponent("Added.md")
        workspace.select(addedURL)
        wait { workspace.selectedFile == addedURL }
        let externallyRenamedURL = root.appendingPathComponent("ExternalRename.md")
        try! fm.moveItem(at: addedURL, to: externallyRenamedURL)
        wait(4) { workspace.selectedFile == externallyRenamedURL }
        check("external rename follows the open file", workspace.selectedFile == externallyRenamedURL)
        check("external rename updates file list", workspace.files.contains(externallyRenamedURL) && !workspace.files.contains(addedURL))

        // External removal with unsaved edits preserves edits and recreates file
        workspace.document.text = "# Preserved Edits\nThis text was saved back.\n"
        check("has unsaved changes before removal", workspace.hasUnsavedChanges)
        try! fm.removeItem(at: externallyRenamedURL)
        wait(4) { fm.fileExists(atPath: externallyRenamedURL.path) }
        check("external removal with unsaved edits recreates file on disk", fm.fileExists(atPath: externallyRenamedURL.path))
        check("recreated file has the unsaved edits", (try? String(contentsOf: externallyRenamedURL, encoding: .utf8)) == "# Preserved Edits\nThis text was saved back.\n")
        check("selection is kept when recreating file", workspace.selectedFile == externallyRenamedURL)
        check("document text in memory is preserved", workspace.document.text == "# Preserved Edits\nThis text was saved back.\n")

        // Wait for the recreated file to be rescanned into workspace.files
        wait(4) { workspace.files.contains(externallyRenamedURL) }
        check("recreated file appears in file list", workspace.files.contains(externallyRenamedURL))

        // External removal without unsaved edits cleanly clears selection and transitions to another file
        try! fm.removeItem(at: externallyRenamedURL)
        wait(4) { workspace.selectedFile != externallyRenamedURL }
        check("external removal without unsaved edits transitions selection", workspace.selectedFile != nil && workspace.selectedFile != externallyRenamedURL)

        // Restore Added.md so subsequent sidebar test finds 3 top-level notes + Projects folder
        write("Added.md", "# Added elsewhere\n")
        wait(4) { workspace.files.contains { $0.lastPathComponent == "Added.md" } }

        workspace.close()

        // MARK: Editor hooks


        let welcomeText = try! String(contentsOf: welcome, encoding: .utf8)
        let gardenRange = (welcomeText as NSString).range(of: "garden")
        let request = TextRevealRequest(fileURL: welcome, range: gardenRange)
        let box = DocBox(SwashDocument(text: welcomeText))
        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 700), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        win.contentView = NSHostingView(rootView: EditorRoot(box: box, file: welcome, request: request))
        win.makeKeyAndOrderFront(nil)
        pump(1.0)
        if let tv = findTextView(in: win.contentView!), let storage = tv.textStorage {
            check("the reveal request selects the match", tv.selectedRange().length == gardenRange.length && request.isHandled,
                  "\(tv.selectedRange())")
            let display = storage.string as NSString
            let wikiLocation = display.range(of: "Ideas]]").location
            let wikiLink = wikiLocation == NSNotFound ? nil : storage.attribute(.link, at: wikiLocation, effectiveRange: nil) as? URL
            check("[[wiki]] links are marked as links", wikiLink?.absoluteString == "\(wikiLinkScheme):Ideas", "\(String(describing: wikiLink))")
            let codeLocation = display.range(of: "NotALink").location
            check("[[wiki]] links in code are not links",
                  codeLocation != NSNotFound && storage.attribute(.link, at: codeLocation, effectiveRange: nil) == nil)
            let planLocation = display.range(of: "plan").location
            if planLocation != NSNotFound, let link = storage.attribute(.link, at: planLocation, effectiveRange: nil) {
                _ = tv.delegate?.textView?(tv, clickedOnLink: link, at: planLocation)
                check("clicking a relative link goes to the folder window", clicked.last?.relativeString == "Projects/Plan.md",
                      "\(clicked.map(\.absoluteString))")
            } else {
                check("the relative link is a link", false)
            }
        } else {
            check("the editor is hosted", false)
        }
        win.orderOut(nil)

        // MARK: The folder window

        let folderWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1040, height: 700), styleMask: [.titled, .resizable, .closable, .miniaturizable, .fullSizeContentView], backing: .buffered, defer: false)
        folderWindow.contentView = NSHostingView(rootView: FolderWindowView(folderURL: root))
        folderWindow.makeKeyAndOrderFront(nil)
        pump(1.5)
        func findTable(in v: NSView) -> NSTableView? {
            if let t = v as? NSTableView { return t }
            for s in v.subviews { if let f = findTable(in: s) { return f } }
            return nil
        }
        // Top-level rows: the Projects folder (collapsed) and the three top-level notes
        let rows = folderWindow.contentView.flatMap(findTable(in:))?.numberOfRows ?? 0
        check("the sidebar lists the tree", rows >= 4, "\(rows) rows")
        try? fm.createDirectory(at: outDir, withIntermediateDirectories: true)
        snapshot(folderWindow, outDir.appendingPathComponent("folder-window.png"))
        print("Folder window snapshot: \(outDir.appendingPathComponent("folder-window.png").path)")
        folderWindow.orderOut(nil)

        try? fm.removeItem(at: root)
        print(failures == 0 ? "FOLDER: all checks passed" : "FOLDER: \(failures) failure(s)")
        exit(failures == 0 ? 0 : 1)

    }
}

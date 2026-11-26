//
//  SwashApp.swift
//  Swash
//
//  Created by Jack James on 13/07/2026.
//

#if os(macOS)
import SwiftUI
import MacAppKitExtras
import AppKit

class AppDelegate: NSObject, NSApplicationDelegate {
    let servicesProvider = ServicesProvider()
    
    func applicationDidFinishLaunching(_ notification: Notification) {
        WritingPartnerDefaults.migrateExistingInstall()
        NSApp.servicesProvider = servicesProvider
        // `-appearance light|dark` on the command line fixes the app's appearance for one launch
        // (the screenshot scripts; GOTCHAS #40). `-AppleInterfaceStyle Dark` stopped working in macOS 27.
        if let name = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)["appearance"] as? String {
            NSApp.appearance = NSAppearance(named: name == "dark" ? .darkAqua : .aqua)
        }
        GlobalHotKey.shared.register(QuickCaptureShortcut.current)
        PixerateAccess.startAtLaunch()
        PixerateAccess.shared.isFeatureEnabled = {
            WritingPartnerDefaults.mode() != .off || WritingPartnerDefaults.quickNoteTidy()
        }
        WritingBandleaderFactory.installPixerateBandleader()
        WritingBandleaderFactory.installOnDeviceBandleader()
        MarkdownTitleSuggestion.installMacDraftNameHook()
        AgentBridge.shared.startIfEnabled()
        DispatchQueue.main.async {
            DefaultAppManager.shared.checkAndPromptIfNecessary()
        }
    }
    
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            if url.scheme == "swash" {
                handleSwashURL(url)
            } else {
                DocumentOpener.shared.open([url])
            }
        }
    }
    
    func application(_ sender: NSApplication, openFiles filenames: [String]) {
        DocumentOpener.shared.open(filenames.map { URL(fileURLWithPath: $0) })
        sender.reply(toOpenOrPrint: .success)
    }
    
    func application(_ sender: NSApplication, openFile filename: String) -> Bool {
        DocumentOpener.shared.open([URL(fileURLWithPath: filename)])
        return true
    }
    
    private func handleSwashURL(_ url: URL) {
        guard url.scheme == "swash" else { return }
        
        if url.host == "new" {
            let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
            let text = components?.queryItems?.first(where: { $0.name == "text" })?.value ?? ""
            let givenTitle = components?.queryItems?.first(where: { $0.name == "title" })?.value?.trimmingCharacters(in: .whitespacesAndNewlines)
            let title: String
            if let givenTitle, !givenTitle.isEmpty, givenTitle != "Untitled", givenTitle != "Shared Note" {
                title = givenTitle
            } else {
                title = MarkdownTitleSuggestion.suggest(from: text) ?? "Untitled"
            }
            
            let tempDir = FileManager.default.temporaryDirectory
            let fileName = "\(MarkdownTitleSuggestion.cleanFileName(title)).md"
            let fileURL = tempDir.appendingPathComponent(fileName)
            
            do {
                try text.write(to: fileURL, atomically: true, encoding: .utf8)
                NSDocumentController.shared.openDocument(withContentsOf: fileURL, display: true) { _, _, _ in }
            } catch {
                print("Failed to handle swash://new: \(error)")
            }
        } else if url.host == "open" {
            let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
            if let path = components?.queryItems?.first(where: { $0.name == "path" })?.value {
                DocumentOpener.shared.open([URL(fileURLWithPath: path)])
            }
        }
    }
}

@main
struct SwashApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    #if !APP_STORE
    @StateObject private var sparkleUpdater = SparkleUpdater.shared
    #endif
    @AppStorage("showMenuBarExtra") private var showMenuBarExtra = false

    init() {
        // Pixie's chat in document windows (View › Show Pixie).
        ContentView.pixieInspector = { session, name, close in
            PixieSwashInspector.make(session: session, documentName: name, onClose: close)
        }
    }
    
    var body: some Scene {
        DocumentGroup(newDocument: SwashDocument()) { file in
            ContentView(document: file.$document, fileURL: file.fileURL, isEditable: file.isEditable)
        }
        .windowToolbarStyle(.unified)
        .defaultSize(width: 800, height: 750)
        .handlesExternalEvents(matching: ["*"])
        .commands {
            #if !APP_STORE
            CommandGroup(after: .appInfo) {
                Button("Check for Updates...") {
                    sparkleUpdater.checkForUpdates()
                }
                .disabled(!sparkleUpdater.canCheckForUpdates)
            }
            #endif
            FormatMenuCommands()
            DocumentMenuCommands()
            FileMenuCommands()
            ExportCommands()
            WritingModeCommands()
            TypographyCommands()
            OpenFolderCommands()
            CommandGroup(after: .saveItem) {
                Button("Grant Folder Access…") {
                    if let keyWindow = NSApp.keyWindow {
                        let docURL = keyWindow.representedURL ?? NSDocumentController.shared.document(for: keyWindow)?.fileURL
                        if let docURL = docURL {
                            let folderURL = docURL.hasDirectoryPath ? docURL : docURL.deletingLastPathComponent()
                            FolderAccessManager.shared.promptForAccess(to: folderURL, window: keyWindow) { _ in }
                        }
                    }
                }
            }
        }
        
        WindowGroup("Folder", id: FolderWindowView.windowID, for: URL.self) { $folderURL in
            if let folderURL {
                FolderWindowView(folderURL: folderURL)
            }
        }
        .windowToolbarStyle(.unified)
        .defaultSize(width: 1040, height: 750)
        // Folder windows open only through File › Open Folder…, not File › New
        .commandsRemoved()

        Settings {
            SettingsView()
        }
        
        MenuBarExtra("Swash", systemImage: "square.and.pencil", isInserted: $showMenuBarExtra) {
            SwashMenuBarMenu()
        }
    }
}
#endif

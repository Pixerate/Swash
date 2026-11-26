//
//  IOSContentView.swift
//  Swash
//
//  The document screen on iPhone and iPad. It offers the same modes as the Mac window:
//  Source, Formatted, and Split side by side when the width is regular (iPad).
//

#if os(iOS)
import SwiftUI
import MacAppKitExtras
import UIKit
import PixerateMarkdown

struct IOSContentView: View {
    @Binding var document: SwashDocument
    let fileURL: URL?

    @SceneStorage("viewMode") private var viewMode: ViewMode = .preview
    /// Whether the iPad split view shows the outline sidebar; the system sidebar button sets it.
    @SceneStorage("outlineColumnVisible") private var outlineVisible = false
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.scenePhase) private var scenePhase
    @State private var editor = IOSEditorController()
    @State private var scrollSync = ScrollSync()
    @State private var showingSettings = false
    @State private var distractionFree = false
    @AppStorage(WritingDefaults.focusMode) private var focusMode = false
    @AppStorage(WritingDefaults.focusUnit) private var focusUnit: FocusUnit = .paragraph
    @AppStorage(WritingDefaults.typewriterScrolling) private var typewriterScrolling = false
    @State private var partnerPaused = false
    @State private var conflictCount = 0
    @State private var showingConflictSheet = false
    @State private var conflictError: String?
    /// Where "Rename to …" moved the file, until DocumentGroup reports the new `fileURL` itself.
    @State private var renamedFileURL: URL?
    @State private var renameError: String?
    @State private var linkPrompt: LinkPrompt?
    @State private var dismissedFolderBanner: URL?
    /// Global y of the top safe-area edge and of the editor, which extends under the bar.
    @State private var safeAreaTop: CGFloat = 0
    @State private var editorTop: CGFloat = 0
    @ObservedObject private var folderAccessManager = FolderAccessManager.shared
    private var typography = IOSTypographySettings()
    @State private var features = IOSDocumentFeaturesModel()

    // Explicit, because `typography` is a private stored property, which would
    // otherwise make the memberwise initializer private.
    init(document: Binding<SwashDocument>, fileURL: URL?) {
        _document = document
        self.fileURL = fileURL
    }

    /// Split needs room for two columns; in compact width it falls back to Source.
    private var effectiveMode: ViewMode {
        viewMode == .split && horizontalSizeClass == .compact ? .edit : viewMode
    }

    private var availableModes: [ViewMode] {
        horizontalSizeClass == .compact ? [.edit, .preview] : ViewMode.allCases
    }

    private var unreadableFolderURL: URL? {
        guard let folder = MarkdownParser.unreadableRelativeFolder(in: document.text, baseURL: fileURL),
              folder != dismissedFolderBanner else { return nil }
        return folder
    }

    var body: some View {
        documentLayout
        .toolbarTitleMenu {
            if let suggestion = titleSuggestion, canRenameToSuggestion {
                Button {
                    renameDocument(to: suggestion)
                } label: {
                    Label("Rename to “\(suggestion)”", systemImage: "pencil")
                }
            }
        }
        .modifier(IOSDocumentFeatures(model: features, text: document.text, editor: editor))
        .sheet(isPresented: $showingSettings) {
            IOSSettingsView()
        }
        .sheet(isPresented: $showingConflictSheet) {
            if let url = fileURL {
                ConflictResolutionSheet(url: url, onKeep: { version in
                    showingConflictSheet = false
                    resolveConflicts(keeping: version, at: url)
                }, onCancel: { showingConflictSheet = false })
            }
        }
        .alert("Couldn’t Rename", isPresented: Binding(
            get: { renameError != nil },
            set: { if !$0 { renameError = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(renameError ?? "")
        }
        .onChange(of: fileURL) { _, _ in renamedFileURL = nil }
        .alert("Couldn’t Resolve Conflict", isPresented: Binding(
            get: { conflictError != nil },
            set: { if !$0 { conflictError = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(conflictError ?? "")
        }
        .alert(linkPrompt?.isEditing == true ? "Edit Link" : "Add Link", isPresented: Binding(
            get: { linkPrompt != nil },
            set: { if !$0 { linkPrompt = nil } }
        ), presenting: linkPrompt) { prompt in
            TextField("https://example.com", text: Binding(
                get: { linkPrompt?.url ?? "" },
                set: { linkPrompt?.url = $0 }
            ))
            .textInputAutocapitalization(.never)
            .keyboardType(.URL)
            .autocorrectionDisabled()
            Button(prompt.isEditing ? "Update" : "Add") { applyLink(linkPrompt?.url ?? "", selection: prompt.selection) }
            if prompt.isEditing {
                Button("Remove Link", role: .destructive) { applyLink(nil, selection: prompt.selection) }
            }
            Button("Cancel", role: .cancel) {}
        }
        .focusedSceneValue(\.formatCommandHandler, { handleFormatCommand($0) })
        .focusedSceneValue(\.distractionFreeToggle, DistractionFreeToggle(isOn: distractionFree, toggle: {
            withAnimation(.easeInOut(duration: 0.2)) {
                distractionFree.toggle()
            }
        }))
        .onChange(of: partnerPaused) { _, paused in
            editor.setPartnerPaused(paused)
        }
        .onAppear {
            editor.onPartnerPauseChange = { partnerPaused = $0 }
            editor.onFormatCommand = { handleFormatCommand($0) }
            editor.flavor = document.flavor
            refreshConflicts()
        }
        .onChange(of: document.flavor) { _, flavor in
            editor.flavor = flavor
        }
        .onChange(of: fileURL) { _, _ in
            refreshConflicts()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                WritingPartnerActiveVoice.shared.documentFlavor = document.flavor
                refreshConflicts()
            }
        }
    }

    /// At regular width (iPad) the outline is the sidebar of a system split view, with the
    /// system's sidebar button; in compact width it's a sheet from the toolbar's Outline button.
    @ViewBuilder
    private var documentLayout: some View {
        if horizontalSizeClass == .regular {
            NavigationSplitView(columnVisibility: Binding(
                get: { outlineVisible && !distractionFree && !focusMode ? .all : .detailOnly },
                set: { if !distractionFree && !focusMode { outlineVisible = $0 != .detailOnly } }
            )) {
                IOSOutlineSidebar(model: features, text: document.text, editor: editor,
                                  isVisible: outlineVisible && !distractionFree && !focusMode, fileURL: fileURL,
                                  flavor: flavorBinding,
                                  showInfo: { features.showInfo(text: document.text, editor: editor) },
                                  showSettings: { showingSettings = true })
            } detail: {
                documentScreen
            }
            // DocumentGroup's own bar would sit above the columns' bars; the detail column's
            // bar already carries the document's back button and title menu
            .background(DocumentBarHider())
            .animation(.easeInOut(duration: 0.2), value: focusMode)
        } else {
            documentScreen
                .animation(.easeInOut(duration: 0.2), value: focusMode)
        }
    }

    /// The editor with its toolbar; the detail column on iPad.
    private var documentScreen: some View {
        // The editors fill the window, so text scrolls under the navigation bar and gets its
        // scroll-edge effect; the banner joins that bar instead of pushing the editor down
        ZStack {
            // Where the safe area (bar and banner) ends; the editor below starts at the window top
            Color.clear
                .onGeometryChange(for: CGFloat.self) { $0.frame(in: .global).minY } action: { safeAreaTop = $0 }
            content(topInset: max(0, safeAreaTop - editorTop))
                .onGeometryChange(for: CGFloat.self) { $0.frame(in: .global).minY } action: { editorTop = $0 }
                .ignoresSafeArea(.container, edges: [.top, .bottom])
        }
        .overlay(alignment: .topTrailing) {
            if distractionFree {
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        distractionFree = false
                    }
                } label: {
                    Image(systemName: "arrow.down.right.and.arrow.up.left")
                        .font(.system(size: 15, weight: .medium))
                        .frame(width: 36, height: 36)
                }
                .buttonStyle(.glass)
                .accessibilityLabel("Exit Distraction-Free Writing")
                .accessibilityIdentifier("ExitDistractionFreeButton")
                .padding(.trailing, 16)
                .padding(.top, 8)
            } else if focusMode {
                focusControl
                    .padding(.trailing, 16)
                    .padding(.top, 8)
            }
        }
        .safeAreaBar(edge: .top) {
            // Conflict and folder-access banners stay visible in Focus Mode: they guard the file
            if !distractionFree {
                if conflictCount > 0 {
                    ConflictBanner(count: conflictCount) { showingConflictSheet = true }
                }
                if let folderURL = unreadableFolderURL {
                    folderAccessBanner(for: folderURL)
                }
            }
        }
        .toolbar { toolbar }
        .toolbar(distractionFree || focusMode ? .hidden : .visible, for: .navigationBar)
        .toolbarRole(.editor)
        .background(DocumentShareBridge(source: exportSource, model: features))
    }

    private var focusControl: some View {
        Menu {
            Toggle("Focus Mode", systemImage: "viewfinder", isOn: Binding(
                get: { focusMode },
                set: { newValue in
                    withAnimation(.easeInOut(duration: 0.2)) {
                        focusMode = newValue
                    }
                }
            ))
            Picker("Focus On", selection: $focusUnit) {
                ForEach(FocusUnit.allCases) { unit in
                    Text(unit.title).tag(unit)
                }
            }
            Toggle("Typewriter Scrolling", systemImage: "arrow.up.and.down.text.horizontal", isOn: $typewriterScrolling)
            Divider()
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    focusMode = false
                }
            } label: {
                Label("Turn Focus Off", systemImage: "viewfinder.slash")
            }
        } label: {
            Image(systemName: "viewfinder")
                .font(.system(size: 15, weight: .medium))
                .frame(width: 36, height: 36)
        }
        .buttonStyle(.glass)
        .accessibilityLabel("Focus Options")
        .accessibilityIdentifier("FocusOptionsButton")
    }

    /// The editors ignore the top safe area so text scrolls under the bar; `topInset` is the
    /// bar's (and banner's) height, which they apply as a content inset.
    @ViewBuilder
    private func content(topInset: CGFloat) -> some View {
        switch effectiveMode {
        case .edit:
            sourceEditor(topInset: topInset)
        case .preview:
            // Edit Text for every flavour: Slack mrkdwn is parsed onto the same model (SlackMarkdown)
            StyledTextView(text: $document.text, controller: editor, flavor: document.flavor, baseURL: fileURL,
                           formattingEnabled: !distractionFree, topInset: topInset,
                           writingOptions: typography.writingOptions(distractionFree: distractionFree),
                           typography: typography.scaled,
                           showEmptyLineInsertAffordance: typography.showEmptyLineInsertAffordance)
                .id(folderAccessManager.accessGrantedTrigger)
        case .split:
            HStack(spacing: 0) {
                sourceEditor(topInset: topInset)
                Divider()
                preview(topInset: topInset)
            }
        }
    }

    private func sourceEditor(topInset: CGFloat) -> some View {
        SourceTextView(
            text: $document.text,
            controller: editor,
            scrollSync: effectiveMode == .split ? scrollSync : nil,
            formattingEnabled: !distractionFree,
            topInset: topInset,
            flavor: document.flavor,
            baseURL: fileURL,
            textSize: typography.stored.textSize
        )
    }

    private func preview(topInset: CGFloat) -> some View {
        MarkdownPreviewView(
            text: document.text,
            flavor: document.flavor,
            baseURL: fileURL,
            scrollSync: effectiveMode == .split ? scrollSync : nil,
            topInset: topInset,
            typography: typography.scaled
        )
        .environment(\.openURL, OpenURLAction { url in
            openRelativeNoteIfPossible(url) ? .handled : .systemAction
        })
        .id(folderAccessManager.accessGrantedTrigger)
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        // Focus Mode keeps only the Writing menu (its focus options) in the toolbar
        if !focusMode {
            // In the centre group on iPad; on iPhone the overflow would hide its one-tap switch
            ToolbarItem(placement: horizontalSizeClass == .regular ? .secondaryAction : .primaryAction) {
                // A glyph button, not a segmented control: iOS 26 toolbars squeeze segmented
                // controls into one glass circle. Tap switches Source and Formatted; hold for every mode.
                Menu {
                    Picker("View Mode", selection: $viewMode) {
                        ForEach(availableModes) { mode in
                            Label(mode.rawValue, systemImage: mode.icon).tag(mode)
                        }
                    }
                    .pickerStyle(.inline)
                } label: {
                    Label("View Mode: \(effectiveMode.rawValue)", systemImage: effectiveMode.icon)
                } primaryAction: {
                    viewMode = effectiveMode == .preview ? .edit : .preview
                }
                .accessibilityLabel("View Mode")
                .accessibilityValue(effectiveMode.rawValue)
                .accessibilityHint("Switches between Source and Formatted. Touch and hold for more modes.")
            }
        }
        IOSDocumentToolbar(model: features, text: document.text, source: { exportSource },
                           editor: editor, regularWidth: horizontalSizeClass == .regular,
                           distractionFree: $distractionFree, partnerPaused: $partnerPaused)
        if horizontalSizeClass != .regular && !focusMode {
            // iPad shares from the title menu; on iPhone that menu is a tap further away
            ToolbarSpacer(.fixed, placement: .primaryAction)
            ToolbarItem(placement: .primaryAction) {
                shareLink
            }
            ToolbarItem(placement: .secondaryAction) {
                // A submenu, so the editor toolbar on iPad shows an icon, not the bare flavour name
                Menu {
                    Picker("Markdown Flavor", selection: flavorBinding) {
                        ForEach(MarkdownFlavor.allCases) { flavor in
                            Text(flavor.rawValue).tag(flavor)
                        }
                    }
                    .pickerStyle(.inline)
                } label: {
                    Label("Markdown Flavor", systemImage: "textformat")
                }
            }
            ToolbarItem(placement: .secondaryAction) {
                Button {
                    showingSettings = true
                } label: {
                    Label("Settings", systemImage: "gearshape")
                }
            }
        }
    }

    /// Shares the document through the system share sheet (`IOSPresenter.shareDocument`),
    /// providing multiple representations (formatted text for Notes, plain text for Messages,
    /// Mail and Notion, the `.md` file for AirDrop and Save to Files, and a print formatter for
    /// Print) along with custom actions for Export as PDF, Export as HTML, Copy as Rich Text,
    /// and Copy HTML (GOTCHAS #55, #183).
    @ViewBuilder
    private var shareLink: some View {
        Button {
            presentShareSheet()
        } label: {
            Label("Share", systemImage: "square.and.arrow.up")
        }
        .disabled(features.exporting != nil)
    }

    private func presentShareSheet() {
        IOSPresenter.shareDocument(source: exportSource, model: features)
    }

    /// Changing flavour converts the text in place, as on the Mac.
    private var flavorBinding: Binding<MarkdownFlavor> {
        Binding(
            get: { document.flavor },
            set: { newFlavor in
                guard newFlavor != document.flavor else { return }
                var updated = document
                updated.text = MarkdownParser.convert(document.text, from: document.flavor, to: newFlavor)
                updated.flavor = newFlavor
                document = updated
            }
        )
    }

    private var exportSource: DocumentExporter.Source {
        DocumentExporter.Source(text: document.text, flavor: document.flavor, fileURL: fileURL, title: documentTitle)
    }

    /// The document's current location, including a rename made from the title menu.
    private var currentFileURL: URL? { renamedFileURL ?? fileURL }

    private var documentTitle: String {
        if let name = currentFileURL?.deletingPathExtension().lastPathComponent, !name.isEmpty {
            return name
        }
        return "Untitled"
    }

    private var titleSuggestion: String? {
        MarkdownTitleSuggestion.suggest(from: document.text)
    }

    private var canRenameToSuggestion: Bool {
        guard let suggestion = titleSuggestion, !suggestion.isEmpty else { return false }
        return documentTitle != suggestion
    }

    private func renameDocument(to newTitle: String) {
        guard let sourceURL = currentFileURL else { return }
        let ext = sourceURL.pathExtension.isEmpty ? "md" : sourceURL.pathExtension
        let sanitized = IOSDocumentFeaturesModel.fileName(newTitle)
        let parentFolder = sourceURL.deletingLastPathComponent()
        var destinationURL = parentFolder.appendingPathComponent(sanitized).appendingPathExtension(ext)
        if destinationURL.standardizedFileURL == sourceURL.standardizedFileURL { return }

        var counter = 2
        while FileManager.default.fileExists(atPath: destinationURL.path) && destinationURL.standardizedFileURL != sourceURL.standardizedFileURL {
            destinationURL = parentFolder.appendingPathComponent("\(sanitized) \(counter)").appendingPathExtension(ext)
            counter += 1
        }

        let isAccessing = sourceURL.startAccessingSecurityScopedResource()
        defer { if isAccessing { sourceURL.stopAccessingSecurityScopedResource() } }

        let coordinator = NSFileCoordinator(filePresenter: nil)
        var coordinatorError: NSError?
        var moveError: Error?
        var movedTo: URL?
        coordinator.coordinate(writingItemAt: sourceURL, options: .forMoving,
                               writingItemAt: destinationURL, options: .forReplacing,
                               error: &coordinatorError) { newSourceURL, newDestinationURL in
            do {
                coordinator.item(at: newSourceURL, willMoveTo: newDestinationURL)
                try FileManager.default.moveItem(at: newSourceURL, to: newDestinationURL)
                // Tells the open UIDocument (a file presenter) where its file went, so autosave
                // writes there instead of recreating or failing on the old path
                coordinator.item(at: newSourceURL, didMoveTo: newDestinationURL)
                movedTo = newDestinationURL
            } catch {
                moveError = error
            }
        }
        if let movedTo {
            renamedFileURL = movedTo
        } else if let error = moveError ?? coordinatorError {
            renameError = "“\(sourceURL.lastPathComponent)” couldn’t be renamed. \(error.localizedDescription)"
        }
    }

    private func folderAccessBanner(for folderURL: URL) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "folder.badge.questionmark")
                .foregroundStyle(Color.accentColor)
            Text("Allow access to **\(folderURL.lastPathComponent)** to show linked images.")
                .font(.footnote)
                .lineLimit(2)
            Spacer(minLength: 0)
            Button("Allow…") {
                FolderAccessManager.shared.promptForAccess(to: folderURL) { success in
                    if success { dismissedFolderBanner = nil }
                }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .accessibilityIdentifier("GrantFolderAccessButton")
            Button {
                dismissedFolderBanner = folderURL
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .accessibilityLabel("Dismiss")
            .accessibilityIdentifier("DismissFolderAccessButton")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .glassEffect(.regular, in: .rect(cornerRadius: 16))
        .padding(.horizontal, 12)
        .padding(.bottom, 6)
    }

    // MARK: - Conflicts & Folder Links

    private func refreshConflicts() {
        let count = fileURL.map { DocumentConflicts.unresolved(at: $0).count } ?? 0
        if count != conflictCount { conflictCount = count }
    }

    private func resolveConflicts(keeping version: NSFileVersion?, at url: URL) {
        do {
            if let text = try DocumentConflicts.resolve(at: url, keeping: version) {
                commit(MarkdownEdit(text: text, selection: NSRange(location: 0, length: 0)),
                       actionName: "Keep Other Version")
            }
        } catch {
            conflictError = error.localizedDescription
        }
        refreshConflicts()
    }

    /// Opens a relative or `file:` note link in the document's folder, if it points to one.
    private func openRelativeNoteIfPossible(_ url: URL) -> Bool {
        guard let fileURL else { return false }
        let root = fileURL.deletingLastPathComponent().standardizedFileURL
        _ = FolderAccessManager.shared.ensureAccess(for: root)
        guard let resolved = NoteLinkResolver.resolve(url.absoluteString, from: fileURL, root: root) else {
            return false
        }
        DocumentOpener.open(resolved)
        return true
    }

    // MARK: - Formatting

    /// Formatting writes the document's flavour: Slack mrkdwn gets `*bold*`, `_italic_`, `~strike~`
    /// and `<url|text>` links (SlackMarkdown.swift).
    private func handleFormatCommand(_ command: FormatCommand) {
        RecentFormatCommands.shared.record(command)
        let selection = editor.isAttached ? editor.selection : NSRange(location: (document.text as NSString).length, length: 0)
        if command == .link {
            let current = FormatCommandEdits.activeLink(text: document.text, selection: selection, flavor: document.flavor)
            let clipboard = PlatformPasteboard.string.flatMap { URL(string: $0)?.scheme != nil ? $0 : nil }
            linkPrompt = LinkPrompt(url: current ?? clipboard ?? "", isEditing: current != nil, selection: selection)
            return
        }
        guard let edit = FormatCommandEdits.edit(for: command, text: document.text, selection: selection, flavor: document.flavor) else { return }
        commit(edit, actionName: command.actionName)
    }

    private func applyLink(_ url: String?, selection: NSRange) {
        let trimmed = url?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let trimmed = trimmed, trimmed.isEmpty { return }
        guard let edit = FormatCommandEdits.link(trimmed, text: document.text, selection: selection, flavor: document.flavor) else { return }
        commit(edit, actionName: trimmed == nil ? "Remove Link" : "Link")
    }

    /// Edits go through the live text view so they can be undone (GOTCHAS #10).
    private func commit(_ edit: MarkdownEdit, actionName: String) {
        if editor.isAttached {
            editor.apply(edit, actionName: actionName)
            document.text = edit.text
            editor.focus()
        } else {
            document.text = edit.text
        }
    }

    private struct LinkPrompt {
        var url: String
        let isEditing: Bool
        let selection: NSRange
    }
}

/// Hides the bar of the navigation controller DocumentGroup puts the document in, while the
/// iPad split view is on screen. SwiftUI repeats the document's back button and title menu in
/// the detail column's bar, but ignores `.toolbar(.hidden, for: .navigationBar)` for its own
/// bar, so both showed (GOTCHAS #76). Removing the view (compact width) brings the bar back.
private struct DocumentBarHider: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> Controller { Controller() }
    func updateUIViewController(_ controller: Controller, context: Context) { controller.hideBar() }
    static func dismantleUIViewController(_ controller: Controller, coordinator: ()) { controller.restoreBar() }

    final class Controller: UIViewController {
        private weak var hiddenIn: UINavigationController?

        override func didMove(toParent parent: UIViewController?) {
            super.didMove(toParent: parent)
            parent == nil ? restoreBar() : hideBar()
        }

        override func viewWillAppear(_ animated: Bool) {
            super.viewWillAppear(animated)
            hideBar()
        }

        func hideBar() {
            guard let navigation = navigationController else { return }
            hiddenIn = navigation
            if !navigation.isNavigationBarHidden { navigation.setNavigationBarHidden(true, animated: false) }
        }

        func restoreBar() {
            hiddenIn?.setNavigationBarHidden(false, animated: false)
            hiddenIn = nil
        }
    }
}

private extension FormatCommand {
    /// The Undo menu's name for the edit: the manifest label ("Undo Heading 2"), without a
    /// trailing ellipsis. Only Swash's own commands are named here.
    var actionName: String {
        if let label = label {
            return label.hasSuffix("…") ? String(label.dropLast()) : label
        }
        switch self {
        case .callout: return "Callout"
        case .footnote: return "Footnote"
        case .tableOfContents: return "Table of Contents"
        default: return "Format"
        }
    }
}
#Preview("iOS Editor") {
    @Previewable @State var document = SwashSampleDocument.standard
    NavigationStack {
        IOSContentView(document: $document, fileURL: nil)
    }
}

#Preview("iOS Editor - Focus Mode") {
    @Previewable @State var document = SwashSampleDocument.standard
    let defaults: UserDefaults = {
        let suite = UserDefaults(suiteName: "focus-mode-preview")!
        suite.set(true, forKey: WritingDefaults.focusMode)
        return suite
    }()
    NavigationStack {
        IOSContentView(document: $document, fileURL: nil)
    }
    .defaultAppStorage(defaults)
}

#Preview("iOS Editor - Dark Mode") {
    @Previewable @State var document = SwashSampleDocument.tablesAndMath
    NavigationStack {
        IOSContentView(document: $document, fileURL: nil)
    }
    .preferredColorScheme(.dark)
}

#Preview("iOS Editor - iPad", traits: .landscapeLeft) {
    @Previewable @State var document = SwashSampleDocument.standard
    NavigationStack {
        IOSContentView(document: $document, fileURL: nil)
    }
}
#endif

//
//  IOSDocumentFeatures.swift
//  Swash
//
//  The Mac's newer document features on iPhone and iPad (#57): the heading outline (a sheet on
//  iPhone, a sidebar column on iPad at regular width), Document Info (word count and reading time),
//  export as PDF or HTML through the share sheet, printing, and the typography settings with
//  Dynamic Type.
//

#if os(iOS)
import SwiftUI
import UIKit
import PixerateMarkdown

// MARK: - Typography

/// Settings › Typography, read from the same defaults as the Mac. The editor and preview sizes are
/// multiplied by the Dynamic Type scale of the body style, so the default settings at the default
/// Dynamic Type size reproduce the original look exactly.
struct IOSTypographySettings: DynamicProperty {
    @AppStorage(EditorTypography.Keys.font) private var font: TypographyFont = .system
    @AppStorage(EditorTypography.Keys.textSize) private var textSize: Double = Double(EditorTypography.defaultTextSize)
    @AppStorage(EditorTypography.Keys.lineWidth) private var lineWidth: TypographyLineWidth = .full
    @AppStorage(EditorTypography.Keys.theme) private var theme: EditorTheme = .system
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    /// The saved settings, without Dynamic Type.
    var stored: EditorTypography {
        EditorTypography(font: font, textSize: EditorTypography.clampedSize(textSize), lineWidth: lineWidth, theme: theme)
    }

    /// The settings with the text size scaled for Dynamic Type, for Edit Text and the Preview.
    var scaled: EditorTypography {
        var typography = stored
        typography.textSize = (typography.textSize * Self.dynamicTypeScale(dynamicTypeSize) * 2).rounded() / 2
        return typography
    }

    /// How much Dynamic Type enlarges body text (1 at the default size, Large).
    static func dynamicTypeScale(_ size: DynamicTypeSize) -> CGFloat {
        let traits = UITraitCollection(preferredContentSizeCategory: UIContentSizeCategory(size))
        return UIFontMetrics(forTextStyle: .body).scaledValue(for: 17, compatibleWith: traits) / 17
    }
}

/// The Typography and Colours sections of the iOS Settings sheet.
struct IOSTypographySettingsSections: View {
    @AppStorage(EditorTypography.Keys.font) private var font: TypographyFont = .system
    @AppStorage(EditorTypography.Keys.textSize) private var textSize: Double = Double(EditorTypography.defaultTextSize)
    @AppStorage(EditorTypography.Keys.lineWidth) private var lineWidth: TypographyLineWidth = .full
    @AppStorage(EditorTypography.Keys.theme) private var theme: EditorTheme = .system

    private var typography: EditorTypography {
        EditorTypography(font: font, textSize: EditorTypography.clampedSize(textSize), lineWidth: lineWidth, theme: theme)
    }

    /// Text size relative to the default, as the reader sees it ("100%").
    private var sizeLabel: String {
        "\(Int((textSize / Double(EditorTypography.defaultTextSize) * 100).rounded()))%"
    }

    var body: some View {
        Section {
            Picker("Font", selection: $font) {
                ForEach(TypographyFont.allCases) { font in
                    Text(font.title).tag(font)
                }
            }
            Stepper(value: $textSize,
                    in: Double(EditorTypography.minTextSize)...Double(EditorTypography.maxTextSize),
                    step: 1) {
                LabeledContent("Text Size", value: sizeLabel)
            }
            .accessibilityValue(sizeLabel)
            Picker("Line Width", selection: $lineWidth) {
                ForEach(TypographyLineWidth.allCases) { width in
                    Text(width.title).tag(width)
                }
            }
        } header: {
            Text("Typography")
        } footer: {
            Text("Applies to Formatted, Source and the preview, on top of the text size in Settings › Display & Brightness. The readable column only shows where the window is wider than it.")
        }

        Section {
            Picker("Theme", selection: $theme) {
                ForEach(EditorTheme.allCases) { theme in
                    Label {
                        Text(theme.title)
                    } icon: {
                        Image(systemName: "circle.fill")
                            .foregroundStyle(theme.accent.map { Color(uiColor: $0) } ?? Color.accentColor)
                    }
                    .tag(theme)
                }
            }
            .pickerStyle(.navigationLink)
            sample
        } header: {
            Text("Colours")
        } footer: {
            Text("Themes colour code, links, quotes and tasks, and follow Light and Dark Mode.")
        }

        Section {
            Button("Restore Defaults") {
                font = .system
                textSize = Double(EditorTypography.defaultTextSize)
                lineWidth = .full
                theme = .system
            }
            .disabled(typography == EditorTypography())
        }
    }

    private var sample: some View {
        let accent = typography.previewAccent
        let swash = Text("Swash").bold()
        let code = Text("code").monospaced().foregroundStyle(accent)
        let links = Text("links").foregroundStyle(accent).underline()
        return Text("\(swash) writes \(code) and \(links)")
            .font(typography.previewFont())
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 6)
            .listRowBackground(typography.theme.background.map { Color(uiColor: $0) })
            .accessibilityLabel("Sample text")
    }
}

// MARK: - Outline

/// The document's headings; the one around the caret is marked and choosing one moves the editor there.
struct IOSOutlineList: View {
    let outline: MarkdownOutline
    let currentIndex: Int?
    let select: (Int) -> Void

    var body: some View {
        if outline.headings.isEmpty {
            ContentUnavailableView("No Headings", systemImage: "list.bullet.indent",
                                   description: Text("Lines starting with # appear here."))
        } else {
            let minLevel = outline.headings.map(\.level).min() ?? 1
            ScrollViewReader { proxy in
                List {
                    ForEach(Array(outline.headings.enumerated()), id: \.offset) { index, heading in
                        Button {
                            select(index)
                        } label: {
                            Text(heading.title.isEmpty ? "Untitled" : heading.title)
                                .fontWeight(heading.level == minLevel ? .semibold : .regular)
                                .foregroundStyle(heading.title.isEmpty ? .secondary : .primary)
                                .lineLimit(2)
                                .padding(.leading, CGFloat(min(heading.level - minLevel, 5)) * 14)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .listRowBackground(index == currentIndex ? Color.accentColor.opacity(0.15) : nil)
                        .accessibilityLabel("\(heading.title.isEmpty ? "Untitled" : heading.title), heading level \(heading.level)")
                        .accessibilityAddTraits(index == currentIndex ? .isSelected : [])
                        .id(index)
                    }
                }
                .onAppear {
                    if let currentIndex { proxy.scrollTo(currentIndex, anchor: .center) }
                }
            }
        }
    }
}

extension IOSEditorController {
    /// Puts the caret at `rawLocation` (raw Markdown) and scrolls its line to the top of the editor.
    func reveal(rawLocation: Int) {
        guard let textView else { return }
        var range = NSRange(location: rawLocation, length: 0)
        if let styled = textView as? StyledUITextView, let coordinator = styled.coordinator {
            range = coordinator.storageRange(forRaw: range, in: styled)
        }
        let length = textView.textStorage.length
        range = NSRange(location: min(max(0, range.location), length), length: 0)
        textView.selectedRange = range

        let layoutManager = textView.layoutManager
        layoutManager.ensureLayout(for: textView.textContainer)
        guard layoutManager.numberOfGlyphs > 0 else { return }
        let glyph = min(layoutManager.glyphIndexForCharacter(at: min(range.location, max(0, length - 1))), layoutManager.numberOfGlyphs - 1)
        let line = layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
        let insets = textView.adjustedContentInset
        let maxY = max(-insets.top, textView.contentSize.height - textView.bounds.height + insets.bottom)
        let y = min(max(-insets.top, line.minY + textView.textContainerInset.top - insets.top - 8), maxY)
        textView.setContentOffset(CGPoint(x: textView.contentOffset.x, y: y), animated: true)
    }
}

// MARK: - Document Info

/// Word count, characters, paragraphs and reading time, for the document and the selection.
struct IOSDocumentInfoView: View {
    let title: String
    let document: MarkdownStatistics
    let selection: MarkdownStatistics?
    let headings: Int
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("Document") {
                    rows(document)
                    LabeledContent("Headings", value: format(headings))
                    LabeledContent("Reading Time", value: readingTime(document))
                }
                if let selection {
                    Section("Selection") {
                        rows(selection)
                        LabeledContent("Reading Time", value: readingTime(selection))
                    }
                }
            }
            .monospacedDigit()
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    @ViewBuilder
    private func rows(_ statistics: MarkdownStatistics) -> some View {
        LabeledContent("Words", value: format(statistics.words))
        LabeledContent("Characters", value: format(statistics.characters))
        LabeledContent("Characters (No Spaces)", value: format(statistics.charactersExcludingSpaces))
        LabeledContent("Paragraphs", value: format(statistics.paragraphs))
    }

    private func format(_ value: Int) -> String {
        value.formatted(.number)
    }

    private func readingTime(_ statistics: MarkdownStatistics) -> String {
        let minutes = statistics.readingMinutes
        if minutes == 0 { return "—" }
        return Duration.seconds(minutes * 60).formatted(.units(allowed: [.hours, .minutes], width: .abbreviated))
    }
}

// MARK: - Export and print

enum IOSExportFormat: String, Identifiable {
    case pdf = "PDF"
    case html = "HTML"
    var id: String { rawValue }
}

/// Presents UIKit view controllers over the key window's frontmost one, anchored at the top
/// trailing corner on iPad (where the toolbar's overflow menu is).
enum IOSPresenter {
    static var frontmost: UIViewController? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        guard let window = scenes.filter({ $0.activationState == .foregroundActive }).flatMap(\.windows).first(where: \.isKeyWindow),
              var presenter = window.rootViewController else { return nil }
        while let presented = presenter.presentedViewController, !presented.isBeingDismissed { presenter = presented }
        return presenter
    }

    /// The system share sheet for `items` (GOTCHAS #55: not ShareLink, which crashes in the overflow menu).
    static func share(_ items: [Any], subject: String) {
        guard let presenter = frontmost else { return }
        let activity = UIActivityViewController(activityItems: items, applicationActivities: nil)
        activity.setValue(subject, forKey: "subject")
        if let popover = activity.popoverPresentationController {
            popover.sourceView = presenter.view
            popover.sourceRect = CGRect(x: presenter.view.bounds.maxX - 60, y: presenter.view.safeAreaInsets.top, width: 1, height: 1)
            popover.permittedArrowDirections = .up
        }
        presenter.present(activity, animated: true)
    }
}

// MARK: - Toolbar, sheets and the outline column

/// State shared by the toolbar items (in IOSContentView's toolbar) and the sheets and outline
/// column around the content (`IOSDocumentFeatures`). A second `.toolbar` inside the content
/// isn't merged into the document's toolbar on iOS, so the items live in the main one.
@MainActor @Observable
final class IOSDocumentFeaturesModel {
    var outlineColumnVisible = false
    var showingOutlineSheet = false
    var info: InfoSnapshot?
    var outline = MarkdownOutline(text: "")
    var currentHeading: Int?
    var exporting: String?
    var exportError: String?

    struct InfoSnapshot: Identifiable {
        let id = UUID()
        let document: MarkdownStatistics
        let selection: MarkdownStatistics?
        let headings: Int
    }

    // MARK: Outline

    /// The toolbar button: a column at regular width (iPad), a sheet otherwise.
    func showOutline(text: String, editor: IOSEditorController, regularWidth: Bool) {
        refreshOutline(text: text, editor: editor)
        if regularWidth {
            withAnimation(.easeInOut(duration: 0.25)) { outlineColumnVisible.toggle() }
        } else {
            showingOutlineSheet = true
        }
    }

    func refreshOutline(text: String, editor: IOSEditorController) {
        let newOutline = MarkdownOutline(text: text)
        if newOutline != outline { outline = newOutline }
        let caret = editor.isAttached ? editor.selection.location : nil
        let index = caret.flatMap { outline.headingIndex(containing: $0) }
        if index != currentHeading { currentHeading = index }
    }

    func choose(_ index: Int, editor: IOSEditorController) {
        guard outline.headings.indices.contains(index) else { return }
        currentHeading = index
        let location = outline.headings[index].range.location
        // After the sheet has gone, so the editor can scroll
        DispatchQueue.main.async { editor.reveal(rawLocation: location) }
    }

    // MARK: Info

    func showInfo(text: String, editor: IOSEditorController) {
        let ns = text as NSString
        var selectionStatistics: MarkdownStatistics?
        if editor.isAttached {
            let range = editor.selection
            if range.length > 0, NSMaxRange(range) <= ns.length {
                selectionStatistics = MarkdownStatistics(text: ns.substring(with: range))
            }
        }
        info = InfoSnapshot(document: MarkdownStatistics(text: text), selection: selectionStatistics,
                            headings: MarkdownOutline(text: text).headings.count)
    }

    // MARK: Export

    /// Typesets the document, writes it to a temporary file and offers it in the share sheet.
    func export(_ format: IOSExportFormat, source: DocumentExporter.Source) {
        withAnimation { exporting = "Preparing \(format.rawValue)…" }
        Task {
            defer { withAnimation { exporting = nil } }
            do {
                let folder = FileManager.default.temporaryDirectory
                    .appendingPathComponent("Export", isDirectory: true)
                    .appendingPathComponent(UUID().uuidString, isDirectory: true)
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                let name = Self.fileName(source.title)
                let url: URL
                switch format {
                case .pdf:
                    url = folder.appendingPathComponent(name).appendingPathExtension("pdf")
                    try await DocumentExporter.exportPDF(source).write(to: url)
                case .html:
                    url = folder.appendingPathComponent(name).appendingPathExtension("html")
                    try await DocumentExporter.standaloneHTML(for: source).write(to: url, atomically: true, encoding: .utf8)
                }
                IOSPresenter.share([url], subject: source.title)
            } catch {
                exportError = error.localizedDescription
            }
        }
    }

    func print(source: DocumentExporter.Source) {
        withAnimation { exporting = "Preparing to Print…" }
        Task {
            do {
                try await DocumentExporter.print(source) {
                    withAnimation { exporting = nil }
                }
            } catch {
                exportError = error.localizedDescription
            }
            withAnimation { exporting = nil }
        }
    }

    /// A file name without characters Files won't accept.
    static func fileName(_ title: String) -> String {
        let cleaned = title.components(separatedBy: CharacterSet(charactersIn: "/:\\")).joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? "Untitled" : cleaned
    }
}

/// The Outline button (primary) and the Document Info and Export items (overflow).
struct IOSDocumentToolbar: ToolbarContent {
    let model: IOSDocumentFeaturesModel
    let text: String
    let source: () -> DocumentExporter.Source
    let editor: IOSEditorController
    let regularWidth: Bool

    var body: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            Button {
                model.showOutline(text: text, editor: editor, regularWidth: regularWidth)
            } label: {
                Label("Outline", systemImage: "list.bullet.indent")
            }
            .accessibilityHint(regularWidth ? "Shows or hides the list of headings" : "Shows the list of headings")
        }
        ToolbarItem(placement: .secondaryAction) {
            Button {
                model.showInfo(text: text, editor: editor)
            } label: {
                Label("Document Info", systemImage: "info.circle")
            }
        }
        ToolbarItem(placement: .secondaryAction) {
            Menu {
                Button {
                    model.export(.pdf, source: source())
                } label: {
                    Label("Export as PDF", systemImage: "doc.richtext")
                }
                Button {
                    model.export(.html, source: source())
                } label: {
                    Label("Export as HTML", systemImage: "chevron.left.forwardslash.chevron.right")
                }
                Button {
                    model.print(source: source())
                } label: {
                    Label("Print", systemImage: "printer")
                }
                Divider()
                Button {
                    DocumentExporter.copyRichText(source())
                } label: {
                    Label("Copy as Rich Text", systemImage: "doc.on.clipboard")
                }
                Button {
                    DocumentExporter.copyHTML(source())
                } label: {
                    Label("Copy HTML", systemImage: "curlybraces")
                }
            } label: {
                Label("Export", systemImage: "square.and.arrow.up.on.square")
            }
            .disabled(model.exporting != nil)
        }
    }
}

/// The outline column (iPad), the outline and Document Info sheets, export progress and errors.
struct IOSDocumentFeatures: ViewModifier {
    @Bindable var model: IOSDocumentFeaturesModel
    let text: String
    let editor: IOSEditorController

    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @SceneStorage("outlineColumnVisible") private var storedColumnVisible = false

    private var showsOutlineColumn: Bool { horizontalSizeClass == .regular && model.outlineColumnVisible }

    func body(content: Content) -> some View {
        HStack(spacing: 0) {
            if showsOutlineColumn {
                outlineColumn
                    .frame(width: 280)
                    .transition(.move(edge: .leading))
                Divider()
                    .ignoresSafeArea(.container, edges: .bottom)
            }
            content
        }
        .onAppear {
            if storedColumnVisible != model.outlineColumnVisible { model.outlineColumnVisible = storedColumnVisible }
        }
        .onChange(of: model.outlineColumnVisible) { _, visible in storedColumnVisible = visible }
        .task(id: showsOutlineColumn ? text : nil) {
            // Keeps the column current while typing, a moment after the typing stops
            guard showsOutlineColumn else { return }
            try? await Task.sleep(for: .milliseconds(model.outline.headings.isEmpty ? 0 : 300))
            guard !Task.isCancelled else { return }
            model.refreshOutline(text: text, editor: editor)
        }
        .sheet(isPresented: $model.showingOutlineSheet) {
            NavigationStack {
                IOSOutlineList(outline: model.outline, currentIndex: model.currentHeading) { index in
                    model.showingOutlineSheet = false
                    model.choose(index, editor: editor)
                }
                .navigationTitle("Outline")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { model.showingOutlineSheet = false }
                    }
                }
            }
            .presentationDetents([.medium, .large])
        }
        .sheet(item: $model.info) { snapshot in
            IOSDocumentInfoView(title: "Document Info", document: snapshot.document, selection: snapshot.selection, headings: snapshot.headings)
                .presentationDetents([.medium, .large])
        }
        .overlay(alignment: .bottom) {
            if let exporting = model.exporting {
                Label {
                    Text(exporting)
                } icon: {
                    ProgressView()
                }
                .font(.callout)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(.regularMaterial, in: Capsule())
                .padding(.bottom, 24)
                .transition(.opacity)
            }
        }
        .alert("Couldn’t Export", isPresented: Binding(get: { model.exportError != nil }, set: { if !$0 { model.exportError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.exportError ?? "")
        }
    }

    private var outlineColumn: some View {
        IOSOutlineList(outline: model.outline, currentIndex: model.currentHeading) { model.choose($0, editor: editor) }
            .listStyle(.sidebar)
            .background(Color(uiColor: .secondarySystemBackground))
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Outline")
    }
}
#endif

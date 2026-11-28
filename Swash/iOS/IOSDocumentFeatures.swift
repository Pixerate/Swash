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
import MacAppKitExtras
import UIKit
import PixerateMarkdown
import LinkPresentation
import UniformTypeIdentifiers

// MARK: - Typography and Writing Options

/// Settings › Typography and Writing, read from the same defaults as the Mac. The editor and preview
/// sizes are multiplied by the Dynamic Type scale of the body style, so the default settings at the
/// default Dynamic Type size reproduce the original look exactly.
struct IOSTypographySettings: DynamicProperty {
    @AppStorage(EditorTypography.Keys.font) private var font: TypographyFont = .system
    @AppStorage(EditorTypography.Keys.textSize) private var textSize: Double = Double(EditorTypography.defaultTextSize)
    @AppStorage(EditorTypography.Keys.lineWidth) private var lineWidth: TypographyLineWidth = .full
    @AppStorage(EditorTypography.Keys.theme) private var theme: EditorTheme = .system
    @AppStorage(WritingDefaults.focusMode) private var focusMode = false
    @AppStorage(WritingDefaults.focusUnit) private var focusUnit: FocusUnit = .paragraph
    @AppStorage(WritingDefaults.typewriterScrolling) private var typewriterScrolling = false
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

    /// Focus mode, typewriter scrolling and readable column for the styled editor.
    func writingOptions(distractionFree: Bool = false) -> WritingOptions {
        let scaled = self.scaled
        return WritingOptions(
            focus: focusMode ? focusUnit : nil,
            typewriter: typewriterScrolling,
            readableColumn: distractionFree || lineWidth == .readable,
            columnWidth: scaled.readableColumnWidth
        )
    }

    /// How much Dynamic Type enlarges body text (1 at the default size, Large).
    static func dynamicTypeScale(_ size: DynamicTypeSize) -> CGFloat {
        let traits = UITraitCollection(preferredContentSizeCategory: UIContentSizeCategory(size))
        return UIFontMetrics(forTextStyle: .body).scaledValue(for: 17, compatibleWith: traits) / 17
    }
}

/// The Typography, Writing and Colours sections of the iOS Settings sheet.
struct IOSTypographySettingsSections: View {
    @AppStorage(EditorTypography.Keys.font) private var font: TypographyFont = .system
    @AppStorage(EditorTypography.Keys.textSize) private var textSize: Double = Double(EditorTypography.defaultTextSize)
    @AppStorage(EditorTypography.Keys.lineWidth) private var lineWidth: TypographyLineWidth = .full
    @AppStorage(EditorTypography.Keys.theme) private var theme: EditorTheme = .system
    @AppStorage(WritingDefaults.focusMode) private var focusMode = false
    @AppStorage(WritingDefaults.focusUnit) private var focusUnit: FocusUnit = .paragraph
    @AppStorage(WritingDefaults.typewriterScrolling) private var typewriterScrolling = false

    private var typography: EditorTypography {
        EditorTypography(font: font, textSize: EditorTypography.clampedSize(textSize), lineWidth: lineWidth, theme: theme)
    }

    private var isDefault: Bool {
        typography == EditorTypography() && !focusMode && focusUnit == .paragraph && !typewriterScrolling
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
            Toggle("Focus Mode", isOn: $focusMode)
            Picker("Focus On", selection: $focusUnit) {
                ForEach(FocusUnit.allCases) { unit in
                    Text(unit.title).tag(unit)
                }
            }
            Toggle("Typewriter Scrolling", isOn: $typewriterScrolling)
        } header: {
            Text("Writing")
        } footer: {
            Text("Focus Mode dims everything outside the current paragraph or sentence. Typewriter Scrolling keeps the line you’re typing centred on the screen.")
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
                focusMode = false
                focusUnit = .paragraph
                typewriterScrolling = false
            }
            .disabled(isDefault)
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
            .sheetRootNavigation()
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
    /// Optional observer hook for unit tests to inspect presented view controllers.
    static var onPresent: ((UIViewController) -> Void)?

    static var frontmost: UIViewController? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let activeWindows = scenes.filter { $0.activationState == .foregroundActive }.flatMap(\.windows)
        let allWindows = activeWindows.isEmpty ? scenes.flatMap(\.windows) : activeWindows
        guard let window = allWindows.first(where: \.isKeyWindow) ?? allWindows.first,
              var presenter = window.rootViewController else { return nil }
        while let presented = presenter.presentedViewController, !presented.isBeingDismissed { presenter = presented }
        return presenter
    }

    /// Presents a configured `UIActivityViewController` anchored at the top trailing corner on iPad.
    static func presentActivity(_ activity: UIActivityViewController) {
        onPresent?(activity)
        guard let presenter = frontmost else { return }
        if let popover = activity.popoverPresentationController {
            if let item = shareBarItem(under: presenter) {
                // Wherever the bar is: on the iPhone Duo bars can run down the trailing edge (#65)
                popover.sourceItem = item
                popover.permittedArrowDirections = .any
            } else {
                popover.sourceView = presenter.view
                popover.sourceRect = CGRect(x: presenter.view.bounds.maxX - 60, y: presenter.view.safeAreaInsets.top, width: 1, height: 1)
                popover.permittedArrowDirections = .up
            }
        }
        if let dismissing = presenter.presentedViewController, dismissing.isBeingDismissed,
           let coordinator = dismissing.transitionCoordinator {
            coordinator.animate(alongsideTransition: nil) { _ in
                presenter.present(activity, animated: true)
            }
        } else {
            presenter.present(activity, animated: true)
        }
    }

    /// The toolbar's Share item in the visible navigation bar under `controller`, if it shows one.
    /// SwiftUI turns toolbar items into bar button items titled with their label.
    private static func shareBarItem(under controller: UIViewController) -> UIBarButtonItem? {
        if let navigation = controller as? UINavigationController, !navigation.isNavigationBarHidden,
           navigation.viewIfLoaded?.window != nil, let item = navigation.topViewController?.navigationItem {
            let items = item.trailingItemGroups.flatMap(\.barButtonItems) + (item.rightBarButtonItems ?? [])
            if let share = items.first(where: { $0.title == "Share" && !$0.isHidden }) { return share }
        }
        for child in controller.children.reversed() {
            if let share = shareBarItem(under: child) { return share }
        }
        return nil
    }

    /// The system share sheet for `items` (GOTCHAS #55: not ShareLink, which crashes in the overflow menu).
    static func share(_ items: [Any], subject: String, applicationActivities: [UIActivity]? = nil) {
        let activity = UIActivityViewController(activityItems: items, applicationActivities: applicationActivities)
        activity.setValue(subject, forKey: "subject")
        presentActivity(activity)
    }

    /// The share sheet action activities for a Markdown document: Export as PDF, Export as HTML,
    /// Copy as Rich Text, and Copy HTML (#183).
    static func documentActivities(
        for source: DocumentExporter.Source,
        model: IOSDocumentFeaturesModel? = nil
    ) -> [UIActivity] {
        [
            ExportPDFActivity(source: source, model: model),
            ExportHTMLActivity(source: source, model: model),
            CopyRichTextActivity(source: source),
            CopyHTMLActivity(source: source),
            PrintDocumentActivity(source: source, model: model),
        ]
    }

    /// Builds the `UIActivityViewController` for sharing a document (used by both the toolbar
    /// Share button and the navigation bar's document title menu).
    /// Includes:
    /// - `DocumentShareItemSource` (formatted rich text for Apple Notes, plain text Markdown for
    ///   Messages/Mail/Notion, and the `.md` file URL for AirDrop and Save to Files)
    /// - `applicationActivities`: `ExportPDFActivity`, `ExportHTMLActivity`,
    ///   `CopyRichTextActivity`, `CopyHTMLActivity`, `PrintDocumentActivity`
    /// The system Print action is excluded: it would print untypeset HTML (no math or diagrams),
    /// while `PrintDocumentActivity` typesets first, like the Mac.
    static func makeDocumentActivityViewController(
        source: DocumentExporter.Source,
        model: IOSDocumentFeaturesModel? = nil
    ) -> UIActivityViewController {
        let html = DocumentExporter.clipboardHTML(for: source)
        let itemSource = DocumentShareItemSource(source: source, html: html)
        let activities = documentActivities(for: source, model: model)
        let controller = UIActivityViewController(
            activityItems: [itemSource],
            applicationActivities: activities
        )
        controller.excludedActivityTypes = [.print]
        controller.setValue(source.title, forKey: "subject")
        return controller
    }

    /// Presents the system share sheet for sharing a document.
    static func shareDocument(source: DocumentExporter.Source, model: IOSDocumentFeaturesModel? = nil) {
        let controller = makeDocumentActivityViewController(source: source, model: model)
        presentActivity(controller)
    }

    /// Presents the system share sheet for sharing a document.
    static func shareDocument(
        title: String,
        text: String,
        flavor: MarkdownFlavor,
        fileURL: URL?,
        model: IOSDocumentFeaturesModel? = nil
    ) {
        let source = DocumentExporter.Source(text: text, flavor: flavor, fileURL: fileURL, title: title)
        shareDocument(source: source, model: model)
    }
}

// MARK: - Document sharing sources, activities and transferable items

extension UIActivity.ActivityType {
    static let saveToFiles = UIActivity.ActivityType("com.apple.UIKit.activity.SaveToFiles")
    static let exportPDF = UIActivity.ActivityType("com.pixerate.Swash.activity.exportPDF")
    static let exportHTML = UIActivity.ActivityType("com.pixerate.Swash.activity.exportHTML")
    static let copyRichText = UIActivity.ActivityType("com.pixerate.Swash.activity.copyRichText")
    static let copyHTML = UIActivity.ActivityType("com.pixerate.Swash.activity.copyHTML")
    static let printDocument = UIActivity.ActivityType("com.pixerate.Swash.activity.print")
}

/// An activity item source that shares multiple representations of a Markdown document,
/// picking the appropriate representation for each activity:
/// - HTML (`UTType.html`) / rich text for Apple Notes (`com.apple.mobilenotes.SharingExtension`)
/// - `UIMarkupTextPrintFormatter` for the system Print action (`.print`)
/// - Plain text (`UTType.plainText`) for Messages, Mail, Notion and general text receivers
/// - The `.md` file URL for AirDrop and Save to Files
final class DocumentShareItemSource: NSObject, UIActivityItemSource {
    let title: String
    let text: String
    let html: String
    let fileURL: URL
    let flavor: MarkdownFlavor
    private let originalFileURL: URL?

    var source: DocumentExporter.Source {
        DocumentExporter.Source(text: text, flavor: flavor, fileURL: originalFileURL, title: title)
    }

    init(title: String, text: String, html: String, fileURL: URL?, flavor: MarkdownFlavor = .commonMark) {
        self.title = title
        self.text = text
        self.html = html
        self.flavor = flavor
        self.originalFileURL = fileURL
        if let fileURL {
            self.fileURL = fileURL
        } else {
            let folder = FileManager.default.temporaryDirectory
                .appendingPathComponent("Shared", isDirectory: true)
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let temp = folder.appendingPathComponent(IOSDocumentFeaturesModel.fileName(title)).appendingPathExtension("md")
            try? text.write(to: temp, atomically: true, encoding: .utf8)
            self.fileURL = temp
        }
        super.init()
    }

    convenience init(source: DocumentExporter.Source, html: String? = nil) {
        let renderedHTML = html ?? DocumentExporter.clipboardHTML(for: source)
        self.init(
            title: source.title,
            text: source.text,
            html: renderedHTML,
            fileURL: source.fileURL,
            flavor: source.flavor
        )
    }

    /// Nonisolated: an isolated deinit crashes on the iOS Simulator when freed outside a Task.
    nonisolated deinit {}

    func activityViewControllerPlaceholderItem(_ activityViewController: UIActivityViewController) -> Any {
        fileURL
    }

    func activityViewController(_ activityViewController: UIActivityViewController, itemForActivityType activityType: UIActivity.ActivityType?) -> Any? {
        if activityType == .airDrop || activityType == .saveToFiles || activityType?.rawValue.contains("SaveToFiles") == true || activityType?.rawValue.contains("CloudDocs") == true {
            return fileURL
        }
        if activityType == .print {
            return UIMarkupTextPrintFormatter(markupText: html)
        }
        if activityType?.rawValue == "com.apple.mobilenotes.SharingExtension" || activityType?.rawValue.contains("mobilenotes") == true {
            if let data = html.data(using: .utf8),
               let attributed = try? NSAttributedString(data: data, options: [
                   .documentType: NSAttributedString.DocumentType.html,
                   .characterEncoding: String.Encoding.utf8.rawValue
               ], documentAttributes: nil) {
                return attributed
            }
            return text
        }
        return text
    }

    func activityViewController(_ activityViewController: UIActivityViewController, subjectForActivityType activityType: UIActivity.ActivityType?) -> String {
        title
    }

    func activityViewController(_ activityViewController: UIActivityViewController, dataTypeIdentifierForActivityType activityType: UIActivity.ActivityType?) -> String {
        if activityType == .airDrop || activityType == .saveToFiles || activityType?.rawValue.contains("SaveToFiles") == true || activityType?.rawValue.contains("CloudDocs") == true {
            return UTType(filenameExtension: "md")?.identifier ?? UTType.plainText.identifier
        }
        if activityType == .print || activityType?.rawValue == "com.apple.mobilenotes.SharingExtension" || activityType?.rawValue.contains("mobilenotes") == true {
            return UTType.html.identifier
        }
        return UTType.plainText.identifier
    }

    func activityViewControllerLinkMetadata(_ activityViewController: UIActivityViewController) -> LPLinkMetadata? {
        let metadata = LPLinkMetadata()
        metadata.title = title
        metadata.originalURL = fileURL
        metadata.url = fileURL
        return metadata
    }
}

/// Extracts a `DocumentExporter.Source` from share sheet activity items when an activity was not
/// initialized with an explicit source.
private func extractExportSource(from activityItems: [Any]) -> DocumentExporter.Source? {
    for item in activityItems {
        if let shareSource = item as? DocumentShareItemSource {
            return shareSource.source
        }
    }
    for item in activityItems {
        if let text = item as? String {
            return DocumentExporter.Source(text: text, flavor: .commonMark, fileURL: nil, title: "Untitled")
        }
        if let url = item as? URL, let text = try? String(contentsOf: url, encoding: .utf8) {
            let title = url.deletingPathExtension().lastPathComponent
            return DocumentExporter.Source(
                text: text,
                flavor: MarkdownParser.detectFlavor(text),
                fileURL: url,
                title: title.isEmpty ? "Untitled" : title
            )
        }
    }
    return nil
}

/// Share sheet action activity that exports the document as a paginated PDF and presents a share
/// sheet for the generated PDF file.
final class ExportPDFActivity: UIActivity {
    private var source: DocumentExporter.Source?
    private weak var model: IOSDocumentFeaturesModel?
    var onExported: ((Result<URL, Error>) -> Void)?

    init(
        source: DocumentExporter.Source? = nil,
        model: IOSDocumentFeaturesModel? = nil,
        onExported: ((Result<URL, Error>) -> Void)? = nil
    ) {
        self.source = source
        self.model = model
        self.onExported = onExported
        super.init()
    }

    nonisolated deinit {}

    override class var activityCategory: UIActivity.Category { .action }
    override var activityType: UIActivity.ActivityType? { .exportPDF }
    override var activityTitle: String? { "Export as PDF" }
    override var activityImage: UIImage? { UIImage(systemName: "doc.richtext") }

    override func canPerform(withActivityItems activityItems: [Any]) -> Bool {
        source != nil || extractExportSource(from: activityItems) != nil
    }

    override func prepare(withActivityItems activityItems: [Any]) {
        if source == nil {
            source = extractExportSource(from: activityItems)
        }
    }

    override func perform() {
        guard let source else {
            activityDidFinish(false)
            return
        }
        activityDidFinish(true)
        if let model {
            model.export(.pdf, source: source, completion: onExported)
        } else {
            let callback = onExported
            Task {
                do {
                    let url = try await IOSDocumentFeaturesModel.writeExportFile(.pdf, source: source)
                    IOSPresenter.share([url], subject: source.title)
                    callback?(.success(url))
                } catch {
                    callback?(.failure(error))
                }
            }
        }
    }
}

/// Share sheet action activity that exports the document as a self-contained HTML file and
/// presents a share sheet for the generated HTML file.
final class ExportHTMLActivity: UIActivity {
    private var source: DocumentExporter.Source?
    private weak var model: IOSDocumentFeaturesModel?
    var onExported: ((Result<URL, Error>) -> Void)?

    init(
        source: DocumentExporter.Source? = nil,
        model: IOSDocumentFeaturesModel? = nil,
        onExported: ((Result<URL, Error>) -> Void)? = nil
    ) {
        self.source = source
        self.model = model
        self.onExported = onExported
        super.init()
    }

    nonisolated deinit {}

    override class var activityCategory: UIActivity.Category { .action }
    override var activityType: UIActivity.ActivityType? { .exportHTML }
    override var activityTitle: String? { "Export as HTML" }
    override var activityImage: UIImage? { UIImage(systemName: "chevron.left.forwardslash.chevron.right") }

    override func canPerform(withActivityItems activityItems: [Any]) -> Bool {
        source != nil || extractExportSource(from: activityItems) != nil
    }

    override func prepare(withActivityItems activityItems: [Any]) {
        if source == nil {
            source = extractExportSource(from: activityItems)
        }
    }

    override func perform() {
        guard let source else {
            activityDidFinish(false)
            return
        }
        activityDidFinish(true)
        if let model {
            model.export(.html, source: source, completion: onExported)
        } else {
            let callback = onExported
            Task {
                do {
                    let url = try await IOSDocumentFeaturesModel.writeExportFile(.html, source: source)
                    IOSPresenter.share([url], subject: source.title)
                    callback?(.success(url))
                } catch {
                    callback?(.failure(error))
                }
            }
        }
    }
}

/// Share sheet action activity that copies the document to the clipboard as rich text (HTML + plain text).
final class CopyRichTextActivity: UIActivity {
    private var source: DocumentExporter.Source?

    init(source: DocumentExporter.Source? = nil) {
        self.source = source
        super.init()
    }

    nonisolated deinit {}

    override class var activityCategory: UIActivity.Category { .action }
    override var activityType: UIActivity.ActivityType? { .copyRichText }
    override var activityTitle: String? { "Copy as Rich Text" }
    override var activityImage: UIImage? { UIImage(systemName: "doc.on.clipboard") }

    override func canPerform(withActivityItems activityItems: [Any]) -> Bool {
        source != nil || extractExportSource(from: activityItems) != nil
    }

    override func prepare(withActivityItems activityItems: [Any]) {
        if source == nil {
            source = extractExportSource(from: activityItems)
        }
    }

    override func perform() {
        guard let source else {
            activityDidFinish(false)
            return
        }
        DocumentExporter.copyRichText(source)
        activityDidFinish(true)
    }
}

/// Share sheet action activity that copies the document's rendered HTML source to the clipboard.
final class CopyHTMLActivity: UIActivity {
    private var source: DocumentExporter.Source?

    init(source: DocumentExporter.Source? = nil) {
        self.source = source
        super.init()
    }

    nonisolated deinit {}

    override class var activityCategory: UIActivity.Category { .action }
    override var activityType: UIActivity.ActivityType? { .copyHTML }
    override var activityTitle: String? { "Copy HTML" }
    override var activityImage: UIImage? { UIImage(systemName: "curlybraces") }

    override func canPerform(withActivityItems activityItems: [Any]) -> Bool {
        source != nil || extractExportSource(from: activityItems) != nil
    }

    override func prepare(withActivityItems activityItems: [Any]) {
        if source == nil {
            source = extractExportSource(from: activityItems)
        }
    }

    override func perform() {
        guard let source else {
            activityDidFinish(false)
            return
        }
        DocumentExporter.copyHTML(source)
        activityDidFinish(true)
    }
}

/// Share sheet action activity that prints the document typeset (math, diagrams) through
/// `DocumentExporter.print`, instead of the system Print action's untypeset HTML.
final class PrintDocumentActivity: UIActivity {
    private var source: DocumentExporter.Source?
    private weak var model: IOSDocumentFeaturesModel?

    init(source: DocumentExporter.Source? = nil, model: IOSDocumentFeaturesModel? = nil) {
        self.source = source
        self.model = model
        super.init()
    }

    nonisolated deinit {}

    override class var activityCategory: UIActivity.Category { .action }
    override var activityType: UIActivity.ActivityType? { .printDocument }
    override var activityTitle: String? { "Print" }
    override var activityImage: UIImage? { UIImage(systemName: "printer") }

    override func canPerform(withActivityItems activityItems: [Any]) -> Bool {
        source != nil || extractExportSource(from: activityItems) != nil
    }

    override func prepare(withActivityItems activityItems: [Any]) {
        if source == nil {
            source = extractExportSource(from: activityItems)
        }
    }

    override func perform() {
        guard let source else {
            activityDidFinish(false)
            return
        }
        // Finish first: the print sheet can't present while the share sheet is still up
        activityDidFinish(true)
        let model = model
        Task { @MainActor in
            do {
                try await DocumentExporter.print(source)
            } catch {
                model?.exportError = error.localizedDescription
            }
        }
    }
}

/// Configures `UINavigationItem.documentProperties.activityViewControllerProvider` on the
/// enclosing navigation item(s) so the navigation bar's document title menu presents the same
/// share sheet (with Export as PDF, Export as HTML, Copy as Rich Text, Copy HTML and Print)
/// as the toolbar Share button.
struct DocumentShareBridge: UIViewControllerRepresentable {
    let source: DocumentExporter.Source
    let model: IOSDocumentFeaturesModel

    func makeUIViewController(context: Context) -> Controller {
        let controller = Controller()
        controller.configure(source: source, model: model)
        return controller
    }

    func updateUIViewController(_ controller: Controller, context: Context) {
        controller.configure(source: source, model: model)
    }

    final class Controller: UIViewController {
        private var source = DocumentExporter.Source(text: "", flavor: .commonMark, fileURL: nil, title: "Untitled")
        private weak var model: IOSDocumentFeaturesModel?

        nonisolated deinit {}

        func configure(source: DocumentExporter.Source, model: IOSDocumentFeaturesModel) {
            self.source = source
            self.model = model
            applyDocumentProperties()
            DispatchQueue.main.async { [weak self] in
                self?.applyDocumentProperties()
            }
        }

        override func didMove(toParent parent: UIViewController?) {
            super.didMove(toParent: parent)
            applyDocumentProperties()
        }

        override func viewWillAppear(_ animated: Bool) {
            super.viewWillAppear(animated)
            applyDocumentProperties()
        }

        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            applyDocumentProperties()
        }

        func applyDocumentProperties() {
            let provider: () -> UIActivityViewController = { [weak self] in
                guard let self else {
                    return UIActivityViewController(activityItems: [], applicationActivities: nil)
                }
                return IOSPresenter.makeDocumentActivityViewController(source: self.source, model: self.model)
            }

            var candidates: [UIViewController] = []
            var current: UIViewController? = parent
            while let vc = current {
                candidates.append(vc)
                current = vc.parent
            }
            if let navVCs = navigationController?.viewControllers {
                for vc in navVCs where !candidates.contains(where: { $0 === vc }) {
                    candidates.append(vc)
                }
            }

            var updatedAny = false
            for vc in candidates {
                if let existing = vc.navigationItem.documentProperties {
                    existing.activityViewControllerProvider = provider
                    updatedAny = true
                }
            }

            if !updatedAny, let host = navigationController?.topViewController ?? parent {
                let properties: UIDocumentProperties
                if let fileURL = source.fileURL {
                    properties = UIDocumentProperties(url: fileURL)
                } else {
                    let metadata = LPLinkMetadata()
                    metadata.title = source.title
                    properties = UIDocumentProperties(metadata: metadata)
                }
                properties.activityViewControllerProvider = provider
                host.navigationItem.documentProperties = properties
            }
        }
    }
}

/// A transferable representation of a document for SwiftUI ShareLink, offering HTML, plain text,
/// and the Markdown file in priority order.
struct DocumentShareItem: Transferable {
    let title: String
    let text: String
    let html: String
    let fileURL: URL?

    @MainActor
    init(title: String, text: String, flavor: MarkdownFlavor, fileURL: URL?) {
        self.title = title
        self.text = text
        let source = DocumentExporter.Source(text: text, flavor: flavor, fileURL: fileURL, title: title)
        self.html = DocumentExporter.clipboardHTML(for: source)
        self.fileURL = fileURL
    }

    init(title: String, text: String, html: String, fileURL: URL?) {
        self.title = title
        self.text = text
        self.html = html
        self.fileURL = fileURL
    }

    static var transferRepresentation: some TransferRepresentation {
        DataRepresentation(exportedContentType: .html) { item in
            Data(item.html.utf8)
        }
        .suggestedFileName { item in
            "\(item.title).html"
        }
        DataRepresentation(exportedContentType: .plainText) { item in
            Data(item.text.utf8)
        }
        .suggestedFileName { item in
            "\(item.title).txt"
        }
        FileRepresentation(exportedContentType: UTType(filenameExtension: "md") ?? .plainText) { item in
            if let fileURL = item.fileURL {
                return SentTransferredFile(fileURL)
            } else {
                let folder = FileManager.default.temporaryDirectory
                    .appendingPathComponent("Shared", isDirectory: true)
                try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                let temp = folder.appendingPathComponent(IOSDocumentFeaturesModel.fileName(item.title)).appendingPathExtension("md")
                try? item.text.write(to: temp, atomically: true, encoding: .utf8)
                return SentTransferredFile(temp)
            }
        }
    }
}

// MARK: - Toolbar, sheets and the outline column

/// State shared by the toolbar items (in IOSContentView's toolbar) and the sheets and outline
/// sidebar around the content (`IOSDocumentFeatures`). A second `.toolbar` inside the content
/// isn't merged into the document's toolbar on iOS, so the items live in the main one.
@MainActor @Observable
final class IOSDocumentFeaturesModel {
    var showingOutlineSheet = false
    /// Writing Partner Edits (#229): the partner's edit layers for this document.
    var showingPartnerEdits = false
    var info: InfoSnapshot?
    var outline = MarkdownOutline(text: "")
    var currentHeading: Int?
    var exporting: String?
    var exportError: String?

    /// Nonisolated: an isolated deinit crashes on the iOS Simulator (GOTCHAS #103).
    nonisolated deinit {}

    struct InfoSnapshot: Identifiable {
        let id = UUID()
        let document: MarkdownStatistics
        let selection: MarkdownStatistics?
        let headings: Int
    }

    // MARK: Outline

    /// The toolbar's Outline button in compact width (iPad has the sidebar button instead).
    func showOutlineSheet(text: String, editor: IOSEditorController) {
        refreshOutline(text: text, editor: editor)
        showingOutlineSheet = true
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

    /// Typesets the document and writes the exported PDF or HTML file to a temporary folder.
    static func writeExportFile(_ format: IOSExportFormat, source: DocumentExporter.Source) async throws -> URL {
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
        return url
    }

    /// Typesets the document, writes it to a temporary file and offers it in the share sheet.
    func export(_ format: IOSExportFormat, source: DocumentExporter.Source, completion: ((Result<URL, Error>) -> Void)? = nil) {
        withAnimation { exporting = "Preparing \(format.rawValue)…" }
        Task {
            defer { withAnimation { exporting = nil } }
            do {
                let url = try await Self.writeExportFile(format, source: source)
                IOSPresenter.share([url], subject: source.title)
                completion?(.success(url))
            } catch {
                exportError = error.localizedDescription
                completion?(.failure(error))
            }
        }
    }

    /// A file name without characters Files won't accept.
    nonisolated static func fileName(_ title: String) -> String {
        // Line breaks and control characters too: a suggested title can come from any text
        let invalid = CharacterSet(charactersIn: "/:\\").union(.newlines).union(.controlCharacters)
        let cleaned = title.components(separatedBy: invalid).joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? "Untitled" : cleaned
    }
}

/// The Outline button (primary, compact width) and the Document Info and Writing items (overflow).
/// Export and Copy actions live in the system share sheet (#183).
struct IOSDocumentToolbar: ToolbarContent {
    let model: IOSDocumentFeaturesModel
    let text: String
    var source: (() -> DocumentExporter.Source)? = nil
    let editor: IOSEditorController
    let regularWidth: Bool
    var distractionFree: Binding<Bool>? = nil
    /// Pauses the writing partner for this document (#109).
    var partnerPaused: Binding<Bool>? = nil
    @AppStorage(WritingPartnerDefaults.mode) private var partnerMode: WritingPartnerMode = .copyedit

    @AppStorage(WritingDefaults.focusMode) private var focusMode = false
    @AppStorage(WritingDefaults.focusUnit) private var focusUnit: FocusUnit = .paragraph
    @AppStorage(WritingDefaults.typewriterScrolling) private var typewriterScrolling = false

    var body: some ToolbarContent {
        if !regularWidth && !focusMode {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    model.showOutlineSheet(text: text, editor: editor)
                } label: {
                    Label("Outline", systemImage: "list.bullet.indent")
                }
                .accessibilityHint("Shows the list of headings")
            }
        }
        if !regularWidth && !focusMode {
            ToolbarItem(placement: .secondaryAction) {
                Button {
                    model.showInfo(text: text, editor: editor)
                } label: {
                    Label("Document Info", systemImage: "info.circle")
                }
            }
            .overflowPriority(.low)
        }
        if !focusMode {
            // The only way into find without a hardware keyboard (#271)
            ToolbarItem(placement: .secondaryAction) {
                Button("Find", systemImage: "magnifyingglass") {
                    editor.presentFind(showingReplace: false)
                }
            }
            .overflowPriority(.low)
            ToolbarItem(placement: .secondaryAction) {
                Button("Find and Replace", systemImage: "text.magnifyingglass") {
                    editor.presentFind(showingReplace: true)
                }
            }
            .overflowPriority(.low)
        }
        ToolbarItem(placement: .secondaryAction) {
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
                if let partnerPaused, partnerMode != .off {
                    Toggle("Pause Writing Partner", systemImage: "pause.circle", isOn: partnerPaused)
                }
                Button("Writing Partner Edits", systemImage: "square.3.layers.3d") {
                    model.showingPartnerEdits = true
                }
                if let distractionFree {
                    Divider()
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            distractionFree.wrappedValue.toggle()
                        }
                    } label: {
                        Label(
                            distractionFree.wrappedValue ? "Exit Distraction-Free Writing" : "Distraction-Free Writing",
                            systemImage: distractionFree.wrappedValue ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right"
                        )
                    }
                }
            } label: {
                Label("Writing", systemImage: "viewfinder")
            }
        }
        .overflowPriority(.low)
    }
}

/// How readily a toolbar item gives way when the bar runs out of room (#65). Most needed on the
/// iPhone Duo's short outer display, where bars turn vertical and the keyboard takes space.
enum ToolbarOverflowPriority {
    case high, low
}

extension ToolbarContent {
    /// `visibilityPriority(_:)` where available (iOS 27); earlier systems keep the default order.
    @ToolbarContentBuilder
    func overflowPriority(_ priority: ToolbarOverflowPriority) -> some ToolbarContent {
        if #available(iOS 27.0, *) {
            visibilityPriority(priority == .high ? .high : .low)
        } else {
            self
        }
    }
}

/// The outline and Document Info sheets, export progress and errors.
struct IOSDocumentFeatures: ViewModifier {
    @Bindable var model: IOSDocumentFeaturesModel
    let text: String
    let editor: IOSEditorController

    func body(content: Content) -> some View {
        content
        .sheet(isPresented: $model.showingOutlineSheet) {
            NavigationStack {
                IOSOutlineList(outline: model.outline, currentIndex: model.currentHeading) { index in
                    model.showingOutlineSheet = false
                    model.choose(index, editor: editor)
                }
                .navigationTitle("Outline")
                .navigationBarTitleDisplayMode(.inline)
                .sheetRootNavigation()
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { model.showingOutlineSheet = false }
                    }
                }
            }
            .presentationDetents([.medium, .large])
        }
        .sheet(isPresented: $model.showingPartnerEdits) {
            WritingPartnerEditsView(load: { editor.partnerLayerEdits() },
                                    revert: { editor.revertPartnerEdits($0) },
                                    onDone: { model.showingPartnerEdits = false })
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

}

/// The sidebar of the iPad split view: the heading outline and, when the document lives in a
/// folder on disk, the sibling Markdown files and full-text search for that folder.
struct IOSOutlineSidebar: View {
    @Bindable var model: IOSDocumentFeaturesModel
    let text: String
    let editor: IOSEditorController
    let isVisible: Bool
    var fileURL: URL? = nil
    var flavor: Binding<MarkdownFlavor>? = nil
    var showInfo: (() -> Void)? = nil
    var showSettings: (() -> Void)? = nil

    enum Mode: String, CaseIterable {
        case outline = "Outline"
        case folder = "Folder"
    }

    @State private var mode: Mode = .outline

    var body: some View {
        Group {
            if mode == .folder, let fileURL {
                IOSFolderSidebarContent(fileURL: fileURL, currentText: text)
            } else {
                IOSOutlineList(outline: model.outline, currentIndex: model.currentHeading) { model.choose($0, editor: editor) }
                    .listStyle(.sidebar)
            }
        }
        .navigationTitle(mode == .folder ? (fileURL?.deletingLastPathComponent().lastPathComponent ?? "Folder") : "Outline")
        .safeAreaInset(edge: .top, spacing: 0) {
            if fileURL != nil {
                Picker("Sidebar", selection: $mode) {
                    ForEach(Mode.allCases, id: \.self) { item in
                        Text(item.rawValue).tag(item)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            sidebarFooter
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(mode.rawValue)
        .task(id: isVisible ? text : nil) {
            guard isVisible else { return }
            try? await Task.sleep(for: .milliseconds(model.outline.headings.isEmpty ? 0 : 300))
            guard !Task.isCancelled else { return }
            model.refreshOutline(text: text, editor: editor)
        }
    }

    @ViewBuilder
    private var sidebarFooter: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: 16) {
                if let flavor {
                    Menu {
                        Picker("Markdown Flavor", selection: flavor) {
                            ForEach(MarkdownFlavor.allCases) { item in
                                Text(item.rawValue).tag(item)
                            }
                        }
                        .pickerStyle(.inline)
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "textformat")
                            Text(flavor.wrappedValue.rawValue)
                        }
                        .font(.subheadline)
                    }
                    .accessibilityLabel("Markdown Flavor")
                    .accessibilityValue(flavor.wrappedValue.rawValue)
                }
                Spacer()
                HStack(spacing: 16) {
                    Button {
                        if let showInfo {
                            showInfo()
                        } else {
                            model.showInfo(text: text, editor: editor)
                        }
                    } label: {
                        Label("Document Info", systemImage: "info.circle")
                    }
                    Button {
                        showSettings?()
                    } label: {
                        Label("Settings", systemImage: "gearshape")
                    }
                }
                .labelStyle(.iconOnly)
            }
            .font(.body)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(.bar)
        }
    }
}

/// Lists and searches the Markdown files in `fileURL`'s containing folder on iPad.
struct IOSFolderSidebarContent: View {
    let fileURL: URL
    let currentText: String

    @ObservedObject private var folderAccessManager = FolderAccessManager.shared
    @State private var scan = FolderScan()
    @State private var hasAccess = false
    @State private var query = ""
    @State private var searchInText = false
    @State private var searchResults: [FolderSearchMatch] = []

    private var folderURL: URL {
        fileURL.deletingLastPathComponent().standardizedFileURL
    }

    private var trimmedQuery: String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        Group {
            if !hasAccess {
                ContentUnavailableView {
                    Label("Allow Folder Access", systemImage: "folder.badge.questionmark")
                } description: {
                    Text("Allow access to “\(folderURL.lastPathComponent)” to browse and search sibling Markdown notes.")
                } actions: {
                    Button("Allow…") {
                        FolderAccessManager.shared.promptForAccess(to: folderURL) { granted in
                            if granted { reloadFolder() }
                        }
                    }
                    .buttonStyle(.borderedProminent)
                }
            } else if searchInText && !trimmedQuery.isEmpty {
                searchList
            } else {
                fileList
            }
        }
        .searchable(text: $query, prompt: searchInText ? "Search in Notes" : "Filter Files")
        .toolbar {
            if hasAccess {
                ToolbarItem(placement: .primaryAction) {
                    Toggle(isOn: $searchInText) {
                        Label("Search in Notes", systemImage: "doc.text.magnifyingglass")
                    }
                }
            }
        }
        .onAppear { reloadFolder() }
        .onChange(of: fileURL) { _, _ in reloadFolder() }
        .onChange(of: folderAccessManager.accessGrantedTrigger) { _, _ in reloadFolder() }
        .onChange(of: query) { _, _ in runSearchIfNeeded() }
        .onChange(of: searchInText) { _, _ in runSearchIfNeeded() }
    }

    private var fileList: some View {
        let filtered = trimmedQuery.isEmpty ? scan.files : scan.files.filter {
            FolderScanner.relativePath(of: $0, in: folderURL).localizedStandardContains(trimmedQuery)
        }
        return Group {
            if filtered.isEmpty {
                ContentUnavailableView(trimmedQuery.isEmpty ? "No Markdown Files" : "No Matching Files",
                                       systemImage: "doc.text")
            } else {
                List {
                    ForEach(filtered, id: \.self) { url in
                        let isCurrent = url.standardizedFileURL == fileURL.standardizedFileURL
                        Button {
                            if !isCurrent { DocumentOpener.open(url) }
                        } label: {
                            Label(FolderScanner.relativePath(of: url, in: folderURL), systemImage: "doc.text")
                                .fontWeight(isCurrent ? .semibold : .regular)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .listRowBackground(isCurrent ? Color.accentColor.opacity(0.15) : nil)
                        .accessibilityAddTraits(isCurrent ? .isSelected : [])
                    }
                }
                .listStyle(.sidebar)
            }
        }
    }

    private var searchList: some View {
        Group {
            if searchResults.isEmpty {
                ContentUnavailableView.search(text: trimmedQuery)
            } else {
                List(searchResults) { match in
                    Button {
                        DocumentOpener.open(match.file)
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(FolderScanner.relativePath(of: match.file, in: folderURL))
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                            Text(match.snippet)
                                .font(.subheadline)
                                .lineLimit(2)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                .listStyle(.sidebar)
            }
        }
    }

    private func reloadFolder() {
        _ = FolderAccessManager.shared.ensureAccess(for: folderURL)
        let readable = (try? FileManager.default.contentsOfDirectory(atPath: folderURL.path)) != nil
        hasAccess = readable
        guard readable else {
            scan = FolderScan()
            searchResults = []
            return
        }
        scan = FolderScanner.scan(folderURL)
        runSearchIfNeeded()
    }

    private func runSearchIfNeeded() {
        guard hasAccess, searchInText, !trimmedQuery.isEmpty else {
            searchResults = []
            return
        }
        searchResults = FolderSearch.search(
            trimmedQuery,
            in: scan.files,
            texts: [fileURL.standardizedFileURL: currentText]
        )
    }
}

extension View {
    /// For the root view of a sheet's `NavigationStack`. The document scene's back (close) button
    /// carries into sheets presented from the document, so without this a chevron appeared beside
    /// the title that only dismissed the sheet, a second Done (#84).
    func sheetRootNavigation() -> some View {
        navigationBarBackButtonHidden(true)
    }
}

// MARK: - Previews

#Preview("iOS Typography Settings") {
    Form {
        IOSTypographySettingsSections()
    }
}

#Preview("iOS Outline - Populated") {
    IOSOutlineList(
        outline: MarkdownOutline(text: """
            # Swash iOS
            ## Introduction
            ### Navigation
            ## Settings
            """),
        currentIndex: 1,
        select: { _ in }
    )
}

#Preview("iOS Outline - Empty") {
    IOSOutlineList(
        outline: MarkdownOutline(text: ""),
        currentIndex: nil,
        select: { _ in }
    )
}

#Preview("iOS Outline Sidebar") {
    @Previewable @State var model = IOSDocumentFeaturesModel()
    @Previewable @State var flavor = MarkdownFlavor.github
    NavigationStack {
        IOSOutlineSidebar(
            model: model,
            text: """
            # Swash iOS
            ## Introduction
            ### Navigation
            ## Settings
            """,
            editor: IOSEditorController(),
            isVisible: true,
            flavor: $flavor,
            showInfo: {},
            showSettings: {}
        )
    }
}

#Preview("iOS Document Info") {
    IOSDocumentInfoView(
        title: "Document Info",
        document: MarkdownStatistics(text: SwashSampleDocument.standard.text),
        selection: nil,
        headings: 5
    )
}
#endif

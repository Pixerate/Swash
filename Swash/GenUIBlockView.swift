//
//  GenUIBlockView.swift
//  Swash
//
//  Hybrid GenUI renderer: native SwiftUI views for built-in @pixerate/schemas/genui
//  declarative blocks, plus a permission-gated sandboxed WKWebView host for custom
//  agent-supplied widgets (e.g. 3D charts).
//

import SwiftUI
import WebKit

struct GenUIBlockView: View {
    let block: GenUIParsedBlock
    var documentKey: String = "untitled"

    var body: some View {
        switch block {
        case .stats(let data):
            GenUIStatsView(data: data)
        case .callout(let data):
            GenUICalloutView(data: data)
        case .actions(let data):
            GenUIActionsView(data: data)
        case .chart(let data):
            GenUIChartView(data: data)
        case .tree(let data):
            GenUITreeView(data: data)
        case .orgchart(let data):
            GenUIOrgChartView(data: data)
        case .proposals(let data):
            GenUIProposalsView(data: data)
        case .form(let data):
            GenUIFormView(data: data)
        case .widget(let data):
            SandboxedWidgetView(data: data, documentKey: documentKey)
        }
    }
}

// MARK: - Built-in Native Catalog

private struct GenUIStatsView: View {
    let data: GenUIStatsBlock

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let title = data.title, !title.isEmpty {
                Text(title)
                    .font(.headline)
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 130), spacing: 10)], spacing: 10) {
                ForEach(Array(data.items.enumerated()), id: \.offset) { _, item in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(item.label)
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Text(item.value)
                            .font(.title3.bold())
                        if let change = item.change, !change.isEmpty {
                            HStack(spacing: 3) {
                                if item.trend == "up" {
                                    Image(systemName: "arrow.up.right")
                                } else if item.trend == "down" {
                                    Image(systemName: "arrow.down.right")
                                }
                                Text(change)
                            }
                            .font(.caption2.weight(.medium))
                            .foregroundColor(trendColor(item.trend))
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .background(Color.secondary.opacity(0.08))
                    .cornerRadius(8)
                }
            }
        }
        .padding(12)
        .background(Color.secondary.opacity(0.05))
        .cornerRadius(10)
    }

    private func trendColor(_ trend: String?) -> Color {
        switch trend {
        case "up": return .green
        case "down": return .red
        default: return .secondary
        }
    }
}

private struct GenUICalloutView: View {
    let data: GenUICalloutBlock

    private var accentColor: Color {
        switch data.effectiveSeverity {
        case "warning": return .orange
        case "error", "danger", "caution": return .red
        case "success", "tip": return .green
        default: return .blue
        }
    }

    private var iconName: String {
        switch data.effectiveSeverity {
        case "warning": return "exclamationmark.triangle.fill"
        case "error", "danger", "caution": return "xmark.octagon.fill"
        case "success", "tip": return "checkmark.circle.fill"
        default: return "info.circle.fill"
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: iconName)
                .foregroundColor(accentColor)
                .font(.body.weight(.semibold))
            VStack(alignment: .leading, spacing: 4) {
                Text(data.title)
                    .font(.subheadline.weight(.semibold))
                if let body = data.effectiveBody, !body.isEmpty {
                    Text(body)
                        .font(.callout)
                        .foregroundColor(.secondary)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(accentColor.opacity(0.08))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(accentColor.opacity(0.25), lineWidth: 1)
        )
        .cornerRadius(8)
    }
}

private struct GenUIActionsView: View {
    let data: GenUIActionsBlock
    @State private var selectedID: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let title = data.title, !title.isEmpty {
                Text(title)
                    .font(.subheadline.weight(.semibold))
            }
            HStack(spacing: 8) {
                ForEach(data.actions, id: \.id) { action in
                    Button {
                        selectedID = action.id
                    } label: {
                        Text(action.label)
                            .font(.callout.weight(.medium))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(buttonBackground(for: action))
                            .foregroundColor(buttonForeground(for: action))
                            .cornerRadius(6)
                    }
                    .buttonStyle(.plain)
                }
            }
            if let selectedID {
                Text("Selected: \(selectedID)")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Color.secondary.opacity(0.06))
        .cornerRadius(8)
    }

    private func buttonBackground(for action: GenUIActionItem) -> Color {
        if selectedID == action.id { return .accentColor }
        switch action.variant {
        case "primary": return .accentColor.opacity(0.9)
        case "destructive": return .red.opacity(0.85)
        default: return Color.secondary.opacity(0.15)
        }
    }

    private func buttonForeground(for action: GenUIActionItem) -> Color {
        if selectedID == action.id || action.variant == "primary" || action.variant == "destructive" {
            return .white
        }
        return .primary
    }
}

private struct GenUIChartView: View {
    let data: GenUIChartBlock

    private var maxValue: Double {
        max(data.series.flatMap(\.data).max() ?? 1, 1)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let title = data.title, !title.isEmpty {
                Text(title)
                    .font(.headline)
            }
            let categories = data.categories ?? []
            ForEach(Array(data.series.enumerated()), id: \.offset) { seriesIdx, series in
                VStack(alignment: .leading, spacing: 6) {
                    if data.series.count > 1 {
                        Text(series.name)
                            .font(.caption.weight(.semibold))
                            .foregroundColor(.secondary)
                    }
                    ForEach(Array(series.data.enumerated()), id: \.offset) { idx, value in
                        let label = idx < categories.count ? categories[idx] : "#\(idx + 1)"
                        HStack(spacing: 8) {
                            Text(label)
                                .font(.caption)
                                .frame(width: 72, alignment: .leading)
                                .lineLimit(1)
                            GeometryReader { geo in
                                RoundedRectangle(cornerRadius: 4)
                                    .fill(seriesIdx == 0 ? Color.accentColor : Color.secondary)
                                    .frame(width: max(4, geo.size.width * CGFloat(value / maxValue)))
                            }
                            .frame(height: 14)
                            Text("\(value, specifier: "%.4g")\(data.unit ?? "")")
                                .font(.caption.monospacedDigit())
                                .foregroundColor(.secondary)
                        }
                    }
                }
            }
        }
        .padding(12)
        .background(Color.secondary.opacity(0.06))
        .cornerRadius(10)
    }
}

private struct GenUITreeView: View {
    let data: GenUITreeBlock

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let title = data.title, !title.isEmpty {
                Text(title).font(.headline)
            }
            ForEach(data.nodes, id: \.id) { node in
                HStack(spacing: 8) {
                    Image(systemName: node.parentId == nil ? "circle.fill" : "arrow.turn.down.right")
                        .font(.caption)
                        .foregroundColor(.accentColor)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(node.label).font(.callout.weight(.medium))
                        if let detail = node.detail, !detail.isEmpty {
                            Text(detail).font(.caption).foregroundColor(.secondary)
                        }
                    }
                }
                .padding(.leading, node.parentId == nil ? 0 : 16)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Color.secondary.opacity(0.06))
        .cornerRadius(8)
    }
}

private struct GenUIOrgChartView: View {
    let data: GenUIOrgChartBlock

    private var people: [GenUIOrgChartPerson] {
        var list: [GenUIOrgChartPerson] = []
        if let root = data.root { list.append(root) }
        if let more = data.people { list.append(contentsOf: more) }
        return list
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let title = data.title, !title.isEmpty {
                Text(title).font(.headline)
            }
            ForEach(Array(people.enumerated()), id: \.offset) { _, person in
                HStack(spacing: 8) {
                    Image(systemName: "person.crop.circle")
                        .foregroundColor(.accentColor)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(person.name).font(.callout.weight(.medium))
                        if let role = person.role ?? person.title, !role.isEmpty {
                            Text(role).font(.caption).foregroundColor(.secondary)
                        }
                    }
                }
                .padding(.leading, person.managerId == nil ? 0 : 16)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Color.secondary.opacity(0.06))
        .cornerRadius(8)
    }
}

private struct GenUIProposalsView: View {
    let data: GenUIProposalsBlock
    @State private var chosenTitle: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let title = data.title, !title.isEmpty {
                Text(title).font(.headline)
            }
            ForEach(Array(data.effectiveItems.enumerated()), id: \.offset) { _, item in
                Button {
                    chosenTitle = item.title
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(item.title).font(.callout.weight(.semibold))
                            if item.recommended == true {
                                Text("Recommended")
                                    .font(.caption2.weight(.semibold))
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(Color.accentColor.opacity(0.15))
                                    .foregroundColor(.accentColor)
                                    .cornerRadius(4)
                            }
                            Spacer()
                        }
                        if let summary = item.summary ?? item.description, !summary.isEmpty {
                            Text(summary)
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(chosenTitle == item.title ? Color.accentColor.opacity(0.12) : Color.secondary.opacity(0.06))
                    .cornerRadius(8)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(12)
        .background(Color.secondary.opacity(0.04))
        .cornerRadius(10)
    }
}

private struct GenUIFormView: View {
    let data: GenUIFormBlock
    @State private var answers: [String: String] = [:]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let title = data.title, !title.isEmpty {
                Text(title).font(.headline)
            }
            if let desc = data.description, !desc.isEmpty {
                Text(desc).font(.caption).foregroundColor(.secondary)
            }
            ForEach(data.effectiveQuestions, id: \.id) { question in
                VStack(alignment: .leading, spacing: 4) {
                    Text(question.effectiveLabel)
                        .font(.callout.weight(.medium))
                    if let options = question.options, !options.isEmpty {
                        Picker(question.effectiveLabel, selection: binding(for: question.id, default: options.first ?? "")) {
                            ForEach(options, id: \.self) { option in
                                Text(option).tag(option)
                            }
                        }
                        .labelsHidden()
                    } else {
                        TextField(question.placeholder ?? "Enter response…", text: binding(for: question.id, default: ""))
                            .textFieldStyle(.roundedBorder)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Color.secondary.opacity(0.06))
        .cornerRadius(10)
    }

    private func binding(for id: String, default fallback: String) -> Binding<String> {
        Binding(
            get: { answers[id] ?? fallback },
            set: { answers[id] = $0 }
        )
    }
}

// MARK: - Permission-Gated Sandboxed Widget Host

struct SandboxedWidgetView: View {
    let data: GenUICustomWidgetBlock
    let documentKey: String
    @ObservedObject private var trustManager = WidgetTrustManager.shared

    private var widgetHeight: CGFloat {
        CGFloat(min(max(data.height ?? 280, 120), 720))
    }

    var body: some View {
        if trustManager.isTrusted(documentKey: documentKey) {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Label(data.title ?? "Interactive Widget", systemImage: "cube.transparent")
                        .font(.caption.weight(.semibold))
                        .foregroundColor(.secondary)
                    Spacer()
                    Button("Revoke Trust") {
                        trustManager.revokeTrust(for: documentKey)
                    }
                    .font(.caption)
                    .buttonStyle(.borderless)
                }
                SandboxedWidgetWebView(html: composedHTML)
                    .frame(height: widgetHeight)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(Color.secondary.opacity(0.2), lineWidth: 1)
                    )
            }
            .padding(10)
            .background(Color.secondary.opacity(0.04))
            .cornerRadius(10)
        } else {
            HStack(spacing: 12) {
                Image(systemName: "shield.lefthalf.filled")
                    .font(.title2)
                    .foregroundColor(.orange)
                VStack(alignment: .leading, spacing: 3) {
                    Text(data.title ?? "Interactive Widget Blocked")
                        .font(.subheadline.weight(.semibold))
                    Text(trustManager.canGrantTrust(for: documentKey)
                         ? "Custom HTML/JS widgets require your permission before running in this document."
                         : "Save this document to allow its custom HTML/JS widgets to run.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                Spacer()
                if trustManager.canGrantTrust(for: documentKey) {
                    Button("Allow Widgets") {
                        trustManager.grantTrust(for: documentKey)
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
            .padding(12)
            .background(Color.orange.opacity(0.08))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color.orange.opacity(0.3), lineWidth: 1)
            )
            .cornerRadius(8)
        }
    }

    private var composedHTML: String {
        let bodyHTML = data.html ?? "<div id=\"app\"></div>"
        let scriptTag = data.script.map { "<script>\($0)</script>" } ?? ""
        return """
        <!DOCTYPE html>
        <html>
        <head>
        <meta charset="utf-8">
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; img-src data:;">
        <style>html, body { margin: 0; padding: 8px; font-family: -apple-system, sans-serif; background: transparent; }</style>
        </head>
        <body>\(bodyHTML)\(scriptTag)</body>
        </html>
        """
    }
}


/// A widget's web view: no persistent storage or cookies, and no navigation. The widget's HTML is
/// loaded once; links, forms, `location` changes, meta refresh and `window.open` are refused (CSP
/// doesn't cover navigation, so without this a widget could load any site or send its data out
/// in a URL).
private enum WidgetWebViewSupport {
    @MainActor
    static func makeWebView(navigationDelegate: WKNavigationDelegate) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.defaultWebpagePreferences.allowsContentJavaScript = true
        config.preferences.javaScriptCanOpenWindowsAutomatically = false
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = navigationDelegate
        return webView
    }

    /// Only the initial `loadHTMLString` (about:blank, triggered by the app) is allowed.
    @MainActor
    static func allows(_ action: WKNavigationAction) -> Bool {
        action.navigationType == .other
            && action.targetFrame?.isMainFrame == true
            && action.request.url?.absoluteString == "about:blank"
    }
}

final class WidgetNavigationLock: NSObject, WKNavigationDelegate {
    var lastHTML: String
    init(lastHTML: String) { self.lastHTML = lastHTML }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void) {
        decisionHandler(WidgetWebViewSupport.allows(navigationAction) ? .allow : .cancel)
    }
}

#if os(macOS)
private struct SandboxedWidgetWebView: NSViewRepresentable {
    let html: String

    func makeNSView(context: Context) -> WKWebView {
        let webView = WidgetWebViewSupport.makeWebView(navigationDelegate: context.coordinator)
        webView.setValue(false, forKey: "drawsBackground")
        webView.loadHTMLString(html, baseURL: nil)
        return webView
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {
        if context.coordinator.lastHTML != html {
            context.coordinator.lastHTML = html
            nsView.loadHTMLString(html, baseURL: nil)
        }
    }

    func makeCoordinator() -> WidgetNavigationLock { WidgetNavigationLock(lastHTML: html) }
}
#else
private struct SandboxedWidgetWebView: UIViewRepresentable {
    let html: String

    func makeUIView(context: Context) -> WKWebView {
        let webView = WidgetWebViewSupport.makeWebView(navigationDelegate: context.coordinator)
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.loadHTMLString(html, baseURL: nil)
        return webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {
        if context.coordinator.lastHTML != html {
            context.coordinator.lastHTML = html
            uiView.loadHTMLString(html, baseURL: nil)
        }
    }

    func makeCoordinator() -> WidgetNavigationLock { WidgetNavigationLock(lastHTML: html) }
}
#endif

// MARK: - Previews

#Preview("Stats & Callout") {
    VStack(spacing: 12) {
        GenUIBlockView(block: .stats(GenUIStatsBlock(
            title: "Performance",
            items: [
                GenUIStatItem(label: "Active Users", value: "12,450", change: "+14%", trend: "up"),
                GenUIStatItem(label: "Error Rate", value: "0.02%", change: "-0.01%", trend: "down")
            ]
        )))
        GenUIBlockView(block: .callout(GenUICalloutBlock(
            severity: "warning",
            type: nil,
            title: "Permission Required",
            body: "Sandboxed widgets stay gated until approved.",
            message: nil
        )))
    }
    .padding()
    .frame(width: 480)
}

#Preview("GenUI - Actions") {
    GenUIActionsView(data: GenUIActionsBlock(
        title: "Quick Actions",
        actions: [
            GenUIActionItem(id: "run", label: "Run Pipeline", variant: "primary", description: nil),
            GenUIActionItem(id: "cancel", label: "Cancel", variant: "destructive", description: nil)
        ]
    ))
    .padding()
    .frame(width: 400)
}

#Preview("GenUI - Chart") {
    GenUIChartView(data: GenUIChartBlock(
        chartType: "bar",
        title: "Weekly Revenue",
        unit: "$",
        categories: ["Mon", "Tue", "Wed", "Thu", "Fri"],
        series: [
            GenUIChartSeries(name: "Revenue", data: [120, 200, 150, 310, 280], color: nil)
        ]
    ))
    .padding()
    .frame(width: 400)
}

#Preview("GenUI - Tree") {
    GenUITreeView(data: GenUITreeBlock(
        title: "File Hierarchy",
        nodes: [
            GenUITreeNode(id: "root", label: "Project", detail: nil, parentId: nil),
            GenUITreeNode(id: "src", label: "Sources", detail: nil, parentId: "root"),
            GenUITreeNode(id: "file1", label: "ContentView.swift", detail: "Swift", parentId: "src")
        ]
    ))
    .padding()
    .frame(width: 400)
}

#Preview("GenUI - Sandboxed Widget") {
    SandboxedWidgetView(
        data: GenUICustomWidgetBlock(
            title: "Interactive Counter",
            height: 120,
            html: "<html><body><h3 style='color:blue;'>Widget Content</h3><p>Hello from sandboxed HTML!</p></body></html>",
            script: nil
        ),
        documentKey: "preview-doc"
    )
    .padding()
    .frame(width: 400)
}


#if os(macOS)
// MARK: - NSTextAttachment & Cell for Edit Text Mode

final class GenUIAttachmentCell: NSTextAttachmentCell {
    var hostingView: NSHostingView<GenUIBlockView>?
    let block: GenUIParsedBlock
    let documentKey: String
    private var measured: (width: CGFloat, height: CGFloat)?

    init(block: GenUIParsedBlock, documentKey: String) {
        self.block = block
        self.documentKey = documentKey
        super.init(textCell: "")
    }

    required init(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    nonisolated override func cellFrame(for textContainer: NSTextContainer, proposedLineFragment lineFrag: NSRect, glyphPosition position: CGPoint, characterIndex charIndex: Int) -> NSRect {
        let width = lineFrag.width > 0 ? lineFrag.width : 500
        let height = MainActor.assumeIsolated { self.height(forWidth: width) }
        return NSRect(x: 0, y: 0, width: width, height: height)
    }

    @MainActor private func height(forWidth width: CGFloat) -> CGFloat {
        if let measured, measured.width == width { return measured.height }
        let view = makeHostingView()
        view.frame.size.width = width
        let height = ceil(max(52, view.fittingSize.height))
        measured = (width, height)
        return height
    }

    @MainActor private func makeHostingView() -> NSHostingView<GenUIBlockView> {
        if let hv = hostingView { return hv }
        let hv = NSHostingView(rootView: GenUIBlockView(block: block, documentKey: documentKey))
        hostingView = hv
        return hv
    }

    nonisolated override func draw(withFrame cellFrame: NSRect, in controlView: NSView?) {
        guard let parentView = controlView as? NSTextView else { return }
        MainActor.assumeIsolated {
            let hv = self.makeHostingView()
            if hv.superview != parentView {
                parentView.addSubview(hv, positioned: .above, relativeTo: nil)
            }
            if hv.frame != cellFrame {
                hv.frame = cellFrame
            }
        }
    }
}

final class GenUITextAttachment: NSTextAttachment, RawMarkdownAttachment {
    static let fileTypeIdentifier = "com.pixerate.swash.genui"

    let block: GenUIParsedBlock
    let rawMarkdown: String
    let cell: GenUIAttachmentCell

    init(block: GenUIParsedBlock, documentKey: String, rawMarkdown: String) {
        self.block = block
        self.rawMarkdown = rawMarkdown
        let cell = GenUIAttachmentCell(block: block, documentKey: documentKey)
        self.cell = cell
        super.init(data: nil, ofType: Self.fileTypeIdentifier)
        self.attachmentCell = cell
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}
#endif

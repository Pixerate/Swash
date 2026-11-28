import PixerateMarkdown
@testable import Swash
import SwiftUI
import UIKit
import XCTest

@MainActor
final class PreviewSnapshotTests: XCTestCase {
    private struct PreviewCase {
        let name: String
        let style: UIUserInterfaceStyle
        let size: CGSize
        let makeView: () -> AnyView

        init(
            name: String,
            style: UIUserInterfaceStyle,
            size: CGSize = CGSize(width: 393, height: 852),
            makeView: @escaping () -> AnyView
        ) {
            self.name = name
            self.style = style
            self.size = size
            self.makeView = makeView
        }
    }

    /// Tasks, nested bullets, numbers and empty items at the end, for the editor's list markers.
    private static let listMarkdown = "## Today\n\n- [ ] Buy milk\n- [x] Water the plants\n- Bullet\n  - Nested\n    - Deeper\n1. First\n2. Second\n- [ ] "

    func testRenderSwiftUIPreviews() async throws {
        let exportDir = ProcessInfo.processInfo.environment["SWASH_PREVIEW_EXPORT_DIR"]
            .flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0, isDirectory: true) }

        if let exportDir {
            try FileManager.default.createDirectory(at: exportDir, withIntermediateDirectories: true)
        }

        let formatEntries = FormatManifestLayout.formatPanelEntries
        let sampleMarkdown = "# Swash\n\nA fast Markdown editor for Mac, iPad, and iPhone.\n\n## Getting Started\n\n### Formatting\n\n## Export"
        let sampleOutline = MarkdownOutline(text: sampleMarkdown)
        let emptyOutline = MarkdownOutline(text: "")
        let sampleStats = MarkdownStatistics(text: sampleMarkdown)
        let sampleSelectionStats = MarkdownStatistics(text: "A fast Markdown editor for Mac, iPad, and iPhone.")

        let cases: [PreviewCase] = [
            PreviewCase(name: "iOS-Settings-Light", style: .light) {
                AnyView(IOSSettingsView())
            },
            PreviewCase(name: "iOS-Settings-Dark", style: .dark) {
                AnyView(IOSSettingsView())
            },
            PreviewCase(name: "iOS-FormatPanel-Light", style: .light, size: CGSize(width: 393, height: 260)) {
                AnyView(FormatPanel(entries: formatEntries, apply: { _ in }, close: {}))
            },
            PreviewCase(name: "iOS-FormatPanel-Dark", style: .dark, size: CGSize(width: 393, height: 260)) {
                AnyView(FormatPanel(entries: formatEntries, apply: { _ in }, close: {}))
            },
            PreviewCase(name: "iOS-InsertPanel-Light", style: .light, size: CGSize(width: 393, height: 260)) {
                AnyView(InsertPanelView(onSelect: { _ in }, close: {}))
            },
            PreviewCase(name: "iOS-InsertPanel-Dark", style: .dark, size: CGSize(width: 393, height: 260)) {
                AnyView(InsertPanelView(onSelect: { _ in }, close: {}))
            },
            PreviewCase(name: "iOS-OutlineList-Light", style: .light) {
                AnyView(
                    NavigationStack {
                        IOSOutlineList(outline: sampleOutline, currentIndex: 1, select: { _ in })
                            .navigationTitle("Outline")
                    }
                )
            },
            PreviewCase(name: "iOS-OutlineList-Empty-Light", style: .light) {
                AnyView(
                    NavigationStack {
                        IOSOutlineList(outline: emptyOutline, currentIndex: nil, select: { _ in })
                            .navigationTitle("Outline")
                    }
                )
            },
            // List markers are SF Symbols: Reminders-style circles and the system's bullets (#184)
            PreviewCase(name: "iOS-EditorLists-Light", style: .light, size: CGSize(width: 393, height: 420)) {
                AnyView(StyledTextView(text: .constant(Self.listMarkdown), controller: IOSEditorController(), flavor: .github, baseURL: nil))
            },
            PreviewCase(name: "iOS-EditorLists-Dark", style: .dark, size: CGSize(width: 393, height: 420)) {
                AnyView(StyledTextView(text: .constant(Self.listMarkdown), controller: IOSEditorController(), flavor: .github, baseURL: nil))
            },
            PreviewCase(name: "iOS-DocumentInfo-Light", style: .light) {
                AnyView(
                    IOSDocumentInfoView(
                        title: "Sample.md",
                        document: sampleStats,
                        selection: sampleSelectionStats,
                        headings: sampleOutline.headings.count
                    )
                )
            },
        ]

        for entry in cases {
            let png = try await renderToPNG(view: entry.makeView(), style: entry.style, size: entry.size)
            XCTAssertGreaterThan(png.count, 0, "Empty PNG for \(entry.name)")

            if let exportDir {
                let fileURL = exportDir.appendingPathComponent("\(entry.name).png")
                try png.write(to: fileURL, options: .atomic)
            }
        }
    }

    private func renderToPNG(
        view: AnyView,
        style: UIUserInterfaceStyle,
        size: CGSize = CGSize(width: 393, height: 852)
    ) async throws -> Data {
        let scene = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first
        let window: UIWindow
        if let scene {
            window = UIWindow(windowScene: scene)
            window.frame = CGRect(origin: .zero, size: size)
        } else {
            window = UIWindow(frame: CGRect(origin: .zero, size: size))
        }
        window.overrideUserInterfaceStyle = style

        let host = UIHostingController(rootView: view)
        host.view.frame = window.bounds
        window.rootViewController = host
        window.makeKeyAndVisible()

        try await Task.sleep(for: .milliseconds(350))
        host.view.setNeedsLayout()
        host.view.layoutIfNeeded()

        let renderer = UIGraphicsImageRenderer(bounds: window.bounds)
        let image = renderer.image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }

        host.willMove(toParent: nil)
        window.rootViewController = nil
        window.isHidden = true

        guard let data = image.pngData() else {
            throw NSError(domain: "PreviewSnapshotTests", code: 1, userInfo: [NSLocalizedDescriptionKey: "Failed to encode PNG"])
        }
        return data
    }
}

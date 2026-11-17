@testable import Swash
import SwiftUI
import UIKit
import XCTest

@MainActor
final class PreviewSnapshotTests: XCTestCase {
    private struct PreviewCase {
        let name: String
        let style: UIUserInterfaceStyle
        let makeView: () -> AnyView
    }

    func testRenderSwiftUIPreviews() async throws {
        let exportDir = ProcessInfo.processInfo.environment["SWASH_PREVIEW_EXPORT_DIR"]
            .flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0, isDirectory: true) }

        if let exportDir {
            try FileManager.default.createDirectory(at: exportDir, withIntermediateDirectories: true)
        }

        let cases: [PreviewCase] = [
            PreviewCase(name: "iOS-Settings-Light", style: .light) {
                AnyView(IOSSettingsView())
            },
            PreviewCase(name: "iOS-Settings-Dark", style: .dark) {
                AnyView(IOSSettingsView())
            },
        ]

        for entry in cases {
            let png = try await renderToPNG(view: entry.makeView(), style: entry.style)
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

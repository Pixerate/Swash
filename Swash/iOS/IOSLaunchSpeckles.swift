//
//  IOSLaunchSpeckles.swift
//  Swash
//
//  Faint, twinkling pixel speckles around the wordmark on the iPhone and iPad document manager:
//  Flair's `pixel-speckles` effect (FlairEffects' `PixelSpeckles`), the pixel square from
//  docs/BRAND.md in the neon accent gradient. They keep clear of the wordmark and of Create
//  Document, and hold still under Reduce Motion.
//

#if os(iOS)
import FlairEffects
import SwiftUI
import UIKit

/// The speckles, over the whole view, kept clear of `keepClear` (in the view's own coordinates).
struct SwashLaunchSpeckles: View {
    var keepClear: [CGRect] = []

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        SwashSpecklesCanvas(keepClear: keepClear, still: reduceMotion)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

private struct SwashSpecklesCanvas: UIViewRepresentable {
    let keepClear: [CGRect]
    let still: Bool

    func makeUIView(context: Context) -> SwashSpecklesCanvasView { SwashSpecklesCanvasView() }

    func updateUIView(_ view: SwashSpecklesCanvasView, context: Context) {
        view.keepClear = keepClear
        view.isStill = still
    }
}

/// `PixelSpeckles` as the prototype that was chosen drew them: Flair's defaults (its Dark page
/// preset) in both modes, a little denser, with light mode's opacity at 0.18–0.5 (dark's is 1.2 times that) and
/// its gradient ending in the light deep indigo. Flair gives sizes and spacing in frame heights,
/// tuned for a 360pt-high view, so they're scaled to keep the same point sizes at any height; the
/// keep-clear boxes are normalised to the view.
final class SwashSpecklesCanvasView: FlairCanvasView {
    /// The height Flair's presets are tuned for, in points.
    private static let presetHeight: Float = 360

    var keepClear: [CGRect] = [] {
        didSet { if keepClear != oldValue { invalidateEffect() } }
    }

    override func makeEffect(renderer: FlairRenderer) -> AnyFlairEffect? {
        let dark = traitCollection.userInterfaceStyle == .dark
        guard bounds.height > 0 else { return nil }
        var speckles = PixelSpeckles()
        // Flair leaves the grid cells under the keep-clear boxes empty, and here they cover about
        // half the view: smaller cells (43pt on an iPhone), a little fuller, give the prototype's
        // ~26 speckles. On a bigger area (the iPad's launch card) the cells grow with it, so it
        // stays as sparse instead of filling with speckles
        let phoneArea: CGFloat = 402 * 362
        let growth = Float(max(1, (bounds.width * bounds.height / phoneArea).squareRoot()))
        speckles.spacing = 0.12 * growth
        speckles.density = 0.6
        if !dark {
            speckles.minOpacity = 0.18
            speckles.maxOpacity = 0.5
            speckles.color4 = SIMD3(0x43 / 255, 0x38 / 255, 0xCA / 255)
        }
        let scale = Self.presetHeight / Float(bounds.height)
        speckles.spacing *= scale
        speckles.minSize *= scale
        speckles.maxSize *= scale
        speckles.backgroundAlpha = 0
        let boxes = keepClear.prefix(4).map { rect in
            SIMD4<Float>(Float(rect.minX / bounds.width), Float(rect.minY / bounds.height),
                         Float(rect.width / bounds.width), Float(rect.height / bounds.height))
        }
        let unused = SIMD4<Float>(0, 0, 0, 0)
        speckles.clear1 = boxes.count > 0 ? boxes[0] : unused
        speckles.clear2 = boxes.count > 1 ? boxes[1] : unused
        speckles.clear3 = boxes.count > 2 ? boxes[2] : unused
        speckles.clear4 = boxes.count > 3 ? boxes[3] : unused
        return AnyFlairEffect(speckles)
    }
}

#Preview("Speckles, light") {
    SwashLaunchSpeckles(keepClear: [CGRect(x: 110, y: 120, width: 180, height: 70)])
        .frame(width: 402, height: 360)
}

#Preview("Speckles, dark") {
    SwashLaunchSpeckles(keepClear: [CGRect(x: 110, y: 120, width: 180, height: 70)])
        .frame(width: 402, height: 360)
        .background(Color(uiColor: .systemBackground))
        .environment(\.colorScheme, .dark)
}
#endif

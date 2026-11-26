//
//  IOSSwashWordmark.swift
//  Swash
//
//  The "Swash" wordmark on the iPhone and iPad document manager, drawn as the marketing site's
//  hero headline is (site/src/components/SwashHeadline.svelte): New York Bold with tight
//  tracking, and Flair's `swash-text` shader swashing a ribbon through the letters. The plain
//  words show until the shader's first frame, without Metal, and under Reduce Motion, as on the
//  site.
//

#if os(iOS)
import FlairEffects
import MetalKit
import SwiftUI
import UIKit

/// The wordmark's look, shared by the plain text and the shader.
enum SwashWordmarkStyle {
    /// The site's headline is `clamp(3.25rem, 10vw, 7rem)`: 52pt on a phone, scaled with Dynamic Type.
    static let baseSize: CGFloat = 52
    /// Tailwind's `tracking-tight`.
    static let tracking: CGFloat = -0.025
    /// How much of the canvas's height the words take. The rest is room for the ribbon's loop and glow.
    static let textShare: CGFloat = 0.6

    /// The site's `--ink`: #1a1024 in light mode, #f4eefb in dark.
    static let ink = UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0xF4 / 255, green: 0xEE / 255, blue: 0xFB / 255, alpha: 1)
            : UIColor(red: 0x1A / 255, green: 0x10 / 255, blue: 0x24 / 255, alpha: 1)
    }

    static func font(size: CGFloat) -> UIFont {
        let base = UIFont.systemFont(ofSize: size, weight: .bold)
        guard let serif = base.fontDescriptor.withDesign(.serif) else { return base }
        return UIFont(descriptor: serif, size: size)
    }

    static func attributes(size: CGFloat, color: UIColor) -> [NSAttributedString.Key: Any] {
        [.font: font(size: size), .kern: tracking * size, .foregroundColor: color]
    }

    /// The words' own box: their advance width, and the font's ascent plus descent.
    static func textSize(_ text: String, size: CGFloat) -> CGSize {
        let font = font(size: size)
        let width = (text as NSString).size(withAttributes: attributes(size: size, color: .white)).width
        return CGSize(width: ceil(width), height: ceil(font.ascender - font.descender))
    }

    /// The ribbon in each mode, in the app icon's colours, kept quiet: little glow and few sparkles.
    static func effect(dark: Bool, ink: UIColor) -> SwashText {
        var effect = SwashText()
        effect.text = .none
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        ink.getRed(&r, green: &g, blue: &b, alpha: &a)
        effect.ink = SIMD3(Float(r), Float(g), Float(b))
        effect.size = Float(textShare)
        effect.backgroundAlpha = 0
        effect.sparkle = 0.35
        effect.cycle = 8
        effect.tail = SIMD3(1, 0.7, 0.54)
        effect.mid = SIMD3(0.93, 0.42, 1)
        if dark {
            effect.head = SIMD3(0.71, 0.55, 1)
            effect.frostColor = SIMD3(0.73, 0.65, 1)
            effect.glow = 0.4
            effect.opacity = 0.9
        } else {
            effect.head = SIMD3(0.5, 0.13, 1)
            effect.frostColor = SIMD3(0.86, 0.89, 1)
            effect.glow = 0.2
            effect.opacity = 0.8
        }
        return effect
    }
}

/// The wordmark: plain words, with the shader's canvas centred over them once it has drawn.
struct SwashWordmark: View {
    var text = "Swash"
    /// Turns the shader off, as Reduce Motion does; previews use it to show the still wordmark.
    var animated = true

    @ScaledMetric(relativeTo: .largeTitle) private var size = SwashWordmarkStyle.baseSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var shaderShown = false

    private var playing: Bool { animated && !reduceMotion }

    var body: some View {
        let box = SwashWordmarkStyle.textSize(text, size: size)
        Text(text)
            .font(Font(SwashWordmarkStyle.font(size: size)))
            .tracking(SwashWordmarkStyle.tracking * size)
            .foregroundStyle(Color(uiColor: SwashWordmarkStyle.ink))
            .fixedSize()
            .opacity(playing && shaderShown ? 0 : 1)
            .overlay {
                if playing {
                    SwashWordmarkCanvas(text: text, size: size, shown: $shaderShown)
                        .frame(width: box.width / SwashWordmarkStyle.textShare,
                               height: box.height / SwashWordmarkStyle.textShare)
                        .opacity(shaderShown ? 1 : 0)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
            .animation(.easeInOut(duration: 0.5), value: shaderShown)
            .onChange(of: playing) { _, now in if !now { shaderShown = false } }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(text)
            .accessibilityAddTraits(.isHeader)
    }
}

/// The wordmark where the document manager's title was, centred as the site's hero is.
/// `DocumentGroupLaunchScene` lays a blank title out above Create Document; its `titleViewFrame`
/// is the whole area above the browser, in window coordinates, so this ignores the safe area. The
/// system title's baseline sits a little above the area's middle.
struct SwashLaunchWordmark: View {
    let titleViewFrame: CGRect

    @ScaledMetric(relativeTo: .largeTitle) private var baselineLift: CGFloat = 10
    @ScaledMetric(relativeTo: .largeTitle) private var size = SwashWordmarkStyle.baseSize

    var body: some View {
        let ascender = SwashWordmarkStyle.font(size: size).ascender
        SwashWordmark()
            .frame(width: titleViewFrame.width)
            .offset(x: titleViewFrame.minX, y: titleViewFrame.midY - baselineLift - ascender)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .ignoresSafeArea()
            .allowsHitTesting(false)
    }
}

private struct SwashWordmarkCanvas: UIViewRepresentable {
    let text: String
    let size: CGFloat
    @Binding var shown: Bool

    func makeUIView(context: Context) -> SwashWordmarkCanvasView {
        let view = SwashWordmarkCanvasView()
        view.onFirstFrame = { shown = true }
        return view
    }

    func updateUIView(_ view: SwashWordmarkCanvasView, context: Context) {
        view.onFirstFrame = { shown = true }
        view.configure(text: text, size: size)
    }
}

/// Calls back to a target it doesn't keep alive, so a `CADisplayLink` doesn't keep its view.
private final class SwashWordmarkFrameProxy: NSObject {
    weak var target: SwashWordmarkCanvasView?

    init(_ target: SwashWordmarkCanvasView) { self.target = target }

    @objc func tick(_ link: CADisplayLink) {
        guard let target else { link.invalidate(); return }
        target.drawFrame()
    }
}

/// An `MTKView` drawing `SwashText` once a frame. The words are a texture made once per text, size
/// and appearance and bound as the shader's live `uText`, rather than an image input, which the
/// renderer would upload again every frame.
final class SwashWordmarkCanvasView: MTKView {
    var onFirstFrame: (() -> Void)?

    private let renderer: FlairRenderer?
    private var effect: AnyFlairEffect?
    private var text = ""
    private var size: CGFloat = 0
    private var link: CADisplayLink?
    private let start = CACurrentMediaTime()
    private var last: CFTimeInterval = 0
    private var frameCount: Int32 = 0
    private var drewFirstFrame = false

    init() {
        let device = MTLCreateSystemDefaultDevice()
        renderer = try? FlairRenderer(device: device)
        super.init(frame: .zero, device: device)
        colorPixelFormat = .bgra8Unorm
        framebufferOnly = false
        clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        isOpaque = false
        backgroundColor = .clear
        // Frames come from the display link below, not MTKView's own loop
        isPaused = true
        enableSetNeedsDisplay = false
        isAccessibilityElement = false
        registerForTraitChanges([UITraitUserInterfaceStyle.self, UITraitDisplayScale.self]) { (self: Self, _: UITraitCollection) in
            self.effect = nil
        }
    }

    required init(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// Nonisolated: an isolated deinit crashes on the iOS Simulator (GOTCHAS #103).
    nonisolated deinit {}

    func configure(text: String, size: CGFloat) {
        guard text != self.text || size != self.size else { return }
        self.text = text
        self.size = size
        effect = nil
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        link?.invalidate()
        link = nil
        guard window != nil, renderer != nil else { return }
        let link = CADisplayLink(target: SwashWordmarkFrameProxy(self), selector: #selector(SwashWordmarkFrameProxy.tick))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 60, preferred: 60)
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    override func removeFromSuperview() {
        link?.invalidate()
        link = nil
        super.removeFromSuperview()
    }

    /// The effect for the current text and appearance, with the words bound as `uText`.
    private func resolvedEffect() -> AnyFlairEffect? {
        if let effect { return effect }
        guard let renderer, !text.isEmpty, size > 0 else { return nil }
        let ink = SwashWordmarkStyle.ink.resolvedColor(with: traitCollection)
        guard let texture = textTexture(device: renderer.device) else { return nil }
        renderer.setLiveTexture(texture, for: "uText")
        let effect = AnyFlairEffect(SwashWordmarkStyle.effect(dark: traitCollection.userInterfaceStyle == .dark, ink: ink))
        self.effect = effect
        return effect
    }

    /// The words in white on clear, the size of their own box at the screen's scale, as the site's
    /// SVG text input is. The renderer's textures have row 0 at the bottom, so it loads flipped.
    private func textTexture(device: MTLDevice) -> MTLTexture? {
        let box = SwashWordmarkStyle.textSize(text, size: size)
        let format = UIGraphicsImageRendererFormat()
        format.scale = max(2, traitCollection.displayScale)
        format.opaque = false
        // The default range is extended on wide-colour screens, which MTKTextureLoader refuses
        format.preferredRange = .standard
        let font = SwashWordmarkStyle.font(size: size)
        let image = UIGraphicsImageRenderer(size: box, format: format).image { _ in
            (text as NSString).draw(at: CGPoint(x: 0, y: (box.height - (font.ascender - font.descender)) / 2),
                                    withAttributes: SwashWordmarkStyle.attributes(size: size, color: .white))
        }
        guard let cgImage = image.cgImage else { return nil }
        return try? MTKTextureLoader(device: device).newTexture(cgImage: cgImage, options: [
            .origin: MTKTextureLoader.Origin.flippedVertically,
            .generateMipmaps: true,
            .SRGB: false,
        ])
    }

    fileprivate func drawFrame() {
        guard let renderer, let effect = resolvedEffect(), bounds.width > 0, bounds.height > 0,
              let drawable = currentDrawable else { return }
        let now = CACurrentMediaTime()
        let delta = last == 0 ? 1.0 / 60.0 : Float(max(1.0 / 240.0, now - last))
        last = now
        let state = FlairFrameState(width: Float(drawable.texture.width), height: Float(drawable.texture.height),
                                    time: Float(now - start), delta: delta, frame: frameCount, flipY: true)
        frameCount &+= 1
        guard let commands = renderer.commandQueue.makeCommandBuffer() else { return }
        do {
            // The shader's colour is straight alpha and Core Animation's is premultiplied: blending
            // over the cleared drawable multiplies it in, or the glow's faint edges show as white
            try renderer.render(anyEffect: effect, state: state, to: drawable.texture, commandBuffer: commands, blendOver: true)
        } catch {
            return
        }
        commands.present(drawable)
        if !drewFirstFrame {
            drewFirstFrame = true
            commands.addCompletedHandler { [weak self] _ in
                DispatchQueue.main.async { self?.onFirstFrame?() }
            }
        }
        commands.commit()
    }
}

#Preview("Wordmark") {
    SwashWordmark()
        .padding()
}

#Preview("Wordmark, dark", traits: .sizeThatFitsLayout) {
    SwashWordmark()
        .padding()
        .background(Color(uiColor: .systemBackground))
        .environment(\.colorScheme, .dark)
}

#Preview("Wordmark, still") {
    SwashWordmark(animated: false)
        .padding()
}

#Preview("Document manager title") {
    // The launch scene's title area on an iPhone 17
    SwashLaunchWordmark(titleViewFrame: CGRect(x: 0, y: 48, width: 402, height: 362))
}

#Preview("Wordmark, accessibility size") {
    SwashWordmark()
        .padding()
        .environment(\.dynamicTypeSize, .accessibility3)
}
#endif

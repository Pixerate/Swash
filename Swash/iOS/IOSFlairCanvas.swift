//
//  IOSFlairCanvas.swift
//  Swash
//
//  An MTKView that draws one Flair shader effect (FlairEffects) on a transparent background, for
//  the document manager's wordmark (IOSSwashWordmark.swift) and its pixel speckles
//  (IOSLaunchSpeckles.swift). See GOTCHAS #111 and #112.
//

#if os(iOS)
import FlairEffects
import MetalKit
import UIKit

/// Calls back to a canvas it doesn't keep alive, so a `CADisplayLink` doesn't keep its view.
private final class FlairCanvasFrameProxy: NSObject {
    weak var target: FlairCanvasView?

    init(_ target: FlairCanvasView) { self.target = target }

    @objc func tick(_ link: CADisplayLink) {
        guard let target else { link.invalidate(); return }
        target.drawFrame()
    }
}

/// Draws the effect `makeEffect(renderer:)` returns, once a frame from a display link, or once at
/// time 0 while `isStill` (Reduce Motion). The effect is made again after `invalidateEffect()`,
/// and on a change of appearance, display scale or size.
class FlairCanvasView: MTKView {
    /// Called once, after the first frame is on screen.
    var onFirstFrame: (() -> Void)?

    /// Shows the effect's frame at time 0 and stops, instead of animating.
    var isStill = false {
        didSet { if isStill != oldValue { restart() } }
    }

    let renderer: FlairRenderer?
    /// Makes the effect again for every frame, for effects whose settings change over time (the
    /// fold transition's progress) rather than through the shader's own clock.
    var remakesEffectEveryFrame = false
    private var effect: AnyFlairEffect?
    private var link: CADisplayLink?
    private let start = CACurrentMediaTime()
    private var last: CFTimeInterval = 0
    private var frameCount: Int32 = 0
    private var drewFirstFrame = false
    private var lastSize = CGSize.zero

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
            self.invalidateEffect()
        }
    }

    required init(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// Nonisolated: an isolated deinit crashes on the iOS Simulator (GOTCHAS #103).
    nonisolated deinit {}

    /// The effect to draw for the current state, appearance and size; nil draws nothing yet.
    func makeEffect(renderer: FlairRenderer) -> AnyFlairEffect? { nil }

    /// Makes the effect again before the next frame (and draws it now while still).
    func invalidateEffect() {
        effect = nil
        if isStill { drawFrame() }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard bounds.size != lastSize else { return }
        lastSize = bounds.size
        // Sized here, as frames take drawables from the layer rather than through MTKView
        (layer as? CAMetalLayer)?.drawableSize = CGSize(width: bounds.width * contentScaleFactor,
                                                        height: bounds.height * contentScaleFactor)
        invalidateEffect()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        restart()
    }

    override func removeFromSuperview() {
        link?.invalidate()
        link = nil
        super.removeFromSuperview()
    }

    private func restart() {
        link?.invalidate()
        link = nil
        guard window != nil, renderer != nil else { return }
        if isStill {
            drawFrame()
            return
        }
        let link = CADisplayLink(target: FlairCanvasFrameProxy(self), selector: #selector(FlairCanvasFrameProxy.tick))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 60, preferred: 60)
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    fileprivate func drawFrame() {
        guard let renderer, window != nil, bounds.width > 0, bounds.height > 0 else { return }
        if effect == nil || remakesEffectEveryFrame { effect = makeEffect(renderer: renderer) }
        // A fresh drawable from the layer each frame: MTKView's `currentDrawable` is only released
        // by its own `draw()`, which never runs here, so it would keep the first one, at the size
        // of the view's first layout, and the frames would be squashed into the final size
        guard let effect, let drawable = (layer as? CAMetalLayer)?.nextDrawable() else { return }
        let now = CACurrentMediaTime()
        let delta = last == 0 ? 1.0 / 60.0 : Float(max(1.0 / 240.0, now - last))
        last = now
        let state = FlairFrameState(width: Float(drawable.texture.width), height: Float(drawable.texture.height),
                                    time: isStill ? 0 : Float(now - start), delta: delta, frame: frameCount, flipY: true)
        frameCount &+= 1
        guard let commands = renderer.commandQueue.makeCommandBuffer() else { return }
        do {
            // Flair's colour is straight alpha and Core Animation's is premultiplied: blending over
            // the cleared drawable multiplies it in, or faint edges show as white
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
#endif

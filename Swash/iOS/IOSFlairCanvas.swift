//
//  IOSFlairCanvas.swift
//  Swash
//
//  An MTKView that draws one Flair shader effect (FlairEffects) on a transparent background, for
//  the document manager's wordmark (IOSSwashWordmark.swift) and its pixel speckles
//  (IOSLaunchSpeckles.swift). Frames are encoded and presented on a render thread of their own,
//  so the effects keep moving while the main thread is busy (opening a document, say). See
//  GOTCHAS #111, #112 and #115.
//

#if os(iOS)
import FlairEffects
import MetalKit
import UIKit

/// The thread every canvas's frames are drawn on, with a run loop of its own for their display
/// links. It runs for the life of the app; a canvas that isn't playing has no link on it.
nonisolated private final class FlairRenderThread: Thread, @unchecked Sendable {
    static let shared = FlairRenderThread()

    private let started = DispatchSemaphore(value: 0)
    /// Set on the thread before `started` is signalled, and only read after waiting for it.
    private var runLoop: CFRunLoop?

    private override init() {
        super.init()
        name = "Swash Flair render"
        qualityOfService = .userInteractive
        start()
        started.wait()
    }

    override func main() {
        runLoop = CFRunLoopGetCurrent()
        // A port keeps the run loop from returning at once while no display link is on it
        RunLoop.current.add(NSMachPort(), forMode: .default)
        started.signal()
        while true {
            autoreleasepool { _ = RunLoop.current.run(mode: .default, before: .distantFuture) }
        }
    }

    /// Runs `block` on the render thread, after any blocks already asked for.
    func perform(_ block: @escaping @Sendable () -> Void) {
        guard let runLoop else { return }
        CFRunLoopPerformBlock(runLoop, CFRunLoopMode.defaultMode.rawValue, block)
        CFRunLoopWakeUp(runLoop)
    }
}

/// Calls back to a drawer it doesn't keep alive, so a `CADisplayLink` doesn't keep it (or its
/// canvas's layer) after the canvas has gone.
nonisolated private final class FlairCanvasFrameProxy: NSObject {
    weak var target: FlairCanvasDrawer?

    init(_ target: FlairCanvasDrawer) { self.target = target }

    @objc func tick(_ link: CADisplayLink) {
        guard let target else { link.invalidate(); return }
        target.drawFrame()
    }
}

/// Calls back to a canvas on the main thread, for effects that are made again every frame.
private final class FlairCanvasEffectProxy: NSObject {
    weak var target: FlairCanvasView?

    init(_ target: FlairCanvasView) { self.target = target }

    @objc func tick(_ link: CADisplayLink) {
        guard let target else { link.invalidate(); return }
        target.invalidateEffect()
    }
}

/// The render-thread half of a canvas. The canvas hands it the effect to draw (made on the main
/// thread, where it can read UIKit) and whether it's still; it draws them into the canvas's
/// `CAMetalLayer`, whose `drawableSize` the canvas keeps up to date, and never touches UIKit.
nonisolated final class FlairCanvasDrawer: @unchecked Sendable {
    private struct Snapshot {
        var effect: AnyFlairEffect?
        var isStill = false
    }

    let renderer: FlairRenderer
    private let layer: CAMetalLayer
    private let firstFrameShown: @Sendable () -> Void

    private let lock = NSLock()
    /// The latest effect from the main thread; guarded by `lock`.
    private var snapshot = Snapshot()

    // Only used on the render thread
    private var link: CADisplayLink?
    private let start = CACurrentMediaTime()
    private var last: CFTimeInterval = 0
    private var frameCount: Int32 = 0
    private var drewFirstFrame = false

    init(renderer: FlairRenderer, layer: CAMetalLayer, firstFrameShown: @escaping @Sendable () -> Void) {
        self.renderer = renderer
        self.layer = layer
        self.firstFrameShown = firstFrameShown
    }

    /// Draws `effect` from the next frame on (nothing while it's nil), at time 0 while `isStill`.
    func update(effect: AnyFlairEffect?, isStill: Bool) {
        lock.withLock { snapshot = Snapshot(effect: effect, isStill: isStill) }
    }

    /// Draws a frame on every display refresh, until `stop()`.
    func play() {
        FlairRenderThread.shared.perform { [self] in
            guard link == nil else { return }
            let link = CADisplayLink(target: FlairCanvasFrameProxy(self), selector: #selector(FlairCanvasFrameProxy.tick))
            link.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 60, preferred: 60)
            link.add(to: .current, forMode: .default)
            self.link = link
        }
    }

    func stop() {
        FlairRenderThread.shared.perform { [self] in
            link?.invalidate()
            link = nil
        }
    }

    /// Draws one frame, for a still canvas.
    func drawOnce() {
        FlairRenderThread.shared.perform { [self] in drawFrame() }
    }

    /// On the render thread.
    fileprivate func drawFrame() {
        let snapshot = lock.withLock { self.snapshot }
        // A fresh drawable from the layer each frame: MTKView's `currentDrawable` is only released
        // by its own `draw()`, which never runs here, so it would keep the first one, at the size
        // of the view's first layout, and the frames would be squashed into the final size
        guard let effect = snapshot.effect, let drawable = layer.nextDrawable() else { return }
        let now = CACurrentMediaTime()
        let delta = last == 0 ? 1.0 / 60.0 : Float(max(1.0 / 240.0, now - last))
        last = now
        let state = FlairFrameState(width: Float(drawable.texture.width), height: Float(drawable.texture.height),
                                    time: snapshot.isStill ? 0 : Float(now - start), delta: delta, frame: frameCount, flipY: true)
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
            let firstFrameShown = firstFrameShown
            commands.addCompletedHandler { _ in firstFrameShown() }
        }
        commands.commit()
    }
}

/// Draws the effect `makeEffect(renderer:)` returns, once a frame from a display link on the
/// render thread, or once at time 0 while `isStill` (Reduce Motion). The effect is made on the
/// main thread, again after `invalidateEffect()` and on a change of appearance, display scale or
/// size, and handed to the render thread, which keeps drawing the latest one while the main
/// thread is busy.
class FlairCanvasView: MTKView {
    /// Called on the main thread, once, after the first frame is on screen.
    var onFirstFrame: (() -> Void)?

    /// Shows the effect's frame at time 0 and stops, instead of animating.
    var isStill = false {
        didSet { if isStill != oldValue { restart() } }
    }

    let renderer: FlairRenderer?
    /// Makes the effect again for every frame, for effects whose settings change over time (the
    /// fold transition's progress) rather than through the shader's own clock.
    var remakesEffectEveryFrame = false {
        didSet { if remakesEffectEveryFrame != oldValue { restart() } }
    }
    private var drawer: FlairCanvasDrawer?
    /// On the main run loop, while `remakesEffectEveryFrame`: makes the effect for each frame.
    private var effectLink: CADisplayLink?
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
        // Frames come from the drawer's display link, not MTKView's own loop
        isPaused = true
        enableSetNeedsDisplay = false
        isAccessibilityElement = false
        if let renderer, let layer = layer as? CAMetalLayer {
            drawer = FlairCanvasDrawer(renderer: renderer, layer: layer) { [weak self] in
                DispatchQueue.main.async { self?.onFirstFrame?() }
            }
        }
        registerForTraitChanges([UITraitUserInterfaceStyle.self, UITraitDisplayScale.self]) { (self: Self, _: UITraitCollection) in
            self.invalidateEffect()
        }
    }

    required init(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// Nonisolated: an isolated deinit crashes on the iOS Simulator (GOTCHAS #103). The drawer's
    /// display link stops itself once the drawer has gone.
    nonisolated deinit {}

    /// The effect to draw for the current state, appearance and size; nil draws nothing yet.
    /// Called on the main thread.
    func makeEffect(renderer: FlairRenderer) -> AnyFlairEffect? { nil }

    /// Makes the effect again and hands it to the render thread (and draws it now while still).
    func invalidateEffect() {
        guard let drawer else { return }
        let showing = window != nil && bounds.width > 0 && bounds.height > 0
        drawer.update(effect: showing ? makeEffect(renderer: drawer.renderer) : nil, isStill: isStill)
        if showing, isStill { drawer.drawOnce() }
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
        stop()
        super.removeFromSuperview()
    }

    private func stop() {
        drawer?.stop()
        effectLink?.invalidate()
        effectLink = nil
    }

    private func restart() {
        stop()
        guard window != nil, let drawer else { return }
        // Made again here, now the traits are the window's
        invalidateEffect()
        guard !isStill else { return }
        drawer.play()
        if remakesEffectEveryFrame {
            let link = CADisplayLink(target: FlairCanvasEffectProxy(self), selector: #selector(FlairCanvasEffectProxy.tick))
            link.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 60, preferred: 60)
            link.add(to: .main, forMode: .common)
            effectLink = link
        }
    }
}
#endif

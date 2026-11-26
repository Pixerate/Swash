//
//  FoldTransition.swift
//  Swash
//
//  Opening or closing an iPhone Duo moves the document between displays. The system crossfades
//  the two layouts; this turns that moment into a page folding over (#65). When the hinge starts
//  to move, the window is snapshotted at its current size; when the window then changes size (the
//  display switch), the snapshot covers the new layout at once, so the first frame on the new
//  display is the page the person was looking at, and Flair's mirror fold turns it over to reveal
//  the new layout. With Reduce Motion the snapshot simply fades.
//
//  The hinge also tells the editor to tidy up before the switch: transient menus are closed (they
//  would come back in the wrong place) and unsaved edits are saved.
//

#if os(iOS)
import FlairEffects
import MetalKit
import SwiftUI
import UIKit

/// Hosts a `FoldTransitionWatcher` behind the document screen.
struct FoldTransitionHost: UIViewRepresentable {
    /// Called when the hinge leaves fully open or closed, before the display switches.
    var onHingeMove: () -> Void

    func makeUIView(context: Context) -> FoldTransitionWatcher {
        FoldTransitionWatcher()
    }

    func updateUIView(_ watcher: FoldTransitionWatcher, context: Context) {
        watcher.onHingeMove = onHingeMove
    }
}

/// Watches the hinge and its window's size, and plays the fold when the window moves displays.
final class FoldTransitionWatcher: UIView {
    var onHingeMove: (() -> Void)?

    /// The window as it looked when the hinge started to move, and when.
    private var pending: (image: UIImage, size: CGSize, taken: CFTimeInterval)?
    private var lastWindowSize = CGSize.zero
    private var lastHingeStatus: Int?
    private weak var overlay: UIView?

    /// How long a snapshot taken as the hinge moved stays usable: a hinge that moves and settles
    /// back without a display switch leaves one behind.
    private static let snapshotLifetime: CFTimeInterval = 4
    /// Width changes smaller than this (the keyboard, a sidebar) aren't display switches.
    private static let minimumWidthChange: CGFloat = 120

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        backgroundColor = .clear
        if #available(iOS 27.1, *) {
            addInteraction(UIHingeInteraction { [weak self] _, update in
                self?.hingeChanged(update.hinge)
            })
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// Nonisolated: an isolated deinit crashes on the iOS Simulator (GOTCHAS #103).
    nonisolated deinit {}

    override func didMoveToWindow() {
        super.didMoveToWindow()
        lastWindowSize = window?.bounds.size ?? .zero
    }

    @available(iOS 27.1, *)
    private func hingeChanged(_ hinge: UIHinge?) {
        guard let hinge else { return }
        let status = hinge.status.rawValue
        defer { lastHingeStatus = status }
        // Leaving a resting state (closed, or open flat) is the start of an open or a close
        guard let previous = lastHingeStatus, previous != status,
              previous == UIHinge.Status.closed.rawValue || previous == UIHinge.Status.fullyOpen.rawValue else { return }
        onHingeMove?()
        captureWindow()
    }

    private func captureWindow() {
        guard let window, window.bounds.width > 0, overlay == nil else { return }
        let size = window.bounds.size
        let format = UIGraphicsImageRendererFormat(for: window.traitCollection)
        let image = UIGraphicsImageRenderer(size: size, format: format).image { _ in
            window.drawHierarchy(in: CGRect(origin: .zero, size: size), afterScreenUpdates: false)
        }
        pending = (image, size, CACurrentMediaTime())
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard let window else { return }
        let size = window.bounds.size
        defer { lastWindowSize = size }
        guard lastWindowSize != .zero, abs(size.width - lastWindowSize.width) >= Self.minimumWidthChange else { return }
        guard let pending, pending.size == lastWindowSize,
              CACurrentMediaTime() - pending.taken < Self.snapshotLifetime else {
            self.pending = nil
            return
        }
        self.pending = nil
        playFold(in: window, from: pending.image, opening: size.width > pending.size.width)
    }

    /// Covers the new layout with the old page now, then folds it away once the new layout has
    /// been drawn.
    private func playFold(in window: UIWindow, from oldPage: UIImage, opening: Bool) {
        overlay?.removeFromSuperview()
        let size = window.bounds.size
        let background = window.rootViewController?.view.backgroundColor ?? .systemBackground
        let from = Self.page(oldPage, fittedTo: size, background: background, traits: window.traitCollection)

        let cover = UIImageView(image: from)
        cover.frame = window.bounds
        cover.isUserInteractionEnabled = false
        cover.accessibilityElementsHidden = true
        window.addSubview(cover)
        overlay = cover
        // Whatever happens to the fold (no Metal, a frame that never draws), the old page never
        // stays over the editor
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self, weak cover] in
            cover?.removeFromSuperview()
            if let fold = self?.overlay as? FoldTransitionCanvasView { fold.removeFromSuperview() }
        }

        guard !UIAccessibility.isReduceMotionEnabled else {
            UIView.animate(withDuration: 0.25, delay: 0.05, options: .curveEaseOut) {
                cover.alpha = 0
            } completion: { _ in
                cover.removeFromSuperview()
            }
            return
        }
        // The new layout is drawn on the next run loop: text reflows and the editors keep their
        // reading position (MarkdownEditingTextView) during this one
        DispatchQueue.main.async { [weak self, weak window, weak cover] in
            guard let self, let window, let cover, cover.superview != nil else { return }
            guard let content = window.rootViewController?.view else {
                cover.removeFromSuperview()
                return
            }
            let format = UIGraphicsImageRendererFormat(for: window.traitCollection)
            let to = UIGraphicsImageRenderer(size: window.bounds.size, format: format).image { _ in
                content.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
            }
            let fold = FoldTransitionCanvasView(from: from, to: to, opening: opening, background: background)
            guard fold.isReady else {
                cover.removeFromSuperview()
                return
            }
            fold.frame = window.bounds
            fold.onFinish = { [weak fold] in fold?.removeFromSuperview() }
            window.addSubview(fold)
            // The fold's first frame is the old page too, so the cover can go once it's showing
            fold.onFirstFrame = { [weak cover] in cover?.removeFromSuperview() }
            self.overlay = fold
        }
    }

    /// The old page on a canvas the size of the new window, at the same scale and pinned to the
    /// top leading corner, where the text starts: the shader stretches its input to the frame,
    /// so the old page has to be the new frame's shape.
    private static func page(_ image: UIImage, fittedTo size: CGSize, background: UIColor,
                             traits: UITraitCollection) -> UIImage {
        let format = UIGraphicsImageRendererFormat(for: traits)
        return UIGraphicsImageRenderer(size: size, format: format).image { context in
            background.resolvedColor(with: traits).setFill()
            context.fill(CGRect(origin: .zero, size: size))
            let x = traits.layoutDirection == .rightToLeft ? size.width - image.size.width : 0
            image.draw(at: CGPoint(x: x, y: 0))
        }
    }
}

/// Flair's mirror fold from the old page to the new one, once, then `onFinish`.
final class FoldTransitionCanvasView: FlairCanvasView {
    var onFinish: (() -> Void)?

    /// Whether both pages were uploaded; without them there's nothing to fold.
    private(set) var isReady = false
    private let opening: Bool
    private let background: SIMD3<Float>
    private var started: CFTimeInterval?
    private var finished = false
    private static let duration: CFTimeInterval = 0.6

    init(from: UIImage, to: UIImage, opening: Bool, background: UIColor) {
        self.opening = opening
        var red: CGFloat = 1, green: CGFloat = 1, blue: CGFloat = 1, alpha: CGFloat = 1
        background.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        self.background = SIMD3(Float(red), Float(green), Float(blue))
        super.init()
        isUserInteractionEnabled = false
        accessibilityElementsHidden = true
        remakesEffectEveryFrame = true
        guard let renderer, let fromImage = from.cgImage, let toImage = to.cgImage else { return }
        // Uploaded once and bound by name, so each frame only changes the fold's progress
        let loader = MTKTextureLoader(device: renderer.device)
        let options: [MTKTextureLoader.Option: Any] = [.SRGB: false, .origin: MTKTextureLoader.Origin.topLeft]
        guard let fromTexture = try? loader.newTexture(cgImage: fromImage, options: options),
              let toTexture = try? loader.newTexture(cgImage: toImage, options: options) else { return }
        renderer.setLiveTexture(fromTexture, for: "uFrom")
        renderer.setLiveTexture(toTexture, for: "uTo")
        isReady = true
    }

    required init(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// Nonisolated: an isolated deinit crashes on the iOS Simulator (GOTCHAS #103).
    nonisolated deinit {}

    override func makeEffect(renderer: FlairRenderer) -> AnyFlairEffect? {
        let now = CACurrentMediaTime()
        let start = started ?? now
        started = start
        let t = min(1, (now - start) / Self.duration)
        if t >= 1, !finished {
            finished = true
            DispatchQueue.main.async { [weak self] in self?.onFinish?() }
        }
        var fold = TransitionMirrorFold()
        fold.animate = false
        // Ease in and out, so the page lifts gently and settles
        fold.progress = Float(t * t * (3 - 2 * t))
        // Opening, the page turns from the hinge outwards; closing, it folds back towards it
        fold.angle = opening ? 0 : 180
        fold.flap = 0.3
        fold.backdrop = background
        fold.backdropAlpha = 1
        return AnyFlairEffect(fold)
    }
}
#endif

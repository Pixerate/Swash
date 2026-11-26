//
//  FoldTransition.swift
//  Swash
//
//  Opening or closing an iPhone Duo moves the document between displays (#65). As the hinge
//  moves, the words on the display being left glide to where the other display will show them,
//  turning over on the way, so by the time the switch happens the page reads as the mirror image
//  of the layout that's about to appear, gathered on the left half, where the outer display sits
//  behind the inner one: seen through the back of the page. Opening plays the same thing the
//  other way round. The hinge's angle drives it, so the words follow the person's hand; a hinge
//  that settles half open, or goes back, puts the words back. With Reduce Motion nothing moves.
//
//  The hinge also tells the editor to tidy up before the switch: transient menus are closed (they
//  would come back in the wrong place) and unsaved edits are saved.
//

#if os(iOS)
import ObjectiveC
import SwiftUI
import UIKit

/// Hosts a `FoldTransitionWatcher` behind the document screen.
struct FoldTransitionHost: UIViewRepresentable {
    /// Called when the hinge leaves fully open or closed, before the display switches.
    var onHingeMove: () -> Void
    /// The editor whose words move.
    var textView: () -> UITextView?

    func makeUIView(context: Context) -> FoldTransitionWatcher {
        FoldTransitionWatcher()
    }

    func updateUIView(_ watcher: FoldTransitionWatcher, context: Context) {
        watcher.onHingeMove = onHingeMove
        watcher.textView = textView
    }
}

/// Forwards the hinge and its window's size to the window's `FoldTransitionCoordinator`. SwiftUI
/// rebuilds the document screen, and this view with it, while the display switches, so it keeps
/// no state of its own.
final class FoldTransitionWatcher: UIView {
    var onHingeMove: (() -> Void)?
    var textView: (() -> UITextView?)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        backgroundColor = .clear
        if #available(iOS 27.1, *) {
            addInteraction(UIHingeInteraction { [weak self] _, update in
                guard let self, let hinge = update.hinge, let window = self.window else { return }
                // `angle` is in radians: about π open flat, 0 closed
                FoldTransitionCoordinator.for(window).hingeChanged(status: hinge.status.rawValue,
                                                                   angle: hinge.angle * 180 / .pi, from: self)
            })
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// Nonisolated: an isolated deinit crashes on the iOS Simulator (GOTCHAS #103).
    nonisolated deinit {}

    override func layoutSubviews() {
        super.layoutSubviews()
        guard let window else { return }
        FoldTransitionCoordinator.for(window).windowLaidOut(from: self)
    }
}

/// One per window: follows a hinge movement from rest to the display switch, and plays the words'
/// mirrored reflow over the window meanwhile.
final class FoldTransitionCoordinator {
    private enum Rest { case closed, fullyOpen }

    private weak var window: UIWindow?
    /// Where the hinge was last at rest.
    private var lastRest: Rest?
    private var lastAngle: CGFloat = 0
    private var lastWindowSize = CGSize.zero
    /// The rest state the hinge left, while a movement is under way.
    private var leaving: Rest?
    private var overlay: MirrorReflowOverlay?
    private var settleTimer: Timer?

    /// Width changes smaller than this (the keyboard, a sidebar) aren't display switches.
    private static let minimumWidthChange: CGFloat = 120
    /// How long the hinge can rest part-way before the words go back.
    private static let settleDelay: TimeInterval = 0.45

    // Learned from the switches seen so far (defaults until then): the window's size on the other
    // display, the editor's frame at each size, and the hinge angle each switch happens at.
    private static var otherSize: [SizeKey: CGSize] = [:]
    private static var editorFrames: [SizeKey: CGRect] = [:]
    // On the simulator the displays switch at about 30° opening and 60–90° closing: finishing a
    // little early leaves the mirrored page showing until the switch, finishing late cuts it short
    private static var closingSwitchAngle: CGFloat = 90
    private static var openingSwitchAngle: CGFloat = 30

    private static var key: UInt8 = 0

    static func `for`(_ window: UIWindow) -> FoldTransitionCoordinator {
        if let existing = objc_getAssociatedObject(window, &key) as? FoldTransitionCoordinator { return existing }
        let coordinator = FoldTransitionCoordinator(window: window)
        objc_setAssociatedObject(window, &key, coordinator, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        return coordinator
    }

    private init(window: UIWindow) {
        self.window = window
        lastWindowSize = window.bounds.size
    }

    // MARK: Hinge

    /// The hinge is at rest only when its status and angle agree: either can lag the other (on
    /// the simulator the status stayed closed while the angle went past 90°, and read closed while
    /// the angle was still near 60°).
    private static func rest(status: Int, angle: CGFloat) -> Rest? {
        if #available(iOS 27.1, *) {
            if status == UIHinge.Status.closed.rawValue, angle <= 5 { return .closed }
            if status == UIHinge.Status.fullyOpen.rawValue, angle >= 175 { return .fullyOpen }
        }
        return nil
    }

    func hingeChanged(status: Int, angle: CGFloat, from watcher: FoldTransitionWatcher) {
        lastAngle = angle
        let resting = Self.rest(status: status, angle: angle)
        defer { if let resting { lastRest = resting } }
        if leaving == nil {
            // Leaving a resting state (closed, or open flat) is the start of an open or a close
            guard resting == nil, let from = lastRest else { return }
            leaving = from
            watcher.onHingeMove?()
            if !UIAccessibility.isReduceMotionEnabled, let textView = watcher.textView?() {
                startReflow(textView: textView, closing: from == .fullyOpen)
            }
        }
        guard let leaving else { return }
        if let resting {
            // Back where it started, no switch is coming; at the other end, the switch is done
            finish(retract: resting == leaving)
            return
        }
        overlay?.setProgress(progress(angle: angle, leaving: leaving))
        settleTimer?.invalidate()
        if resting == nil {
            // A hinge that stops part-way (the phone stood half open) is being used, not moved
            settleTimer = Timer.scheduledTimer(withTimeInterval: Self.settleDelay, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated { self?.finish(retract: true) }
            }
        }
    }

    /// How far the words have gone: from the hinge's rest to the angle the display switches at.
    private func progress(angle: CGFloat, leaving: Rest) -> CGFloat {
        switch leaving {
        case .fullyOpen:
            let start: CGFloat = 180, end = Self.closingSwitchAngle
            return (start - angle) / max(1, start - end)
        case .closed:
            return angle / max(1, Self.openingSwitchAngle)
        }
    }

    // MARK: Window

    func windowLaidOut(from watcher: FoldTransitionWatcher) {
        guard let window else { return }
        let size = window.bounds.size
        defer { lastWindowSize = size }
        guard lastWindowSize != .zero, size != lastWindowSize else { return }
        guard abs(size.width - lastWindowSize.width) >= Self.minimumWidthChange else { return }
        // The display switched: the real layout takes over at once
        Self.otherSize[SizeKey(lastWindowSize)] = size
        Self.otherSize[SizeKey(size)] = lastWindowSize
        if let leaving {
            let angle = min(170, max(0, lastAngle))
            switch leaving {
            case .fullyOpen: Self.closingSwitchAngle = min(angle, 120)
            case .closed: Self.openingSwitchAngle = max(angle, 15)
            }
        }
        finish(retract: false)
        // The hinge is still moving on the new display: nothing starts until it has come to rest
        lastRest = nil
        // Where the editor sits at this size, once the new layout is in
        DispatchQueue.main.async { [weak self, weak watcher] in
            guard let self, let window = self.window, let textView = watcher?.textView?() else { return }
            self.recordEditorFrame(textView, in: window)
        }
    }

    private func recordEditorFrame(_ textView: UITextView, in window: UIWindow) {
        guard textView.window === window else { return }
        Self.editorFrames[SizeKey(window.bounds.size)] = textView.convert(textView.bounds, to: window)
    }

    // MARK: Reflow

    private func startReflow(textView: UITextView, closing: Bool) {
        guard let window, textView.window === window, overlay == nil else { return }
        recordEditorFrame(textView, in: window)
        let size = window.bounds.size
        let current = textView.convert(textView.bounds, to: window)
        // The other display's window, and the editor in it: learned, or estimated the first time
        // (closed is about half the open width, give or take the hinge)
        let targetSize = Self.otherSize[SizeKey(size)]
            ?? CGSize(width: closing ? size.width * 0.49 : size.width * 2.04, height: size.height)
        let targetFrame = Self.editorFrames[SizeKey(targetSize)]
            ?? CGRect(x: current.minX, y: current.minY,
                      width: max(120, targetSize.width - (size.width - current.width)),
                      height: max(120, targetSize.height - (size.height - current.height)))
        guard let words = MirrorReflowOverlay.words(in: textView, window: window,
                                                   targetWindow: targetSize, targetEditor: targetFrame),
              !words.words.isEmpty else { return }
        let overlay = MirrorReflowOverlay(frame: window.bounds, page: current,
                                          background: textView.backgroundColor ?? .systemBackground, words: words)
        window.addSubview(overlay)
        self.overlay = overlay
    }

    private func finish(retract: Bool) {
        settleTimer?.invalidate()
        settleTimer = nil
        leaving = nil
        guard let overlay else { return }
        self.overlay = nil
        if retract {
            overlay.retract()
        } else {
            overlay.removeFromSuperview()
        }
    }
}

/// A window size, rounded, as a dictionary key.
private struct SizeKey: Hashable {
    let width: Int
    let height: Int
    init(_ size: CGSize) {
        width = Int(size.width.rounded())
        height = Int(size.height.rounded())
    }
}

/// The editor's visible words as layers over a blank page, each moving between where it is and
/// its mirrored place on the other display.
final class MirrorReflowOverlay: UIView {
    struct Word {
        /// The word's glyphs, cut from a render of the visible text.
        let contentsRect: CGRect
        /// Where it is now, in the window.
        let from: CGRect
        /// Where it ends up, in the window: its place on the other display, mirrored.
        let to: CGRect
        /// When it starts, as a share of the whole movement, so the words leave in a wave.
        let delay: CGFloat
    }

    private let words: [Word]
    private var layers: [CALayer] = []
    private let pageLayer = CALayer()
    private var progress: CGFloat = 0

    /// The latest a word starts: the rest of the movement is its own.
    private static let maximumDelay: CGFloat = 0.35

    init(frame: CGRect, page: CGRect, background: UIColor, words: (image: CGImage, scale: CGFloat, words: [Word])) {
        self.words = words.words
        super.init(frame: frame)
        isUserInteractionEnabled = false
        accessibilityElementsHidden = true
        backgroundColor = .clear
        // Covers the real text, which stays where it is underneath
        pageLayer.frame = page
        pageLayer.backgroundColor = background.resolvedColor(with: traitCollection).cgColor
        layer.addSublayer(pageLayer)
        var perspective = CATransform3DIdentity
        perspective.m34 = -1 / 900
        layer.sublayerTransform = perspective
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for word in words.words {
            let wordLayer = CALayer()
            wordLayer.contents = words.image
            wordLayer.contentsRect = word.contentsRect
            wordLayer.contentsScale = words.scale
            wordLayer.contentsGravity = .resize
            wordLayer.frame = word.from
            // The back shows the glyphs mirrored, which is the point
            wordLayer.isDoubleSided = true
            layer.addSublayer(wordLayer)
            layers.append(wordLayer)
        }
        CATransaction.commit()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// Nonisolated: an isolated deinit crashes on the iOS Simulator (GOTCHAS #103).
    nonisolated deinit {}

    /// Moves every word to `progress` (0 where it is, 1 its mirrored place), gliding between the
    /// hinge's updates.
    func setProgress(_ value: CGFloat, duration: CFTimeInterval = 1.0 / 20) {
        progress = min(1, max(0, value))
        CATransaction.begin()
        CATransaction.setAnimationDuration(duration)
        CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .linear))
        let span = 1 - Self.maximumDelay
        for (word, wordLayer) in zip(words, layers) {
            let local = min(1, max(0, (progress - word.delay) / span))
            let t = local * local * (3 - 2 * local)
            wordLayer.position = CGPoint(x: word.from.midX + (word.to.midX - word.from.midX) * t,
                                         y: word.from.midY + (word.to.midY - word.from.midY) * t)
            let scaleX = word.from.width > 0 ? 1 + (word.to.width / word.from.width - 1) * t : 1
            let scaleY = word.from.height > 0 ? 1 + (word.to.height / word.from.height - 1) * t : 1
            // Turning over about its own vertical axis: half way it's edge on, at the end mirrored
            var transform = CATransform3DMakeRotation(.pi * t, 0, 1, 0)
            transform = CATransform3DScale(transform, scaleX, scaleY, 1)
            wordLayer.transform = transform
        }
        CATransaction.commit()
    }

    /// Puts the words back, then shows the real text again.
    func retract() {
        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak self] in self?.removeFromSuperview() }
        setProgress(0, duration: 0.25)
        CATransaction.commit()
    }

    // MARK: Words

    /// The visible words of `textView`, with where each sits now and where the other display will
    /// show it, mirrored into the part of this window that display sits behind. Nil for an editor
    /// that isn't on TextKit 1 (reading its layout manager would switch it over).
    static func words(in textView: UITextView, window: UIWindow, targetWindow: CGSize,
                      targetEditor: CGRect) -> (image: CGImage, scale: CGFloat, words: [Word])? {
        guard textView.textLayoutManager == nil else { return nil }
        let layoutManager = textView.layoutManager
        let container = textView.textContainer
        let inset = textView.textContainerInset
        let offset = textView.contentOffset
        let visible = CGRect(x: offset.x - inset.left, y: offset.y - inset.top,
                             width: textView.bounds.width, height: textView.bounds.height)
        let glyphs = layoutManager.glyphRange(forBoundingRect: visible, in: container)
        guard glyphs.length > 0 else { return nil }
        let characters = layoutManager.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)

        // The text alone, on clear, as the visible part of the editor shows it
        let format = UIGraphicsImageRendererFormat(for: textView.traitCollection)
        format.opaque = false
        let origin = CGPoint(x: inset.left - offset.x, y: inset.top - offset.y)
        let image = UIGraphicsImageRenderer(size: textView.bounds.size, format: format).image { _ in
            layoutManager.drawGlyphs(forGlyphRange: glyphs, at: origin)
        }
        guard let cgImage = image.cgImage else { return nil }

        // The same text laid out at the other display's width
        let targetStorage = NSTextStorage(attributedString: textView.textStorage)
        let targetLayout = NSLayoutManager()
        targetStorage.addLayoutManager(targetLayout)
        let targetWidth = max(60, targetEditor.width - inset.left - inset.right)
        let targetContainer = NSTextContainer(size: CGSize(width: targetWidth, height: .greatestFiniteMagnitude))
        targetContainer.lineFragmentPadding = container.lineFragmentPadding
        targetLayout.addTextContainer(targetContainer)
        targetLayout.ensureLayout(forCharacterRange: NSRange(location: 0, length: NSMaxRange(characters)))

        // Where the outer display sits, back to back with the inner one: behind its left half,
        // centred there. Closing, that's the region of this (inner) window the mirrored words
        // gather in; opening, it's the region of the other (inner) window that this one shows
        let size = window.bounds.size
        let closing = targetWindow.width < size.width
        let region: CGRect
        if closing {
            let half = size.width / 2
            region = CGRect(x: (half - targetWindow.width) / 2, y: (size.height - targetWindow.height) / 2,
                            width: targetWindow.width, height: targetWindow.height)
        } else {
            let half = targetWindow.width / 2
            region = CGRect(x: (half - size.width) / 2, y: (targetWindow.height - size.height) / 2,
                            width: size.width, height: size.height)
        }

        var words: [Word] = []
        var anchor: (current: CGFloat, target: CGFloat)?
        let editorTop = textView.convert(textView.bounds, to: window).minY
        let text = textView.textStorage.string as NSString
        text.enumerateSubstrings(in: characters, options: [.byWords, .substringNotRequired]) { _, range, _, stop in
            guard let from = firstRect(of: range, layoutManager: layoutManager, container: container),
                  let target = firstRect(of: range, layoutManager: targetLayout, container: targetContainer) else { return }
            // Container coordinates to the editor's visible area, then to the window
            let inEditor = from.offsetBy(dx: inset.left, dy: inset.top)
            let crop = inEditor.offsetBy(dx: -offset.x, dy: -offset.y)
            guard crop.intersects(CGRect(origin: .zero, size: textView.bounds.size)) else { return }
            let inWindow = textView.convert(inEditor, to: window)
            // The first word keeps its distance from the editor's top on the other display, as the
            // editor keeps its reading position there
            if anchor == nil { anchor = (inWindow.minY - editorTop, target.minY) }
            guard let anchor else { return }
            let targetInWindow = CGRect(x: targetEditor.minX + inset.left + target.minX,
                                        y: targetEditor.minY + anchor.current + (target.minY - anchor.target),
                                        width: target.width, height: target.height)
            let mirrored: CGRect
            if closing {
                // The other display's layout, flipped left to right inside its region of this one
                mirrored = CGRect(x: region.minX + (targetWindow.width - targetInWindow.maxX),
                                  y: region.minY + targetInWindow.minY,
                                  width: targetInWindow.width, height: targetInWindow.height)
            } else {
                // The inner layout's left half, flipped, as seen from behind; the words of its right
                // half leave past the left edge
                mirrored = CGRect(x: region.maxX - targetInWindow.maxX,
                                  y: targetInWindow.minY - region.minY,
                                  width: targetInWindow.width, height: targetInWindow.height)
            }
            let bounds = textView.bounds.size
            let contentsRect = CGRect(x: crop.minX / bounds.width, y: crop.minY / bounds.height,
                                      width: crop.width / bounds.width, height: crop.height / bounds.height)
            // A wave from the left, where the outer display is
            let across = inWindow.midX / size.width
            let down = inWindow.midY / size.height
            let delay = MirrorReflowOverlay.maximumDelay * min(1, max(0, 0.7 * across + 0.3 * down))
            words.append(Word(contentsRect: contentsRect, from: inWindow, to: mirrored, delay: delay))
            if words.count >= 1500 { stop.pointee = true }
        }
        return (cgImage, image.scale, words)
    }

    /// The first line's rectangle of `range`, in container coordinates: a word that wraps moves as
    /// its first part. Nil for hidden text (Markdown syntax the editor collapses).
    private static func firstRect(of range: NSRange, layoutManager: NSLayoutManager, container: NSTextContainer) -> CGRect? {
        let glyphs = layoutManager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
        guard glyphs.length > 0 else { return nil }
        var first: CGRect?
        layoutManager.enumerateEnclosingRects(forGlyphRange: glyphs,
                                              withinSelectedGlyphRange: NSRange(location: NSNotFound, length: 0),
                                              in: container) { rect, stop in
            first = rect
            stop.pointee = true
        }
        guard let first, first.width >= 1, first.height >= 1 else { return nil }
        return first
    }
}
#endif

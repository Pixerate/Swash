//
//  WritingPartnerOverlay.swift
//  Swash
//
//  What the writing partner (#61) shows over the Mac editor. It draws in layers over the text view
//  and never touches the text:
//  - a soft gradient that sweeps across the word or line it's checking;
//  - its own insertion point, in the partner's colour, as the editor package's `AgentTextDirector`
//    moves it (#878): it selects the word it's fixing, types the new word over it (drawn here, not
//    written into the text, until the edit lands), then tints what changed and fades.
//  With Reduce Motion on, the sweep is skipped and the fix lands at once; the cursor and tint fade.
//

#if os(macOS)
import AppKit
import PixerateCore
import QuartzCore

final class WritingPartnerOverlay: NSView {
    /// The partner's colour: its cursor and selection, distinct from the person's.
    static let tint = NSColor.systemPurple

    static var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    init(in textView: NSTextView) {
        super.init(frame: textView.bounds)
        wantsLayer = true
        layer?.masksToBounds = false
        autoresizingMask = [.width, .height]
    }

    required init?(coder: NSCoder) { nil }

    /// The overlay of `textView`, added on first use.
    static func overlay(for textView: NSTextView) -> WritingPartnerOverlay {
        if let existing = textView.subviews.compactMap({ $0 as? WritingPartnerOverlay }).first {
            existing.frame = textView.bounds
            return existing
        }
        let overlay = WritingPartnerOverlay(in: textView)
        textView.addSubview(overlay)
        return overlay
    }

    /// Line rectangles of `range` (storage offsets) in the text view's coordinates.
    static func rects(for range: NSRange, in textView: NSTextView) -> [NSRect] {
        guard let layoutManager = textView.layoutManager, let container = textView.textContainer,
              let storage = textView.textStorage, NSMaxRange(range) <= storage.length else { return [] }
        let glyphs = layoutManager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
        var rects: [NSRect] = []
        layoutManager.enumerateEnclosingRects(forGlyphRange: glyphs, withinSelectedGlyphRange: NSRange(location: NSNotFound, length: 0),
                                              in: container) { rect, _ in
            rects.append(rect.offsetBy(dx: textView.textContainerOrigin.x, dy: textView.textContainerOrigin.y))
        }
        return rects.filter { $0.width > 0.5 && $0.height > 0.5 }
    }

    /// The insertion point's rectangle at `location` (storage offset): the left edge of the
    /// character there, or the right edge of the one before at the end of a line or the text.
    static func caretRect(at location: Int, in textView: NSTextView) -> NSRect? {
        guard let layoutManager = textView.layoutManager, let container = textView.textContainer,
              let storage = textView.textStorage, storage.length > 0 else { return nil }
        let string = storage.string as NSString
        let atLineEnd = location >= string.length || string.character(at: location) == 0x0A
        let index = atLineEnd ? max(0, min(location, string.length) - 1) : location
        let glyphs = layoutManager.glyphRange(forCharacterRange: NSRange(location: index, length: 1), actualCharacterRange: nil)
        let glyph = layoutManager.boundingRect(forGlyphRange: glyphs, in: container)
        let line = layoutManager.lineFragmentUsedRect(forGlyphAt: glyphs.location, effectiveRange: nil)
        let x = atLineEnd ? glyph.maxX : glyph.minX
        return NSRect(x: x - 1, y: line.minY, width: 2, height: line.height)
            .offsetBy(dx: textView.textContainerOrigin.x, dy: textView.textContainerOrigin.y)
    }

    // MARK: Checking

    /// Sweeps a soft gradient across `rects`, left to right.
    func sweep(_ rects: [NSRect]) {
        guard !Self.reduceMotion, let root = layer else { return }
        for (index, rect) in rects.enumerated() {
            let gradient = CAGradientLayer()
            gradient.frame = rect.insetBy(dx: -2, dy: 1)
            gradient.cornerRadius = 3
            gradient.startPoint = CGPoint(x: 0, y: 0.5)
            gradient.endPoint = CGPoint(x: 1, y: 0.5)
            let colour = Self.tint.withAlphaComponent(0.22).cgColor
            let clear = Self.tint.withAlphaComponent(0).cgColor
            gradient.colors = [clear, colour, clear]
            gradient.locations = [-0.4, -0.2, 0]
            root.addSublayer(gradient)

            let duration = 0.32 + 0.0015 * Double(rect.width)
            let move = CABasicAnimation(keyPath: "locations")
            move.fromValue = [-0.4, -0.2, 0]
            move.toValue = [1, 1.2, 1.4]
            move.duration = duration
            move.beginTime = CACurrentMediaTime() + Double(index) * 0.08
            move.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            move.fillMode = .both
            move.isRemovedOnCompletion = false
            gradient.add(move, forKey: "sweep")
            DispatchQueue.main.asyncAfter(deadline: .now() + duration + Double(index) * 0.08 + 0.05) {
                gradient.removeFromSuperlayer()
            }
        }
    }

    // MARK: The partner's cursor

    /// How long the partner's cursor holds a word selected before typing over it, in ms.
    static let selectMs: Double = 180

    private weak var carets: AgentCaretStore?
    private weak var target: WritingPartnerTarget?
    private var subscription: UUID?
    /// The layers of the cursor, its selection, the tint on what changed and the word being typed.
    private var cursorLayers: [CALayer] = []
    /// Whether the last render showed a selection, to grow the next one from its start.
    private var hadSelection = false

    /// Draws the carets in `carets`, in the text of `target`.
    func attach(carets: AgentCaretStore, target: WritingPartnerTarget) {
        if let subscription { self.carets?.unsubscribe(subscription) }
        self.carets = carets
        self.target = target
        subscription = carets.subscribe { [weak self] _ in
            self?.render()
            // Tints of a fix are drawn again once the editor has restyled it
            DispatchQueue.main.async { [weak self] in self?.render(animated: false) }
        }
    }

    /// Redraws the cursor, selection, tint and the word being typed from the director's state.
    func render(animated: Bool = true) {
        guard let root = layer, let carets = carets?.carets, let target, let textView = target.textView,
              let coordinator = target.coordinator else { return }
        frame = textView.bounds
        guard !carets.isEmpty else {
            fadeCursor()
            return
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for layer in cursorLayers { layer.removeFromSuperlayer() }
        cursorLayers = []
        let storage = { (agent: NSRange) -> NSRange in
            coordinator.storageRange(forRaw: target.realRange(forAgent: agent), in: textView)
        }
        var growing: [(CALayer, CGFloat)] = []
        var moving: (CALayer, NSRect, NSRect)?
        var hasSelection = false
        for caret in carets {
            // The tint on what the partner just changed
            for range in caret.changed {
                for rect in Self.rects(for: storage(range), in: textView) {
                    add(fill(rect, alpha: 0.16), to: root)
                }
            }
            // Its selection, grown from the start the first time it shows
            if caret.selection.length > 0 {
                hasSelection = true
                for rect in Self.rects(for: storage(caret.selection), in: textView) {
                    let selection = fill(rect, alpha: 0.22)
                    selection.anchorPoint = CGPoint(x: 0, y: 0.5)
                    selection.frame = rect
                    add(selection, to: root)
                    growing.append((selection, rect.width))
                }
            }
        }
        if let ghost = target.ghost { drawGhost(ghost, in: textView, coordinator: coordinator, root: root) }
        for caret in carets {
            guard let rect = caretRect(atAgent: caret.head, in: textView, coordinator: coordinator, target: target) else { continue }
            let layer = fill(rect, alpha: 1)
            layer.cornerRadius = 1
            add(layer, to: root)
            if caret.selection.length > 0, let start = caretRect(atAgent: caret.selection.location, in: textView,
                                                                 coordinator: coordinator, target: target) {
                moving = (layer, start, rect)
            }
        }
        CATransaction.commit()

        let duration = Self.selectMs / 1000
        if animated, hasSelection, !hadSelection, !Self.reduceMotion {
            for (selection, width) in growing {
                let grow = CABasicAnimation(keyPath: "bounds.size.width")
                grow.fromValue = 0
                grow.toValue = width
                grow.duration = duration
                grow.timingFunction = CAMediaTimingFunction(name: .easeOut)
                selection.add(grow, forKey: "grow")
            }
            if let (caret, start, end) = moving {
                let move = CABasicAnimation(keyPath: "position")
                move.fromValue = CGPoint(x: start.midX, y: start.midY)
                move.toValue = CGPoint(x: end.midX, y: end.midY)
                move.duration = duration
                move.timingFunction = CAMediaTimingFunction(name: .easeOut)
                caret.add(move, forKey: "move")
            }
        }
        hadSelection = hasSelection
    }

    /// The partner's insertion point at `position` (an offset in the director's text): inside or at
    /// the end of the word being typed, it follows the drawn word.
    private func caretRect(atAgent position: Int, in textView: NSTextView, coordinator: SwashTextView.Coordinator,
                           target: WritingPartnerTarget) -> NSRect? {
        if let ghost = target.ghost, let layout = ghostLayout(ghost, in: textView, coordinator: coordinator) {
            let typed = (ghost.text as NSString).length
            let offset = position - ghost.range.location
            if offset >= 0, offset <= typed {
                let prefix = NSAttributedString(string: (ghost.text as NSString).substring(to: offset), attributes: layout.attributes)
                return NSRect(x: layout.origin.x + prefix.size().width - 1, y: layout.line.minY, width: 2, height: layout.line.height)
            }
        }
        let raw = target.realPosition(forAgent: position)
        let location = coordinator.storageRange(forRaw: NSRange(location: raw, length: 0), in: textView).location
        return Self.caretRect(at: location, in: textView)
    }

    /// Where and how the word being typed is drawn: over the word it replaces, in that word's font.
    private func ghostLayout(_ ghost: (range: NSRange, text: String), in textView: NSTextView,
                             coordinator: SwashTextView.Coordinator) -> (origin: NSPoint, line: NSRect, attributes: [NSAttributedString.Key: Any], covered: [NSRect])? {
        guard let storage = textView.textStorage, let layoutManager = textView.layoutManager, storage.length > 0 else { return nil }
        let range = coordinator.storageRange(forRaw: ghost.range, in: textView)
        guard let caret = Self.caretRect(at: range.location, in: textView) else { return nil }
        let index = min(range.location, storage.length - 1)
        var attributes: [NSAttributedString.Key: Any] = [:]
        for key in [NSAttributedString.Key.font, .foregroundColor, .kern] {
            if let value = storage.attribute(key, at: index, effectiveRange: nil) { attributes[key] = value }
        }
        let font = (attributes[.font] as? NSFont) ?? textView.font ?? NSFont.systemFont(ofSize: NSFont.systemFontSize)
        // The baseline of the line the word is on
        let glyph = layoutManager.glyphIndexForCharacter(at: index)
        let fragment = layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
        let baseline = fragment.minY + layoutManager.location(forGlyphAt: glyph).y + textView.textContainerOrigin.y
        let origin = NSPoint(x: caret.minX + 1, y: baseline - font.ascender)
        return (origin, caret, attributes, Self.rects(for: range, in: textView))
    }

    /// Covers the word being replaced and draws what's been typed of the new one in its place.
    private func drawGhost(_ ghost: (range: NSRange, text: String), in textView: NSTextView,
                           coordinator: SwashTextView.Coordinator, root: CALayer) {
        guard let layout = ghostLayout(ghost, in: textView, coordinator: coordinator) else { return }
        let background = textView.drawsBackground ? textView.backgroundColor : NSColor.textBackgroundColor
        for rect in layout.covered {
            let cover = CALayer()
            cover.backgroundColor = background.cgColor
            cover.frame = rect
            add(cover, to: root)
        }
        let text = NSAttributedString(string: ghost.text, attributes: layout.attributes)
        let size = text.size()
        guard size.width > 0, size.height > 0 else { return }
        let scale = window?.backingScaleFactor ?? 2
        let image = NSImage(size: size, flipped: true) { _ in
            text.draw(at: .zero)
            return true
        }
        let typed = CALayer()
        typed.frame = NSRect(origin: layout.origin, size: size)
        typed.contents = image.layerContents(forContentsScale: scale)
        typed.contentsScale = scale
        add(fill(typed.frame.insetBy(dx: -1, dy: 0), alpha: 0.12), to: root)
        add(typed, to: root)
    }

    private func fill(_ rect: NSRect, alpha: CGFloat) -> CALayer {
        let layer = CALayer()
        layer.backgroundColor = Self.tint.withAlphaComponent(alpha).cgColor
        layer.cornerRadius = 2
        layer.frame = rect
        return layer
    }

    private func add(_ layer: CALayer, to root: CALayer) {
        root.addSublayer(layer)
        cursorLayers.append(layer)
    }

    private func fadeCursor() {
        let layers = cursorLayers
        cursorLayers = []
        hadSelection = false
        guard !layers.isEmpty else { return }
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.3)
        CATransaction.setCompletionBlock { layers.forEach { $0.removeFromSuperlayer() } }
        for layer in layers { layer.opacity = 0 }
        CATransaction.commit()
    }
}
#endif

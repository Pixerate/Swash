//
//  WritingPartnerOverlay.swift
//  Swash
//
//  What the writing partner (#61) shows over the Mac editor. It draws in layers over the text view
//  and never touches the text:
//  - a soft gradient that sweeps across the word or line it's checking;
//  - its own insertion point, in the partner's colour, which goes to a word it's fixing, selects it,
//    stays at the end of the fix, then fades.
//  With Reduce Motion on, the sweep is skipped and the cursor and selection only fade.
//

#if os(macOS)
import AppKit
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

    private var caret: CALayer?
    private var selections: [CALayer] = []
    private var blinkWork: DispatchWorkItem?

    /// How long the partner's cursor takes to select what it fixes before the fix lands.
    static var selectDuration: TimeInterval { reduceMotion ? 0 : 0.18 }

    /// Puts the partner's cursor at the start of `ranges` (storage offsets, before the fix) and
    /// selects them, as if it were about to type over them.
    func select(_ ranges: [NSRange], in textView: NSTextView) {
        clearCursor()
        guard let root = layer, let first = ranges.first else { return }
        let duration = Self.selectDuration
        for range in ranges {
            for rect in Self.rects(for: range, in: textView) {
                let selection = CALayer()
                selection.backgroundColor = Self.tint.withAlphaComponent(0.22).cgColor
                selection.cornerRadius = 2
                selection.anchorPoint = CGPoint(x: 0, y: 0.5)
                selection.frame = rect
                root.addSublayer(selection)
                selections.append(selection)
                if duration > 0 {
                    let grow = CABasicAnimation(keyPath: "bounds.size.width")
                    grow.fromValue = 0
                    grow.toValue = rect.width
                    grow.duration = duration
                    grow.timingFunction = CAMediaTimingFunction(name: .easeOut)
                    selection.add(grow, forKey: "grow")
                }
            }
        }
        guard let start = Self.caretRect(at: first.location, in: textView),
              let end = Self.caretRect(at: NSMaxRange(ranges.last ?? first), in: textView) else { return }
        let caret = CALayer()
        caret.backgroundColor = Self.tint.cgColor
        caret.cornerRadius = 1
        caret.frame = end
        root.addSublayer(caret)
        self.caret = caret
        if duration > 0 {
            let move = CABasicAnimation(keyPath: "position")
            move.fromValue = CGPoint(x: start.midX, y: start.midY)
            move.toValue = CGPoint(x: end.midX, y: end.midY)
            move.duration = duration
            move.timingFunction = CAMediaTimingFunction(name: .easeOut)
            caret.add(move, forKey: "move")
        }
    }

    /// The fix landed over `ranges` (storage offsets, after the fix): show it selected for a moment
    /// with the partner's cursor at its end, then fade both.
    func landed(_ ranges: [NSRange], in textView: NSTextView) {
        guard let root = layer else { return }
        for selection in selections { selection.removeFromSuperlayer() }
        selections = []
        for range in ranges {
            for rect in Self.rects(for: range, in: textView) {
                let selection = CALayer()
                selection.backgroundColor = Self.tint.withAlphaComponent(0.22).cgColor
                selection.cornerRadius = 2
                selection.frame = rect
                root.addSublayer(selection)
                selections.append(selection)
            }
        }
        if let last = ranges.last, let end = Self.caretRect(at: NSMaxRange(last), in: textView) {
            if caret == nil {
                let caret = CALayer()
                caret.backgroundColor = Self.tint.cgColor
                caret.cornerRadius = 1
                root.addSublayer(caret)
                self.caret = caret
            }
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            caret?.frame = end
            CATransaction.commit()
        }
        let work = DispatchWorkItem { [weak self] in self?.fadeCursor() }
        blinkWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: work)
    }

    /// The fix didn't land (the text changed under it): take the cursor away.
    func cancel() {
        fadeCursor()
    }

    private func fadeCursor() {
        let layers = selections + (caret.map { [$0] } ?? [])
        selections = []
        caret = nil
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.3)
        CATransaction.setCompletionBlock { layers.forEach { $0.removeFromSuperlayer() } }
        for layer in layers { layer.opacity = 0 }
        CATransaction.commit()
    }

    private func clearCursor() {
        blinkWork?.cancel()
        for layer in selections + (caret.map { [$0] } ?? []) { layer.removeFromSuperlayer() }
        selections = []
        caret = nil
    }
}
#endif

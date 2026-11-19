//
//  WritingPartnerOverlay.swift
//  Swash
//
//  What the writing partner (#61) shows over the Mac editor. It draws in layers over the text view
//  and never touches the text. The look is a Flair text treatment (#100), `ribbon-curl` unless
//  another is chosen in Settings › Writing; this file says where the text is and which stage is
//  playing, and Flair plans and draws it:
//  - `checking`: a sweep across a word or line the partner looked at and left alone;
//  - `caret`: its own insertion point, in the partner's colour and with no name tag, as the editor
//    package's `AgentTextDirector` moves it (#878);
//  - `selecting`, then `typing`: it selects the word it's fixing and types the new word over it
//    (drawn here, not written into the text, until the edit lands);
//  - `landed`: what changed, as the treatment shows it (a ribbon, a tint), until it fades.
//  With Reduce Motion on, Flair holds each stage still and fades it.
//
//  A treatment's layers are either behind the text or above it, so a ribbon can pass under the
//  letters and back over them. The layers above are this view's. The layers behind are drawn by the
//  text view itself, between its background and its glyphs (`SwashLayoutManager.drawBackground`
//  calls `drawUnderText`), because a view over the text can't draw under it.
//

#if os(macOS)
import AppKit
import FlairEffects
import PixerateCore
import QuartzCore

final class WritingPartnerOverlay: NSView {
    /// The partner's colour: its cursor and selection, distinct from the person's.
    static let tint = NSColor.systemPurple

    static var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    override var isFlipped: Bool { true }

    private(set) var suggestionPrompt: SuggestionPromptView?
    private(set) var introductionView: PartnerIntroductionView?
    private(set) var undoReminderView: PartnerUndoReminderView?

    var hasActiveSuggestion: Bool {
        suggestionPrompt != nil && suggestionPrompt?.isHidden == false
    }

    var activeSuggestion: JazzTextSuggestion? {
        suggestionPrompt?.currentSuggestion
    }

    var hasActiveIntroduction: Bool {
        introductionView != nil && introductionView?.isHidden == false
    }

    var hasActiveUndoReminder: Bool {
        undoReminderView != nil && undoReminderView?.isHidden == false
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        if let intro = introductionView, !intro.isHidden {
            let pointInIntro = convert(point, to: intro)
            if intro.bounds.contains(pointInIntro) {
                return intro.hitTest(pointInIntro)
            }
        }
        if let reminder = undoReminderView, !reminder.isHidden {
            let pointInReminder = convert(point, to: reminder)
            if reminder.bounds.contains(pointInReminder) {
                return reminder.hitTest(pointInReminder)
            }
        }
        if let prompt = suggestionPrompt, !prompt.isHidden {
            let pointInPrompt = convert(point, to: prompt)
            if prompt.bounds.contains(pointInPrompt) {
                return prompt.hitTest(pointInPrompt)
            }
        }
        return nil
    }

    init(in textView: NSTextView) {
        super.init(frame: textView.bounds)
        wantsLayer = true
        layer?.masksToBounds = false
        autoresizingMask = [.width, .height]
    }

    required init?(coder: NSCoder) { nil }

    // MARK: Structural Suggestion Prompt

    /// Shows an inline prompt for a structural suggestion (`suggestion`) positioned near `rect`.
    func showSuggestionPrompt(
        suggestion: JazzTextSuggestion,
        at rect: NSRect,
        onAccept: @escaping () -> Void,
        onDismiss: @escaping () -> Void
    ) {
        let prompt: SuggestionPromptView
        if let existing = suggestionPrompt {
            prompt = existing
        } else {
            prompt = SuggestionPromptView(frame: .zero)
            addSubview(prompt)
            suggestionPrompt = prompt
        }

        prompt.configure(with: suggestion, onAccept: onAccept, onDismiss: onDismiss)
        let size = SuggestionPromptView.preferredSize(for: suggestion)

        let margin: CGFloat = 12
        let originX = max(margin, min(rect.minX, bounds.width - size.width - margin))
        var originY = rect.maxY + 4
        if originY + size.height > bounds.height - margin {
            originY = max(margin, rect.minY - size.height - 4)
        }

        prompt.frame = NSRect(origin: NSPoint(x: originX, y: originY), size: size)
        prompt.isHidden = false

        if Self.reduceMotion {
            prompt.alphaValue = 1.0
        } else {
            prompt.alphaValue = 0.0
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.18
                prompt.animator().alphaValue = 1.0
            }
        }
    }

    /// Hides and removes the active structural suggestion prompt.
    func hideSuggestionPrompt() {
        guard let prompt = suggestionPrompt, !prompt.isHidden else { return }
        if Self.reduceMotion {
            prompt.isHidden = true
            prompt.removeFromSuperview()
            suggestionPrompt = nil
        } else {
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = 0.15
                prompt.animator().alphaValue = 0.0
            }, completionHandler: { [weak self, weak prompt] in
                prompt?.isHidden = true
                prompt?.removeFromSuperview()
                if self?.suggestionPrompt === prompt {
                    self?.suggestionPrompt = nil
                }
            })
        }
    }

    // MARK: First-Run Introduction & First-Undo Reminder (#112)

    /// Shows the in-place first-run introduction note near `rect`.
    func showIntroduction(
        at rect: NSRect,
        onChooseMode: @escaping (WritingPartnerMode) -> Void,
        onDismiss: @escaping () -> Void
    ) {
        let intro: PartnerIntroductionView
        if let existing = introductionView {
            intro = existing
        } else {
            intro = PartnerIntroductionView(frame: .zero)
            addSubview(intro)
            introductionView = intro
        }

        intro.configure(onChooseMode: onChooseMode, onDismiss: onDismiss)
        let size = PartnerIntroductionView.preferredSize
        let margin: CGFloat = 12
        let originX = max(margin, min(rect.minX, max(margin, bounds.width - size.width - margin)))
        var originY = rect.maxY + 8
        if originY + size.height > bounds.height - margin {
            originY = max(margin, rect.minY - size.height - 8)
        }
        intro.frame = NSRect(origin: NSPoint(x: originX, y: originY), size: size)
        intro.layoutSubtreeIfNeeded()
        intro.isHidden = false
        intro.alphaValue = 1.0
        intro.startSamplePreview()
    }

    /// Hides and removes the first-run introduction note.
    func hideIntroduction() {
        guard let intro = introductionView else { return }
        intro.isHidden = true
        intro.removeFromSuperview()
        introductionView = nil
    }

    /// Shows a quiet, non-modal reminder the first time a partner fix is undone.
    func showUndoReminder(
        at rect: NSRect,
        onPause: @escaping () -> Void,
        onDismiss: @escaping () -> Void
    ) {
        let reminder: PartnerUndoReminderView
        if let existing = undoReminderView {
            reminder = existing
        } else {
            reminder = PartnerUndoReminderView(frame: .zero)
            addSubview(reminder)
            undoReminderView = reminder
        }

        reminder.configure(onPause: onPause, onDismiss: onDismiss)
        let size = PartnerUndoReminderView.preferredSize
        let margin: CGFloat = 12
        let originX = max(margin, min(rect.minX, max(margin, bounds.width - size.width - margin)))
        var originY = rect.maxY + 6
        if originY + size.height > bounds.height - margin {
            originY = max(margin, rect.minY - size.height - 6)
        }
        reminder.frame = NSRect(origin: NSPoint(x: originX, y: originY), size: size)
        reminder.layoutSubtreeIfNeeded()
        reminder.isHidden = false
        reminder.alphaValue = 1.0
    }

    /// Hides and removes the first-undo reminder.
    func hideUndoReminder() {
        guard let reminder = undoReminderView else { return }
        reminder.isHidden = true
        reminder.removeFromSuperview()
        undoReminderView = nil
    }

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

    // MARK: The treatment

    /// The chosen treatment with the partner's values, resolved once for a style and appearance.
    struct Look {
        let id: String
        let dark: Bool
        let stages: FlairJSON

        func plan(_ stage: FlairTextTreatmentStage, at time: Double, over target: FlairTreatmentTarget) -> FlairTextTreatmentPlan {
            FlairTextTreatments.planResolved(stages, stage: stage, time: max(0, time), target: target,
                                             reduceMotion: WritingPartnerOverlay.reduceMotion)
        }
    }

    /// The look for a treatment id (the default when it's unknown) in a light or dark appearance:
    /// the partner's colour, the treatment's dark variant where it has one, and no name tag.
    static func look(id: String, dark: Bool) -> Look? {
        guard let treatment = FlairTextTreatments.treatment(id: id)
                ?? FlairTextTreatments.treatment(id: WritingPartnerDefaults.defaultStyle)
                ?? FlairTextTreatments.all.first else { return nil }
        let values = treatment.values(values: [
            "color": .string(rgba(tint)?.hex ?? "#AF52DE"),
            "darkTheme": .bool(dark),
            "nameTag": .bool(false),
        ])
        return Look(id: treatment.id, dark: dark, stages: FlairTextTreatments.resolve(treatment, values: values))
    }

    static func isDark(_ view: NSView) -> Bool {
        view.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    }

    static func rgba(_ color: NSColor?) -> FlairRGBA? {
        guard let c = color?.usingColorSpace(.sRGB) else { return nil }
        return FlairRGBA(Double(c.redComponent), Double(c.greenComponent), Double(c.blueComponent), Double(c.alphaComponent))
    }

    /// A colour as `view` shows it. A system colour (the text's, the page's) read outside a drawing
    /// pass resolves in the appearance the thread last drew in, which need not be the view's.
    static func rgba(_ color: NSColor?, in view: NSView) -> FlairRGBA? {
        var resolved: FlairRGBA?
        view.effectiveAppearance.performAsCurrentDrawingAppearance { resolved = rgba(color) }
        return resolved
    }

    nonisolated static func caret(_ rect: NSRect) -> FlairTreatmentCaret {
        FlairTreatmentCaret(x: Double(rect.midX), y: Double(rect.minY), height: Double(rect.height))
    }

    private let renderer = FlairTextTreatmentRenderer()
    private var look: Look?

    // MARK: Under the text

    /// The overlay of `textView`, if it has one.
    static func existing(in textView: NSTextView) -> WritingPartnerOverlay? {
        textView.subviews.lazy.compactMap { $0 as? WritingPartnerOverlay }.first
    }

    /// Whether the text view draws the layers behind its text itself (the editor's own layout
    /// manager does). Elsewhere they go in this view, over the text and under the layers above.
    private(set) var drawsUnderText = false
    /// What the layers behind the text last covered, to have the text view draw it again.
    private var underRect: NSRect = .zero

    /// Draws the layers that go behind the text, in the text view's coordinates. Called by the
    /// layout manager after the background and before the glyphs.
    func drawUnderText(in context: CGContext) {
        guard drawsUnderText, !(renderer.behindLayer.sublayers ?? []).isEmpty else { return }
        context.saveGState()
        renderer.behindLayer.render(in: context)
        context.restoreGState()
    }

    /// Has the text view draw again where the layers behind its text are, and were.
    private func redrawUnderText(_ plans: [FlairTextTreatmentPlan], in textView: NSTextView) {
        var rect = NSRect.zero
        for layer in plans.flatMap(\.layers) where layer.z == "behind" {
            // Room for a glow, and for a ribbon's edge
            rect = rect.union(layer.frame.insetBy(dx: -((layer.glow ?? 0) + 6), dy: -((layer.glow ?? 0) + 6)))
        }
        let dirty = rect.union(underRect)
        underRect = rect
        if !dirty.isEmpty { textView.setNeedsDisplay(dirty) }
    }

    /// The look for the chosen style and the text view's appearance, resolved again when either changes.
    private func currentLook(in textView: NSTextView) -> Look? {
        let id = WritingPartnerDefaults.style()
        let dark = Self.isDark(textView)
        if let look, look.dark == dark, look.id == id || FlairTextTreatments.treatment(id: id) == nil { return look }
        look = Self.look(id: id, dark: dark)
        return look
    }

    // MARK: Stages

    /// A stage that plays to its end on its own: a `checking` sweep, or a `landed` fix.
    private struct Playback {
        let stage: FlairTextTreatmentStage
        let start: Double
        var target: FlairTreatmentTarget
        /// The raw range of a landed fix, to follow its rectangles while the director still reports it.
        var range: NSRange?
    }

    private var playbacks: [Playback] = []
    /// When the partner's cursor, its selection and its typing each began, in ms.
    private var caretStart: Double?
    private var selectStart: Double?
    private var typingStart: Double?
    private var timer: Timer?

    private static var now: Double { CACurrentMediaTime() * 1000 }

    /// Sweeps across `rects`: what the partner looked at and left alone.
    func sweep(_ rects: [NSRect]) {
        guard !rects.isEmpty else { return }
        playbacks.append(Playback(stage: .checking, start: Self.now, target: FlairTreatmentTarget(lines: rects)))
        render()
    }

    // MARK: Suggestions

    /// Layers drawn for active suggestions in Suggest mode (#103), without touching the text storage.
    private(set) var suggestionLayers: [CALayer] = []

    /// Draws a subtle tint and underline on each suggested word's rectangles, or clears them when empty.
    func showSuggestions(_ rects: [NSRect]) {
        guard let root = layer else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for layer in suggestionLayers { layer.removeFromSuperlayer() }
        suggestionLayers = []
        for rect in rects {
            let container = CALayer()
            container.backgroundColor = Self.tint.withAlphaComponent(0.10).cgColor
            container.cornerRadius = 2
            container.frame = rect
            let underline = CALayer()
            underline.backgroundColor = Self.tint.withAlphaComponent(0.65).cgColor
            underline.cornerRadius = 1
            underline.frame = NSRect(x: 0, y: max(0, rect.height - 2), width: rect.width, height: 2)
            container.addSublayer(underline)
            root.addSublayer(container)
            suggestionLayers.append(container)
        }
        CATransaction.commit()
    }

    // MARK: The partner's cursor

    /// How long the partner's cursor holds a word selected before typing over it, in ms. The
    /// treatments' `selecting` stage takes as long, so typing starts as the selection finishes.
    static let selectMs: Double = 180

    private weak var carets: AgentCaretStore?
    private weak var target: WritingPartnerTarget?
    private var subscription: UUID?

    /// Draws the carets in `carets`, in the text of `target`.
    func attach(carets: AgentCaretStore, target: WritingPartnerTarget) {
        if let subscription { self.carets?.unsubscribe(subscription) }
        self.carets = carets
        self.target = target
        subscription = carets.subscribe { [weak self] _ in
            self?.render()
            // What a fix changed is measured again once the editor has restyled it
            DispatchQueue.main.async { [weak self] in self?.render() }
        }
    }

    /// Redraws every playing stage from the director's state, and keeps drawing while any plays.
    func render(animated: Bool = true) {
        draw()
        if timer == nil, isPlaying {
            let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
                guard let self else { return }
                self.draw()
                if !self.isPlaying { self.stop() }
            }
            RunLoop.main.add(timer, forMode: .common)
            self.timer = timer
        }
    }

    private var isPlaying: Bool { !playbacks.isEmpty || !(carets?.carets.isEmpty ?? true) }

    private func stop() {
        timer?.invalidate()
        timer = nil
        clear()
    }

    /// Removes everything drawn, over the text and under it.
    private func clear() {
        renderer.clear()
        renderer.behindLayer.removeFromSuperlayer()
        renderer.aboveLayer.removeFromSuperlayer()
        if let textView = target?.textView ?? (superview as? NSTextView) { redrawUnderText([], in: textView) }
    }

    /// One frame: the plan of every stage at this moment, drawn by Flair's renderer.
    private func draw() {
        guard let textView = target?.textView ?? (superview as? NSTextView) else { return }
        // Colours are read in the text view's own appearance. A system colour (the text's, the
        // page's, the partner's tint) read from a timer resolves in whatever appearance happens to
        // be current, which is not the window's: in Light Mode the old word was then covered in
        // the Dark Mode page colour while the new one was typed.
        textView.effectiveAppearance.performAsCurrentDrawingAppearance {
            self.drawFrame(in: textView)
        }
    }

    private func drawFrame(in textView: NSTextView) {
        guard let root = layer, let look = currentLook(in: textView) else { return }
        frame = textView.bounds
        let now = Self.now
        var plans: [FlairTextTreatmentPlan] = []
        var font: NSFont?

        // The partner's cursor: its selection, or the word it is typing, and the caret
        var live: [FlairTextTreatmentPlan] = []
        let carets = self.carets?.carets ?? []
        if carets.isEmpty {
            caretStart = nil
            selectStart = nil
            typingStart = nil
        } else if let target, let coordinator = target.coordinator {
            caretStart = caretStart ?? now
            let storage = { (agent: NSRange) -> NSRange in
                coordinator.storageRange(forRaw: target.realRange(forAgent: agent), in: textView)
            }
            for caret in carets {
                let head = caretRect(atAgent: caret.head, in: textView, coordinator: coordinator, target: target).map(Self.caret)
                // What it just changed: the `landed` stage starts, and runs on after the cursor has gone
                for range in caret.changed {
                    let lines = Self.rects(for: storage(range), in: textView)
                    guard !lines.isEmpty else { continue }
                    let end = Self.caretRect(at: NSMaxRange(storage(range)), in: textView).map(Self.caret)
                    let landed = FlairTreatmentTarget(lines: lines, caret: end ?? head)
                    if let index = playbacks.firstIndex(where: { $0.stage == .landed && $0.range == range }) {
                        playbacks[index].target = landed
                    } else {
                        playbacks.append(Playback(stage: .landed, start: now, target: landed, range: range))
                    }
                }
                if let ghost = target.ghost, let layout = ghostLayout(ghost, in: textView, coordinator: coordinator) {
                    // Typing begins while the selection still shows, so nothing is drawn behind the word twice
                    typingStart = typingStart ?? now
                    font = layout.attributes[.font] as? NSFont
                    let background = textView.drawsBackground ? textView.backgroundColor : NSColor.textBackgroundColor
                    let typing = FlairTreatmentTarget(lines: layout.covered, caret: head, text: ghost.text,
                                                      color: Self.rgba(layout.attributes[.foregroundColor] as? NSColor ?? textView.textColor, in: textView),
                                                      background: Self.rgba(background, in: textView))
                    live.append(look.plan(.typing, at: now - (typingStart ?? now), over: typing))
                } else if caret.selection.length > 0 {
                    typingStart = nil
                    selectStart = selectStart ?? now
                    let lines = Self.rects(for: storage(caret.selection), in: textView)
                    live.append(look.plan(.selecting, at: now - (selectStart ?? now), over: FlairTreatmentTarget(lines: lines, caret: head)))
                } else {
                    selectStart = nil
                    typingStart = nil
                }
                if let head {
                    live.append(look.plan(.caret, at: now - (caretStart ?? now), over: FlairTreatmentTarget(caret: head)))
                }
            }
        }

        // Sweeps and landed fixes, until each is done
        playbacks.removeAll { playback in
            let plan = look.plan(playback.stage, at: now - playback.start, over: playback.target)
            if plan.done { return true }
            plans.append(plan)
            return false
        }
        plans += live

        guard !plans.isEmpty else {
            clear()
            return
        }
        drawsUnderText = textView.layoutManager is SwashLayoutManager
        if drawsUnderText {
            renderer.behindLayer.removeFromSuperlayer()
        } else if renderer.behindLayer.superlayer == nil {
            // A text view that only draws its own text: both go over it, the "behind" layers first
            root.insertSublayer(renderer.behindLayer, at: 0)
        }
        if renderer.aboveLayer.superlayer == nil { root.addSublayer(renderer.aboveLayer) }
        renderer.contentsScale = window?.backingScaleFactor ?? 2
        renderer.draw(plans, font: font)
        if drawsUnderText { redrawUnderText(plans, in: textView) }
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

    /// Where the word being typed goes: over the word it replaces (`covered`), in that word's font.
    private func ghostLayout(_ ghost: (range: NSRange, text: String), in textView: NSTextView,
                             coordinator: SwashTextView.Coordinator) -> (origin: NSPoint, line: NSRect, attributes: [NSAttributedString.Key: Any], covered: [NSRect])? {
        guard let storage = textView.textStorage, storage.length > 0 else { return nil }
        let range = coordinator.storageRange(forRaw: ghost.range, in: textView)
        guard let caret = Self.caretRect(at: range.location, in: textView) else { return nil }
        let index = min(range.location, storage.length - 1)
        var attributes: [NSAttributedString.Key: Any] = [:]
        for key in [NSAttributedString.Key.font, .foregroundColor, .kern] {
            if let value = storage.attribute(key, at: index, effectiveRange: nil) { attributes[key] = value }
        }
        return (NSPoint(x: caret.minX + 1, y: caret.minY), caret, attributes, Self.rects(for: range, in: textView))
    }
}

private extension FlairRGBA {
    var hex: String {
        String(format: "#%02X%02X%02X", Int((r * 255).rounded()), Int((g * 255).rounded()), Int((b * 255).rounded()))
    }
}

// MARK: - Suggestion Prompt View

/// The inline prompt for structural suggestions ("make this a list", heading, math, alert, title).
/// Accessible by keyboard (Tab to accept, Esc to dismiss) and VoiceOver.
@MainActor
final class SuggestionPromptView: NSView {
    private let titleLabel = NSTextField(labelWithString: "")
    private let whyLabel = NSTextField(labelWithString: "")
    private let acceptButton = NSButton(title: "Accept ⇥", target: nil, action: nil)
    private let dismissButton = NSButton(title: "Dismiss ⎋", target: nil, action: nil)
    private let iconView = NSImageView()

    var onAccept: (() -> Void)?
    var onDismiss: (() -> Void)?
    private(set) var currentSuggestion: JazzTextSuggestion?

    override var isFlipped: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        setup()
    }

    required init?(coder: NSCoder) { nil }

    private func setup() {
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.borderWidth = 1
        layer?.borderColor = WritingPartnerOverlay.tint.withAlphaComponent(0.4).cgColor
        layer?.backgroundColor = NSColor.windowBackgroundColor.withAlphaComponent(0.96).cgColor
        shadow = NSShadow()
        shadow?.shadowColor = NSColor.black.withAlphaComponent(0.18)
        shadow?.shadowOffset = NSSize(width: 0, height: -2)
        shadow?.shadowBlurRadius = 8

        // Accessibility: group role with full descriptions
        setAccessibilityElement(true)
        setAccessibilityRole(.group)

        // Icon
        iconView.imageScaling = .scaleProportionallyDown
        iconView.contentTintColor = WritingPartnerOverlay.tint
        addSubview(iconView)

        // Title
        titleLabel.font = NSFont.systemFont(ofSize: 12, weight: .semibold)
        titleLabel.textColor = NSColor.labelColor
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.isBezeled = false
        titleLabel.isEditable = false
        titleLabel.drawsBackground = false
        addSubview(titleLabel)

        // Why
        whyLabel.font = NSFont.systemFont(ofSize: 11, weight: .regular)
        whyLabel.textColor = NSColor.secondaryLabelColor
        whyLabel.lineBreakMode = .byTruncatingTail
        whyLabel.isBezeled = false
        whyLabel.isEditable = false
        whyLabel.drawsBackground = false
        addSubview(whyLabel)

        // Accept Button
        acceptButton.bezelStyle = .rounded
        acceptButton.target = self
        acceptButton.action = #selector(acceptClicked)
        acceptButton.keyEquivalent = "\t"
        acceptButton.toolTip = "Accept suggestion (Tab)"
        acceptButton.contentTintColor = WritingPartnerOverlay.tint
        acceptButton.setAccessibilityElement(true)
        acceptButton.setAccessibilityRole(.button)
        acceptButton.setAccessibilityLabel("Accept suggestion")
        addSubview(acceptButton)

        // Dismiss Button
        dismissButton.bezelStyle = .rounded
        dismissButton.target = self
        dismissButton.action = #selector(dismissClicked)
        dismissButton.keyEquivalent = "\u{1b}"
        dismissButton.toolTip = "Dismiss suggestion (Escape)"
        dismissButton.setAccessibilityElement(true)
        dismissButton.setAccessibilityRole(.button)
        dismissButton.setAccessibilityLabel("Dismiss suggestion")
        addSubview(dismissButton)
    }

    @objc private func acceptClicked() {
        onAccept?()
    }

    @objc private func dismissClicked() {
        onDismiss?()
    }

    func configure(
        with suggestion: JazzTextSuggestion,
        onAccept: @escaping () -> Void,
        onDismiss: @escaping () -> Void
    ) {
        self.currentSuggestion = suggestion
        self.onAccept = onAccept
        self.onDismiss = onDismiss

        titleLabel.stringValue = suggestion.kind.title
        whyLabel.stringValue = suggestion.why

        let symbolName: String
        switch suggestion.kind {
        case .list: symbolName = "list.bullet"
        case .heading: symbolName = "textformat.size"
        case .math: symbolName = "function"
        case .title: symbolName = "textformat.characters"
        case .alert: symbolName = "exclamationmark.triangle"
        case .quote: symbolName = "quote.opening"
        case .spelling, .wrongWord: symbolName = "textformat.abc"
        case .houseStyle: symbolName = "person.2"
        case .tone: symbolName = "waveform"
        }
        iconView.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: suggestion.kind.title)

        setAccessibilityLabel("Writing partner suggestion: \(suggestion.kind.title). \(suggestion.why). Press Tab to accept, Escape to dismiss.")
        setAccessibilityChildren([titleLabel, whyLabel, acceptButton, dismissButton])
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let padX: CGFloat = 10
        let padY: CGFloat = 7
        let iconSize: CGFloat = 18

        iconView.frame = NSRect(x: padX, y: (bounds.height - iconSize) / 2, width: iconSize, height: iconSize)

        let buttonH: CGFloat = 22
        let dismissW: CGFloat = 78
        let acceptW: CGFloat = 84

        let buttonsX = bounds.width - padX - dismissW - 6 - acceptW
        acceptButton.frame = NSRect(x: buttonsX, y: (bounds.height - buttonH) / 2, width: acceptW, height: buttonH)
        dismissButton.frame = NSRect(x: bounds.width - padX - dismissW, y: (bounds.height - buttonH) / 2, width: dismissW, height: buttonH)

        let textX = iconView.frame.maxX + 8
        let textW = max(50, buttonsX - textX - 8)

        if whyLabel.stringValue.isEmpty {
            titleLabel.frame = NSRect(x: textX, y: (bounds.height - 16) / 2, width: textW, height: 16)
            whyLabel.frame = .zero
        } else {
            titleLabel.frame = NSRect(x: textX, y: padY, width: textW, height: 15)
            whyLabel.frame = NSRect(x: textX, y: titleLabel.frame.maxY + 1, width: textW, height: 14)
        }
    }

    static func preferredSize(for suggestion: JazzTextSuggestion) -> NSSize {
        let titleW = (suggestion.kind.title as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 12, weight: .semibold)]).width
        let whyW = (suggestion.why as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 11, weight: .regular)]).width
        let textW = max(titleW, whyW)
        let totalW = max(320, min(500, 10 + 18 + 8 + textW + 12 + 84 + 6 + 78 + 10))
        let height: CGFloat = suggestion.why.isEmpty ? 36 : 46
        return NSSize(width: totalW, height: height)
    }
}

// MARK: - Sample Sentence Preview View (#100, #112)

/// A sample sentence with one wrong word, fixed by the partner's cursor in the chosen style.
/// Used in Settings › Writing (looping) and in the first-run introduction (#112, playing one sample fix).
final class WritingPartnerStylePreviewView: NSView {
    static let before = "It fixes the odd "
    static let wrong = "wrod"
    static let right = "word"
    static let after = " as you write."

    /// The script, in ms: the cursor arrives, selects the word, types the new one a letter at a
    /// time, the fix lands and stays, then (when `loops` is true) it starts again.
    private static let selectAt: Double = 700
    private static let typeMs: Double = 70
    private static let hold: Double = 2600

    static var sampleFixDurationMs: Double {
        selectAt + WritingPartnerOverlay.selectMs + typeMs * Double(right.count + 1)
    }

    var style = WritingPartnerDefaults.defaultStyle {
        didSet { if style != oldValue { look = nil; start = WritingPartnerStylePreviewView.now } }
    }

    /// True in Settings › Writing (repeats forever); false in the first-run introduction (plays once and holds).
    var loops = true

    /// The sentence currently shown in the sample layer.
    private(set) var currentSampleText: String = before + wrong + after
    /// True once the sample fix has finished typing and landed.
    private(set) var hasCompletedSampleFix = false

    private let renderer = FlairTextTreatmentRenderer()
    private let label = CATextLayer()
    private var look: WritingPartnerOverlay.Look?
    private var start = WritingPartnerStylePreviewView.now
    private var timer: Timer?
    private let font = NSFont.systemFont(ofSize: 15)

    private static var now: Double { CACurrentMediaTime() * 1000 }

    override var isFlipped: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 8
        label.font = font
        label.fontSize = font.pointSize
        label.actions = ["contents": NSNull(), "string": NSNull(), "foregroundColor": NSNull()]
        layer?.addSublayer(renderer.behindLayer)
        layer?.addSublayer(label)
        layer?.addSublayer(renderer.aboveLayer)
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        setAccessibilityLabel("Sample fix: \(Self.before)\(Self.wrong)\(Self.after) becomes \(Self.before)\(Self.right)\(Self.after)")
    }

    required init?(coder: NSCoder) { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        restartAnimation()
    }

    func restartAnimation() {
        timer?.invalidate()
        timer = nil
        start = Self.now
        hasCompletedSampleFix = false
        draw()
        guard window != nil else { return }
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in self?.draw() }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        look = nil
    }

    private func width(_ text: String) -> CGFloat {
        NSAttributedString(string: text, attributes: [.font: font]).size().width
    }

    func draw(elapsedOverrideMs: Double? = nil) {
        let dark = WritingPartnerOverlay.isDark(self)
        if look == nil { look = WritingPartnerOverlay.look(id: style, dark: dark) }
        guard let look else { return }
        var background = NSColor.textBackgroundColor
        var ink = NSColor.textColor
        effectiveAppearance.performAsCurrentDrawingAppearance {
            background = NSColor.textBackgroundColor.usingColorSpace(.sRGB) ?? background
            ink = NSColor.textColor.usingColorSpace(.sRGB) ?? ink
        }
        layer?.backgroundColor = background.cgColor

        let lineHeight = NSLayoutManager().defaultLineHeight(for: font)
        let origin = NSPoint(x: 14, y: max(4, (bounds.height - lineHeight) / 2))
        let wordX = origin.x + width(Self.before)
        let line = { (word: String) in NSRect(x: wordX, y: origin.y, width: self.width(word), height: lineHeight) }
        let caret = { (x: CGFloat) in FlairTreatmentCaret(x: Double(x), y: Double(origin.y), height: Double(lineHeight)) }

        let typeEnd = Self.sampleFixDurationMs
        var time = elapsedOverrideMs ?? (Self.now - start)
        if loops && time > typeEnd + Self.hold {
            start = Self.now
            time = 0
        }

        var plans: [FlairTextTreatmentPlan] = []
        var shown = Self.wrong
        if time < Self.selectAt {
            plans.append(look.plan(.caret, at: time, over: FlairTreatmentTarget(caret: caret(wordX + width(Self.wrong)))))
        } else if time < Self.selectAt + WritingPartnerOverlay.selectMs {
            let target = FlairTreatmentTarget(lines: [line(Self.wrong)], caret: caret(wordX + width(Self.wrong)))
            plans.append(look.plan(.selecting, at: time - Self.selectAt, over: target))
            plans.append(look.plan(.caret, at: time, over: FlairTreatmentTarget(caret: target.caret)))
        } else if time < typeEnd {
            let typing = time - Self.selectAt - WritingPartnerOverlay.selectMs
            let typed = String(Self.right.prefix(min(Self.right.count, Int(typing / Self.typeMs))))
            let head = caret(wordX + width(typed))
            let target = FlairTreatmentTarget(lines: [line(Self.wrong)], caret: head, text: typed,
                                              color: WritingPartnerOverlay.rgba(ink), background: WritingPartnerOverlay.rgba(background))
            plans.append(look.plan(.typing, at: typing, over: target))
            plans.append(look.plan(.caret, at: time, over: FlairTreatmentTarget(caret: head)))
        } else {
            shown = Self.right
            hasCompletedSampleFix = true
            let target = FlairTreatmentTarget(lines: [line(Self.right)], caret: caret(wordX + width(Self.right)))
            let landed = look.plan(.landed, at: time - typeEnd, over: target)
            if !landed.done {
                plans.append(landed)
            } else if !loops {
                timer?.invalidate()
                timer = nil
            }
        }

        let fullString = Self.before + shown + Self.after
        currentSampleText = fullString
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        label.contentsScale = window?.backingScaleFactor ?? 2
        label.foregroundColor = ink.cgColor
        label.string = fullString
        label.frame = NSRect(x: origin.x, y: origin.y, width: max(120, bounds.width - origin.x * 2), height: lineHeight + 2)
        CATransaction.commit()
        renderer.contentsScale = label.contentsScale
        renderer.draw(plans, font: font)
    }
}

// MARK: - First-Run Introduction View (#112)

/// In-place, non-modal introduction shown once per install the first time a document is edited.
/// Plays one sample fix on a sample sentence before the partner touches the user's words, states
/// plainly that default rules run on the device, and offers Automatically, Suggest, and Not now.
@MainActor
final class PartnerIntroductionView: NSView {
    static let noteText = "Swash can tidy up behind you as you type"
    nonisolated static let privacyText = "Punctuation and spelling rules run on your Mac and never leave this device."
    /// Signed in, the pause tier sends the paragraph to Pixerate (docs/writing-partner-privacy.md),
    /// so the introduction says so before the person chooses.
    nonisolated static let signedInPrivacyText = "Fixes as you type run on your Mac. Because you're signed in, the paragraph you pause on is also sent to Pixerate for suggestions."

    nonisolated static func privacyText(signedIn: Bool) -> String {
        signedIn ? signedInPrivacyText : privacyText
    }

    static let preferredSize = NSSize(width: 420, height: 146)

    let titleLabel = NSTextField(labelWithString: PartnerIntroductionView.noteText)
    let sampleView = WritingPartnerStylePreviewView(frame: .zero)
    let privacyLabel = NSTextField(wrappingLabelWithString: PartnerIntroductionView.privacyText)
    let automaticallyButton = NSButton(title: "Automatically", target: nil, action: nil)
    let suggestButton = NSButton(title: "Suggest", target: nil, action: nil)
    let notNowButton = NSButton(title: "Not now", target: nil, action: nil)
    private let iconView = NSImageView()

    var onChooseMode: ((WritingPartnerMode) -> Void)?
    var onDismiss: (() -> Void)?

    override var isFlipped: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        setup()
    }

    required init?(coder: NSCoder) { nil }

    private func setup() {
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.borderWidth = 1
        layer?.borderColor = WritingPartnerOverlay.tint.withAlphaComponent(0.45).cgColor
        layer?.backgroundColor = NSColor.windowBackgroundColor.withAlphaComponent(0.97).cgColor
        shadow = NSShadow()
        shadow?.shadowColor = NSColor.black.withAlphaComponent(0.18)
        shadow?.shadowOffset = NSSize(width: 0, height: -2)
        shadow?.shadowBlurRadius = 10

        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityIdentifier("WritingPartnerIntroductionView")

        iconView.image = NSImage(systemSymbolName: "character.cursor.ibeam", accessibilityDescription: "Writing partner")
        iconView.imageScaling = .scaleProportionallyDown
        iconView.contentTintColor = WritingPartnerOverlay.tint
        addSubview(iconView)

        titleLabel.font = NSFont.systemFont(ofSize: 13, weight: .semibold)
        titleLabel.textColor = NSColor.labelColor
        titleLabel.isBezeled = false
        titleLabel.isEditable = false
        titleLabel.drawsBackground = false
        addSubview(titleLabel)

        sampleView.loops = false
        sampleView.style = WritingPartnerDefaults.style()
        sampleView.layer?.borderWidth = 1
        sampleView.layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.5).cgColor
        addSubview(sampleView)

        privacyLabel.font = NSFont.systemFont(ofSize: 11, weight: .regular)
        privacyLabel.textColor = NSColor.secondaryLabelColor
        privacyLabel.isBezeled = false
        privacyLabel.isEditable = false
        privacyLabel.drawsBackground = false
        addSubview(privacyLabel)

        automaticallyButton.bezelStyle = .rounded
        automaticallyButton.target = self
        automaticallyButton.action = #selector(automaticallyClicked)
        // No Return key equivalent: Return while writing must start a new line, never opt in
        automaticallyButton.contentTintColor = WritingPartnerOverlay.tint
        automaticallyButton.toolTip = "Turn on the writing partner in Automatically mode (⌥Return)"
        automaticallyButton.setAccessibilityElement(true)
        automaticallyButton.setAccessibilityRole(.button)
        automaticallyButton.setAccessibilityLabel("Turn on Automatically")
        automaticallyButton.setAccessibilityIdentifier("IntroAutomaticallyButton")
        addSubview(automaticallyButton)

        suggestButton.bezelStyle = .rounded
        suggestButton.target = self
        suggestButton.action = #selector(suggestClicked)
        suggestButton.toolTip = "Offer fixes as underlined suggestions without changing text automatically"
        suggestButton.setAccessibilityElement(true)
        suggestButton.setAccessibilityRole(.button)
        suggestButton.setAccessibilityLabel("Turn on Suggest")
        suggestButton.setAccessibilityIdentifier("IntroSuggestButton")
        addSubview(suggestButton)

        notNowButton.bezelStyle = .rounded
        notNowButton.target = self
        notNowButton.action = #selector(notNowClicked)
        notNowButton.keyEquivalent = "\u{1b}"
        notNowButton.toolTip = "Keep the writing partner off for now (Escape)"
        notNowButton.setAccessibilityElement(true)
        notNowButton.setAccessibilityRole(.button)
        notNowButton.setAccessibilityLabel("Not now")
        notNowButton.setAccessibilityIdentifier("IntroNotNowButton")
        addSubview(notNowButton)

        setAccessibilityLabel("\(Self.noteText). \(Self.privacyText) Choose Automatically, Suggest, or Not now.")
        setAccessibilityChildren([titleLabel, sampleView, privacyLabel, automaticallyButton, suggestButton, notNowButton])
    }

    func configure(
        onChooseMode: @escaping (WritingPartnerMode) -> Void,
        onDismiss: @escaping () -> Void
    ) {
        self.onChooseMode = onChooseMode
        self.onDismiss = onDismiss
        sampleView.style = WritingPartnerDefaults.style()
        let privacy = Self.privacyText(signedIn: WritingPartnerDefaults.provider() == .pixerate)
        privacyLabel.stringValue = privacy
        setAccessibilityLabel("\(Self.noteText). \(privacy) Choose Automatically, Suggest, or Not now.")
        needsLayout = true
    }

    func startSamplePreview() {
        sampleView.restartAnimation()
    }

    @objc private func automaticallyClicked() {
        onChooseMode?(.automatic)
    }

    @objc private func suggestClicked() {
        onChooseMode?(.suggest)
    }

    @objc private func notNowClicked() {
        onDismiss?()
    }

    override func layout() {
        super.layout()
        let padX: CGFloat = 12
        let padY: CGFloat = 10
        let iconSize: CGFloat = 16

        iconView.frame = NSRect(x: padX, y: padY + 1, width: iconSize, height: iconSize)
        titleLabel.frame = NSRect(x: iconView.frame.maxX + 6, y: padY, width: bounds.width - iconView.frame.maxX - 6 - padX, height: 18)

        let sampleY = titleLabel.frame.maxY + 6
        sampleView.frame = NSRect(x: padX, y: sampleY, width: bounds.width - padX * 2, height: 38)

        let privacyY = sampleView.frame.maxY + 6
        privacyLabel.frame = NSRect(x: padX, y: privacyY, width: bounds.width - padX * 2, height: 28)

        let buttonH: CGFloat = 24
        let buttonY = bounds.height - padY - buttonH
        let notNowW: CGFloat = 76
        let suggestW: CGFloat = 76
        let autoW: CGFloat = 108

        notNowButton.frame = NSRect(x: bounds.width - padX - notNowW, y: buttonY, width: notNowW, height: buttonH)
        suggestButton.frame = NSRect(x: notNowButton.frame.minX - 6 - suggestW, y: buttonY, width: suggestW, height: buttonH)
        automaticallyButton.frame = NSRect(x: suggestButton.frame.minX - 6 - autoW, y: buttonY, width: autoW, height: buttonH)
    }
}

// MARK: - First-Undo Quiet Reminder View (#112)

/// Quiet, non-modal reminder shown once per install the first time a partner fix is undone,
/// explaining where to pause the partner for this document or turn it off in Settings › Writing.
@MainActor
final class PartnerUndoReminderView: NSView {
    static let messageText = "Pause for this document in Edit › Pause Writing Partner (⌥⌘P), or turn it off in Settings › Writing."
    static let preferredSize = NSSize(width: 460, height: 42)

    let messageLabel = NSTextField(wrappingLabelWithString: PartnerUndoReminderView.messageText)
    let pauseButton = NSButton(title: "Pause Here", target: nil, action: nil)
    let dismissButton = NSButton(title: "Dismiss", target: nil, action: nil)

    var onPause: (() -> Void)?
    var onDismiss: (() -> Void)?

    override var isFlipped: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        setup()
    }

    required init?(coder: NSCoder) { nil }

    private func setup() {
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.borderWidth = 1
        layer?.borderColor = WritingPartnerOverlay.tint.withAlphaComponent(0.35).cgColor
        layer?.backgroundColor = NSColor.windowBackgroundColor.withAlphaComponent(0.96).cgColor
        shadow = NSShadow()
        shadow?.shadowColor = NSColor.black.withAlphaComponent(0.14)
        shadow?.shadowOffset = NSSize(width: 0, height: -2)
        shadow?.shadowBlurRadius = 6

        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityIdentifier("WritingPartnerUndoReminderView")

        messageLabel.font = NSFont.systemFont(ofSize: 11, weight: .regular)
        messageLabel.textColor = NSColor.secondaryLabelColor
        messageLabel.isBezeled = false
        messageLabel.isEditable = false
        messageLabel.drawsBackground = false
        addSubview(messageLabel)

        pauseButton.bezelStyle = .rounded
        pauseButton.target = self
        pauseButton.action = #selector(pauseClicked)
        pauseButton.setAccessibilityElement(true)
        pauseButton.setAccessibilityRole(.button)
        pauseButton.setAccessibilityLabel("Pause Writing Partner for this document")
        pauseButton.setAccessibilityIdentifier("UndoReminderPauseButton")
        addSubview(pauseButton)

        dismissButton.bezelStyle = .rounded
        dismissButton.target = self
        dismissButton.action = #selector(dismissClicked)
        dismissButton.keyEquivalent = "\u{1b}"
        dismissButton.setAccessibilityElement(true)
        dismissButton.setAccessibilityRole(.button)
        dismissButton.setAccessibilityLabel("Dismiss reminder")
        dismissButton.setAccessibilityIdentifier("UndoReminderDismissButton")
        addSubview(dismissButton)

        setAccessibilityLabel(Self.messageText)
        setAccessibilityChildren([messageLabel, pauseButton, dismissButton])
    }

    func configure(onPause: @escaping () -> Void, onDismiss: @escaping () -> Void) {
        self.onPause = onPause
        self.onDismiss = onDismiss
        needsLayout = true
    }

    @objc private func pauseClicked() {
        onPause?()
    }

    @objc private func dismissClicked() {
        onDismiss?()
    }

    override func layout() {
        super.layout()
        let padX: CGFloat = 10
        let buttonH: CGFloat = 22
        let dismissW: CGFloat = 68
        let pauseW: CGFloat = 86

        dismissButton.frame = NSRect(x: bounds.width - padX - dismissW, y: (bounds.height - buttonH) / 2, width: dismissW, height: buttonH)
        pauseButton.frame = NSRect(x: dismissButton.frame.minX - 6 - pauseW, y: (bounds.height - buttonH) / 2, width: pauseW, height: buttonH)

        let textW = max(80, pauseButton.frame.minX - padX - 8)
        messageLabel.frame = NSRect(x: padX, y: (bounds.height - 28) / 2, width: textW, height: 28)
    }
}
#endif

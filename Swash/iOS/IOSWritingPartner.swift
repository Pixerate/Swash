//
//  IOSWritingPartner.swift
//  Swash
//
//  The writing partner on iPhone and iPad (#109). The session (WritingPartnerSession.swift) is the
//  Mac's; here are the iOS editors as its `WritingPartnerHost`, and `IOSWritingPartnerOverlay`, the
//  canvas it draws on: suggestion and mark underlines, the partner's cursor and the word it is
//  typing (drawn, never written, until it lands: GOTCHAS #79) in the chosen Flair treatment, and
//  its notes in place.
//

#if os(iOS)
import FlairEffects
import SwiftUI
import UIKit
import NaturalLanguage
import PixerateCore
import PixerateMarkdown

// MARK: - Host

/// One of the iOS editors as the partner sees it. The coordinator that owns it supplies the
/// raw ↔ storage mapping and how an edit is applied, so Edit Text and Source share one host.
final class IOSWritingPartnerHost: WritingPartnerHost {
    weak var textView: MarkdownEditingTextView?
    let isStyled: Bool
    /// Raw Markdown of the editor.
    var rawText: () -> String = { "" }
    /// Storage → raw offsets.
    var rawRange: (NSRange) -> NSRange = { $0 }
    /// Raw → storage offsets.
    var storageRange: (NSRange) -> NSRange = { $0 }
    /// Applies a whole-document rewrite as one undo step: new raw text, raw selection, action name.
    var apply: (String, NSRange, String) -> Void = { _, _, _ in }
    var flavor: () -> MarkdownFlavor = { .github }
    /// The parsed document for the editor's current text, when the editor caches one.
    var cachedDocument: ((String) -> MarkdownDocument?)?
    /// Set while the partner's own edit is applied, so the editor doesn't report it as typing.
    private(set) var isApplyingPartnerEdit = false

    private var savedAssists: (autocorrection: UITextAutocorrectionType, predictions: UITextInlinePredictionType)?
    private let checker = UITextChecker()
    private var overlay: IOSWritingPartnerOverlay?

    /// Nonisolated: an isolated deinit crashes on the iOS Simulator (GOTCHAS #103).
    nonisolated deinit {}

    init(textView: MarkdownEditingTextView, isStyled: Bool) {
        self.textView = textView
        self.isStyled = isStyled
        WritingPartnerCopy.isPad = UIDevice.current.userInterfaceIdiom == .pad
    }

    var partnerRawText: String { rawText() }

    var partnerRawSelection: NSRange {
        guard let textView else { return NSRange(location: 0, length: 0) }
        return rawRange(textView.selectedRange)
    }

    func setPartnerRawSelection(_ range: NSRange, scrollToVisible: Bool) {
        guard let textView else { return }
        let storage = storageRange(range)
        textView.selectedRange = storage
        if scrollToVisible { textView.scrollRangeToVisible(storage) }
    }

    var partnerFlavor: MarkdownFlavor { flavor() }
    var partnerIsStyled: Bool { isStyled }

    func partnerDocument(for text: String) -> MarkdownDocument {
        cachedDocument?(text) ?? MarkdownDocument.parse(text, flavor: partnerFlavor)
    }

    var partnerCanEdit: Bool { textView.map { $0.window != nil && $0.isEditable } ?? false }
    var partnerIsOnScreen: Bool { textView?.window != nil }
    var partnerHasMarkedText: Bool { textView?.markedTextRange != nil }
    var partnerUndoManager: UndoManager? { textView?.undoManager }

    func applyPartnerEdit(newRawText: String, rawSelection: NSRange, actionName: String) {
        isApplyingPartnerEdit = true
        defer { isApplyingPartnerEdit = false }
        apply(newRawText, rawSelection, actionName)
    }

    /// The keyboard's autocorrect and inline predictions write at the caret too; while the partner
    /// is on it does the correcting itself (as on the Mac, GOTCHAS #78).
    func setSystemTextAssistsSuppressed(_ suppressed: Bool) {
        guard let textView else { return }
        if suppressed, savedAssists == nil {
            savedAssists = (textView.autocorrectionType, textView.inlinePredictionType)
            textView.autocorrectionType = .no
            textView.inlinePredictionType = .no
            if textView.isFirstResponder { textView.reloadInputViews() }
        } else if !suppressed, let saved = savedAssists {
            savedAssists = nil
            textView.autocorrectionType = saved.autocorrection
            textView.inlinePredictionType = saved.predictions
            if textView.isFirstResponder { textView.reloadInputViews() }
        }
    }

    /// UIKit has no autocorrection API, so the partner takes the spell checker's first guess, and
    /// only when it is close to what was typed (two edits at most): a far guess is more likely a
    /// name or a word the dictionary doesn't know than a typo.
    func partnerSpellingCorrection(forWordRange range: NSRange, in text: String) -> String? {
        let ns = text as NSString
        guard NSMaxRange(range) <= ns.length, range.length >= 2 else { return nil }
        let word = ns.substring(with: range)
        let language = Self.checkerLanguage
        let missed = checker.rangeOfMisspelledWord(in: text, range: range, startingAt: range.location, wrap: false, language: language)
        guard missed.location != NSNotFound, NSEqualRanges(missed, range),
              let guess = checker.guesses(forWordRange: range, in: text, language: language)?.first,
              guess != word, !guess.contains(" "),
              Self.editDistance(word.lowercased(), guess.lowercased()) <= 2 else { return nil }
        return guess
    }

    func partnerIgnoreSpelling(_ words: [String]) {
        for word in words { checker.ignoreWord(word) }
    }

    func partnerAnnounce(_ text: String) {
        UIAccessibility.post(notification: .announcement,
                             argument: NSAttributedString(string: text, attributes: [.accessibilitySpeechQueueAnnouncement: true]))
    }

    var partnerCanvas: (any WritingPartnerCanvas)? {
        guard let textView else { return nil }
        if let overlay, overlay.superview === textView { return overlay }
        let made = IOSWritingPartnerOverlay(host: self)
        textView.addSubview(made)
        overlay = made
        return made
    }

    /// The overlay, if the partner has drawn anything yet.
    var existingOverlay: IOSWritingPartnerOverlay? { overlay }

    func partnerRects(forRaw range: NSRange) -> [CGRect] {
        guard let textView else { return [] }
        return Self.rects(forStorage: storageRange(range), in: textView)
    }

    func partnerCaretRect(atRaw location: Int) -> CGRect? {
        guard let textView else { return nil }
        return Self.caretRect(atStorage: storageRange(NSRange(location: location, length: 0)).location, in: textView)
    }

    var partnerReducesMotion: Bool { UIAccessibility.isReduceMotionEnabled }

    var partnerUndoReminderText: String {
        "Pause for this document in the Writing menu, or turn the partner off in Settings › Writing Partner."
    }

    // MARK: Geometry

    /// Line rectangles of `range` (storage offsets) in the text view's content coordinates.
    static func rects(forStorage range: NSRange, in textView: UITextView) -> [CGRect] {
        let storage = textView.textStorage
        guard range.location != NSNotFound, NSMaxRange(range) <= storage.length, range.length > 0 else { return [] }
        let layoutManager = textView.layoutManager
        let glyphs = layoutManager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
        let inset = textView.textContainerInset
        var rects: [CGRect] = []
        layoutManager.enumerateEnclosingRects(forGlyphRange: glyphs,
                                              withinSelectedGlyphRange: NSRange(location: NSNotFound, length: 0),
                                              in: textView.textContainer) { rect, _ in
            rects.append(rect.offsetBy(dx: inset.left, dy: inset.top))
        }
        return rects.filter { $0.width > 0.5 && $0.height > 0.5 }
    }

    /// The insertion point's rectangle at a storage offset, in content coordinates.
    static func caretRect(atStorage location: Int, in textView: UITextView) -> CGRect? {
        let length = textView.textStorage.length
        guard let position = textView.position(from: textView.beginningOfDocument, offset: min(max(0, location), length)) else { return nil }
        let rect = textView.caretRect(for: position)
        return rect.isNull || rect.isInfinite ? nil : rect
    }

    /// The UITextChecker language for the document: its detected language, else the person's.
    static var checkerLanguage: String {
        let available = UITextChecker.availableLanguages
        let document = WritingPartnerActiveVoice.shared.documentLanguage.rawValue
        let preferred = Locale.preferredLanguages.map { $0.replacingOccurrences(of: "-", with: "_") }
        for candidate in preferred where candidate.hasPrefix(document) {
            if available.contains(candidate) { return candidate }
        }
        return available.first { $0.hasPrefix(document) } ?? available.first ?? "en_US"
    }

    static func editDistance(_ a: String, _ b: String) -> Int {
        let a = Array(a), b = Array(b)
        guard !a.isEmpty else { return b.count }
        guard !b.isEmpty else { return a.count }
        var previous = Array(0...b.count)
        for i in 1...a.count {
            var current = [i] + Array(repeating: 0, count: b.count)
            for j in 1...b.count {
                current[j] = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1))
            }
            previous = current
        }
        return previous[b.count]
    }
}

// MARK: - Overlay

/// Draws the partner over an iOS editor. A subview of the text view (so it scrolls with the text),
/// it never takes touches except on its notes.
///
/// The partner's cursor, its selection, the word it types and what it changed are the chosen Flair
/// text treatment (Settings › Writing Partner › Partner style), staged as on the Mac
/// (`WritingPartnerOverlay`): `checking`, `caret`, `selecting`, `typing`, `landed`. The treatment's
/// layers above the text are this view's; the ones behind it go in the text view's own layer, under
/// the view that draws the glyphs, so a ribbon can pass under the letters. With Reduce Motion on,
/// Flair holds each stage still and fades it.
final class IOSWritingPartnerOverlay: UIView, WritingPartnerCanvas {
    static let tint = UIColor.systemPurple

    private weak var host: IOSWritingPartnerHost?
    private let suggestionLayer = CAShapeLayer()
    private let suggestionTintLayer = CAShapeLayer()
    private let markLayer = CAShapeLayer()
    private let renderer = FlairTextTreatmentRenderer()

    private weak var carets: AgentCaretStore?
    private var subscription: UUID?
    private weak var target: WritingPartnerTarget?

    private var introduction: UIView?
    private var undoReminder: UIView?
    private var suggestionPrompt: UIView?

    /// What the last frame drew of the partner's cursor and the word it is typing.
    private var drawnCaret = false
    private var drawnGhost: String?

    var hasSuggestionUnderlines: Bool { suggestionLayer.path.map { !$0.isEmpty } ?? false }
    var hasMarkUnderlines: Bool { markLayer.path.map { !$0.isEmpty } ?? false }
    var isShowingCaret: Bool { drawnCaret }
    var isShowingGhost: Bool { drawnGhost != nil }
    var ghostText: String? { drawnGhost }
    var activeNoteView: UIView? { suggestionPrompt ?? undoReminder ?? introduction }
    /// The Flair treatment drawn now (its id), for tests.
    var treatmentID: String? { look?.id }
    /// Whether any treatment layers are on screen, for tests.
    var isDrawingTreatment: Bool {
        !(renderer.behindLayer.sublayers ?? []).isEmpty || !(renderer.aboveLayer.sublayers ?? []).isEmpty
    }

    init(host: IOSWritingPartnerHost) {
        self.host = host
        super.init(frame: .zero)
        isUserInteractionEnabled = true
        backgroundColor = .clear
        accessibilityElementsHidden = false
        for layer in [suggestionTintLayer, suggestionLayer, markLayer] as [CALayer] {
            layer.contentsScale = traitCollection.displayScale
            self.layer.addSublayer(layer)
        }
        self.layer.addSublayer(renderer.aboveLayer)
        suggestionLayer.lineWidth = 2
        suggestionLayer.fillColor = nil
        markLayer.lineWidth = 2
        markLayer.lineDashPattern = [1.5, 3]
        markLayer.lineCap = .round
        markLayer.fillColor = nil
        applyColors()
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (self: Self, _: UITraitCollection) in
            self.look = nil
            self.applyColors()
            self.renderPartner()
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// Nonisolated: an isolated deinit crashes on the iOS Simulator (GOTCHAS #103). The caret
    /// subscription and the display link are dropped when the overlay leaves its text view instead.
    nonisolated deinit {}

    /// The underline colours in the current appearance (`systemPurple` is lighter in Dark Mode).
    private func applyColors() {
        let tint = Self.tint.resolvedColor(with: traitCollection)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        suggestionTintLayer.fillColor = tint.withAlphaComponent(0.10).cgColor
        suggestionLayer.strokeColor = tint.cgColor
        markLayer.strokeColor = tint.withAlphaComponent(0.7).cgColor
        CATransaction.commit()
    }

    /// Covers the text view's whole content (it scrolls with the text), and stays on top of it.
    private func fit() {
        guard let textView = superview as? UITextView else { return }
        let size = CGSize(width: textView.bounds.width, height: max(textView.contentSize.height, textView.bounds.height))
        if frame.size != size || frame.origin != .zero {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            frame = CGRect(origin: .zero, size: size)
            for layer in [suggestionTintLayer, suggestionLayer, markLayer] as [CALayer] {
                layer.frame = bounds
            }
            CATransaction.commit()
        }
        if textView.subviews.last !== self { textView.bringSubviewToFront(self) }
    }

    override func didMoveToSuperview() {
        super.didMoveToSuperview()
        if superview == nil {
            if let subscription {
                carets?.unsubscribe(subscription)
                self.subscription = nil
            }
            stop()
        }
        fit()
    }

    /// Only the notes take touches; the text under the overlay gets the rest.
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        for note in [introduction, undoReminder, suggestionPrompt].compactMap({ $0 }) {
            let local = convert(point, to: note)
            if note.point(inside: local, with: event) { return note.hitTest(local, with: event) }
        }
        return nil
    }

    // MARK: The treatment

    /// The chosen treatment with the partner's values, resolved for a style and appearance.
    struct Look {
        let id: String
        let dark: Bool
        let stages: FlairJSON

        func plan(_ stage: FlairTextTreatmentStage, at time: Double, over target: FlairTreatmentTarget) -> FlairTextTreatmentPlan {
            FlairTextTreatments.planResolved(stages, stage: stage, time: max(0, time), target: target,
                                             reduceMotion: UIAccessibility.isReduceMotionEnabled)
        }
    }

    /// The look for a treatment id (the default when it's unknown) in `traits`' appearance, in the
    /// partner's tint and with no name tag. The Settings preview draws with it too.
    static func look(id: String, traits: UITraitCollection) -> Look? {
        guard let treatment = FlairTextTreatments.treatment(id: id)
                ?? FlairTextTreatments.treatment(id: WritingPartnerDefaults.defaultStyle)
                ?? FlairTextTreatments.all.first else { return nil }
        let tint = rgba(Self.tint, in: traits)
        let dark = traits.userInterfaceStyle == .dark
        let values = treatment.values(values: [
            "color": .string(String(format: "#%02X%02X%02X", Int((tint.r * 255).rounded()),
                                    Int((tint.g * 255).rounded()), Int((tint.b * 255).rounded()))),
            "darkTheme": .bool(dark),
            "nameTag": .bool(false),
        ])
        return Look(id: treatment.id, dark: dark, stages: FlairTextTreatments.resolve(treatment, values: values))
    }

    /// A colour as `traits` show it.
    static func rgba(_ color: UIColor, in traits: UITraitCollection) -> FlairRGBA {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        color.resolvedColor(with: traits).getRed(&r, green: &g, blue: &b, alpha: &a)
        return FlairRGBA(Double(r), Double(g), Double(b), Double(a))
    }

    nonisolated static func caret(_ rect: CGRect) -> FlairTreatmentCaret {
        FlairTreatmentCaret(x: Double(rect.midX), y: Double(rect.minY), height: Double(rect.height))
    }

    private var look: Look?

    /// The look for the chosen style and the editor's appearance, resolved again when either changes.
    private func currentLook(in textView: UITextView) -> Look? {
        let id = WritingPartnerDefaults.style()
        let dark = textView.traitCollection.userInterfaceStyle == .dark
        if let look, look.dark == dark, look.id == id || FlairTextTreatments.treatment(id: id) == nil { return look }
        look = Self.look(id: id, traits: textView.traitCollection)
        return look
    }

    // MARK: Stages

    /// A stage that plays to its end on its own: a `checking` sweep, or a `landed` fix.
    private struct Playback {
        let stage: FlairTextTreatmentStage
        let start: Double
        var target: FlairTreatmentTarget
        /// The director's range of a landed fix, to follow its rectangles while it still reports it.
        var range: NSRange?
    }

    private var playbacks: [Playback] = []
    /// When the partner's cursor, its selection and its typing each began, in ms.
    private var caretStart: Double?
    private var selectStart: Double?
    private var typingStart: Double?
    private var displayLink: CADisplayLink?

    private static var now: Double { CACurrentMediaTime() * 1000 }

    private var isPlaying: Bool { !playbacks.isEmpty || !(carets?.carets.isEmpty ?? true) }

    /// Draws a frame, and keeps drawing on the display's clock while anything plays.
    private func render() {
        drawFrame()
        if displayLink == nil, isPlaying, window != nil {
            // The proxy holds the overlay weakly: a display link retains its target
            let link = CADisplayLink(target: DisplayLinkProxy(self), selector: #selector(DisplayLinkProxy.tick))
            link.add(to: .main, forMode: .common)
            displayLink = link
        }
    }

    fileprivate func tick() {
        drawFrame()
        if !isPlaying || window == nil { stop() }
    }

    private func stop() {
        displayLink?.invalidate()
        displayLink = nil
        playbacks.removeAll()
        renderer.clear()
        renderer.behindLayer.removeFromSuperlayer()
        drawnCaret = false
        drawnGhost = nil
    }

    // MARK: Underlines

    /// Sweeps across `rects`: what the partner looked at and left alone.
    func sweep(_ rects: [CGRect]) {
        fit()
        guard !rects.isEmpty else { return }
        playbacks.append(Playback(stage: .checking, start: Self.now, target: FlairTreatmentTarget(lines: rects)))
        render()
    }

    func showSuggestions(_ rects: [CGRect]) {
        fit()
        let underline = UIBezierPath()
        let tint = UIBezierPath()
        for rect in rects {
            underline.move(to: CGPoint(x: rect.minX, y: rect.maxY - 1))
            underline.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - 1))
            tint.append(UIBezierPath(roundedRect: rect, cornerRadius: 3))
        }
        suggestionLayer.path = underline.cgPath
        suggestionTintLayer.path = tint.cgPath
        accessibilityValue = rects.isEmpty ? nil : "Suggestions"
    }

    func showMarks(_ rects: [CGRect]) {
        fit()
        let path = UIBezierPath()
        for rect in rects {
            path.move(to: CGPoint(x: rect.minX, y: rect.maxY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        }
        markLayer.path = path.cgPath
    }

    // MARK: The partner's cursor

    func attach(carets: AgentCaretStore, target: WritingPartnerTarget) {
        if let subscription { self.carets?.unsubscribe(subscription) }
        self.carets = carets
        self.target = target
        subscription = carets.subscribe { [weak self] _ in
            self?.renderPartner()
            // What a fix changed is measured again once the editor has restyled it
            DispatchQueue.main.async { [weak self] in self?.renderPartner() }
        }
    }

    /// Redraws every playing stage from the director's state (the editor calls it after restyling).
    func renderPartner() {
        fit()
        render()
    }

    /// One frame: the plan of every stage at this moment, drawn by Flair's renderer.
    private func drawFrame() {
        guard let host, let textView = host.textView, let look = currentLook(in: textView) else { return }
        let now = Self.now
        var plans: [FlairTextTreatmentPlan] = []
        var live: [FlairTextTreatmentPlan] = []
        var font: UIFont?
        var ghostShown: String?
        var caretShown = false

        let carets = self.carets?.carets ?? []
        if carets.isEmpty {
            caretStart = nil
            selectStart = nil
            typingStart = nil
        } else if let target {
            caretStart = caretStart ?? now
            for caret in carets {
                let head = caretRect(atAgent: caret.head, target: target).map(Self.caret)
                // What it just changed: the `landed` stage starts, and runs on after the cursor has gone
                for range in caret.changed {
                    let raw = target.realRange(forAgent: range)
                    let lines = host.partnerRects(forRaw: raw)
                    guard !lines.isEmpty else { continue }
                    let end = host.partnerCaretRect(atRaw: NSMaxRange(raw)).map(Self.caret)
                    let landed = FlairTreatmentTarget(lines: lines, caret: end ?? head)
                    if let index = playbacks.firstIndex(where: { $0.stage == .landed && $0.range == range }) {
                        playbacks[index].target = landed
                    } else {
                        playbacks.append(Playback(stage: .landed, start: now, target: landed, range: range))
                    }
                }
                if let ghost = target.ghost, let layout = ghostLayout(ghost, in: textView) {
                    // Typing begins while the selection still shows, so nothing is drawn behind the word twice
                    typingStart = typingStart ?? now
                    font = layout.attributes[.font] as? UIFont
                    let ink = layout.attributes[.foregroundColor] as? UIColor ?? textView.textColor ?? .label
                    let background = textView.backgroundColor ?? .systemBackground
                    let typing = FlairTreatmentTarget(lines: layout.covered, caret: head, text: ghost.text,
                                                      color: Self.rgba(ink, in: textView.traitCollection),
                                                      background: Self.rgba(background, in: textView.traitCollection))
                    live.append(look.plan(.typing, at: now - (typingStart ?? now), over: typing))
                    ghostShown = ghost.text
                } else if caret.selection.length > 0 {
                    typingStart = nil
                    selectStart = selectStart ?? now
                    let lines = host.partnerRects(forRaw: target.realRange(forAgent: caret.selection))
                    live.append(look.plan(.selecting, at: now - (selectStart ?? now), over: FlairTreatmentTarget(lines: lines, caret: head)))
                } else {
                    selectStart = nil
                    typingStart = nil
                }
                if let head {
                    live.append(look.plan(.caret, at: now - (caretStart ?? now), over: FlairTreatmentTarget(caret: head)))
                    caretShown = true
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
        drawnCaret = caretShown
        drawnGhost = ghostShown

        guard !plans.isEmpty else {
            renderer.clear()
            renderer.behindLayer.removeFromSuperlayer()
            return
        }
        // Behind the text: in the text view's layer, under its subviews (the glyphs) and over its
        // background. It shares the overlay's content coordinates, since the overlay sits at zero.
        if renderer.behindLayer.superlayer !== textView.layer {
            textView.layer.insertSublayer(renderer.behindLayer, at: 0)
        }
        renderer.contentsScale = window?.screen.scale ?? traitCollection.displayScale
        renderer.draw(plans, font: font.map { $0 as CTFont })
    }

    /// The partner's insertion point at an offset in the director's text: in the word being typed
    /// it follows the drawn word.
    private func caretRect(atAgent position: Int, target: WritingPartnerTarget) -> CGRect? {
        guard let host, let textView = host.textView else { return nil }
        if let ghost = target.ghost, let layout = ghostLayout(ghost, in: textView) {
            let typed = (ghost.text as NSString).length
            let offset = position - ghost.range.location
            if offset >= 0, offset <= typed {
                let prefix = NSAttributedString(string: (ghost.text as NSString).substring(to: offset), attributes: layout.attributes)
                return CGRect(x: layout.origin.x + prefix.size().width - 1, y: layout.line.minY, width: 2, height: layout.line.height)
            }
        }
        return host.partnerCaretRect(atRaw: target.realPosition(forAgent: position))
    }

    /// Where the word being typed goes: over the word it replaces (`covered`), in that word's font.
    private func ghostLayout(_ ghost: (range: NSRange, text: String), in textView: UITextView)
        -> (origin: CGPoint, line: CGRect, attributes: [NSAttributedString.Key: Any], covered: [CGRect])? {
        guard let host else { return nil }
        let storage = textView.textStorage
        guard storage.length > 0 else { return nil }
        let range = host.storageRange(ghost.range)
        guard let caret = IOSWritingPartnerHost.caretRect(atStorage: range.location, in: textView) else { return nil }
        let index = min(range.location, storage.length - 1)
        var attributes: [NSAttributedString.Key: Any] = [:]
        for key in [NSAttributedString.Key.font, .foregroundColor, .kern] {
            if let value = storage.attribute(key, at: index, effectiveRange: nil) { attributes[key] = value }
        }
        return (CGPoint(x: caret.midX, y: caret.minY), caret, attributes, IOSWritingPartnerHost.rects(forStorage: range, in: textView))
    }

    // MARK: Notes

    func showIntroduction(at rect: CGRect, onChooseMode: @escaping (WritingPartnerMode) -> Void, onDismiss: @escaping () -> Void) {
        hideIntroduction()
        let signedIn = WritingPartnerDefaults.provider() == .pixerate
        introduction = place(PartnerIntroductionCard(privacy: WritingPartnerCopy.privacy(signedIn: signedIn),
                                                     onChooseMode: onChooseMode, onDismiss: onDismiss), near: rect)
    }

    func hideIntroduction() {
        introduction?.removeFromSuperview()
        introduction = nil
    }

    func showUndoReminder(at rect: CGRect, text: String, onPause: @escaping () -> Void, onDismiss: @escaping () -> Void) {
        hideUndoReminder()
        undoReminder = place(PartnerUndoReminderCard(text: text, onPause: onPause, onDismiss: onDismiss), near: rect)
    }

    func hideUndoReminder() {
        undoReminder?.removeFromSuperview()
        undoReminder = nil
    }

    func showSuggestionPrompt(suggestion: JazzTextSuggestion, at rect: CGRect,
                              onAccept: @escaping () -> Void, onDismiss: @escaping () -> Void) {
        hideSuggestionPrompt()
        suggestionPrompt = place(PartnerSuggestionCard(title: suggestion.kind.title, why: suggestion.why,
                                                       symbol: suggestion.kind.symbolName,
                                                       onAccept: onAccept, onDismiss: onDismiss), near: rect)
    }

    func hideSuggestionPrompt() {
        suggestionPrompt?.removeFromSuperview()
        suggestionPrompt = nil
    }

    /// Adds a note below `rect` (above it when there's no room), inside the visible width.
    private func place<Content: View>(_ content: Content, near rect: CGRect) -> UIView {
        fit()
        let hosting = UIHostingController(rootView: content)
        hosting.view.backgroundColor = .clear
        let margin: CGFloat = 12
        let width = min(420, bounds.width - margin * 2)
        let size = hosting.sizeThatFits(in: CGSize(width: width, height: .greatestFiniteMagnitude))
        let x = max(margin, min(rect.minX, bounds.width - size.width - margin))
        var y = rect.maxY + 8
        if let textView = superview as? UITextView {
            let insets = textView.adjustedContentInset
            let visibleBottom = textView.contentOffset.y + textView.bounds.height - insets.bottom - margin
            let visibleTop = max(margin, textView.contentOffset.y + insets.top + margin)
            if y + size.height > visibleBottom {
                y = max(visibleTop, rect.minY - size.height - 8)
            }
        }
        hosting.view.frame = CGRect(x: x, y: y, width: size.width, height: size.height)
        addSubview(hosting.view)
        UIAccessibility.post(notification: .layoutChanged, argument: hosting.view)
        return hosting.view
    }
}

/// A display link's target that holds the overlay weakly (a display link retains its target).
private final class DisplayLinkProxy: NSObject {
    weak var overlay: IOSWritingPartnerOverlay?
    init(_ overlay: IOSWritingPartnerOverlay) { self.overlay = overlay }
    @objc func tick() { overlay?.tick() }
}

extension JazzTextSuggestionKind {
    /// The SF Symbol for the suggestion prompt (as on the Mac's).
    var symbolName: String {
        switch self {
        case .list: return "list.bullet"
        case .heading: return "textformat.size"
        case .math: return "function"
        case .title: return "textformat.characters"
        case .alert: return "exclamationmark.triangle"
        case .quote: return "quote.opening"
        case .spelling, .wrongWord: return "textformat.abc"
        case .houseStyle: return "person.2"
        case .tone: return "waveform"
        }
    }
}

// MARK: - Notes

/// The first-run introduction: what the partner does, what it sends, and how it should act.
struct PartnerIntroductionCard: View {
    var privacy: String
    var onChooseMode: (WritingPartnerMode) -> Void
    var onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(WritingPartnerCopy.introduction, systemImage: "pencil.and.scribble")
                .font(.headline)
            Text(privacy)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button(WritingPartnerMode.copyedit.title) { onChooseMode(.copyedit) }
                    .buttonStyle(.glassProminent)
                Button(WritingPartnerMode.ghostwrite.title) { onChooseMode(.ghostwrite) }
                    .buttonStyle(.glass)
                Spacer(minLength: 0)
                Button("Not now", action: onDismiss)
                    .buttonStyle(.borderless)
            }
            .controlSize(.small)
        }
        .padding(14)
        .glassEffect(.regular, in: .rect(cornerRadius: 18))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(WritingPartnerCopy.introduction). \(privacy)")
    }
}

/// Shown once, the first time someone undoes a fix of the partner's.
struct PartnerUndoReminderCard: View {
    var text: String
    var onPause: () -> Void
    var onDismiss: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Text(text)
                .font(.footnote)
                .fixedSize(horizontal: false, vertical: true)
            Button("Pause", action: onPause)
                .buttonStyle(.glass)
                .controlSize(.small)
            Button(action: onDismiss) {
                Image(systemName: "xmark")
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Dismiss")
        }
        .padding(12)
        .glassEffect(.regular, in: .rect(cornerRadius: 16))
    }
}

/// A block suggestion from the pause tier (a list, a heading, a callout…), with why it's offered.
struct PartnerSuggestionCard: View {
    var title: String
    var why: String
    var symbol: String
    var onAccept: () -> Void
    var onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: symbol)
                .font(.subheadline.weight(.semibold))
            Text(why)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .lineLimit(4)
            HStack {
                Button("Accept", action: onAccept)
                    .buttonStyle(.glassProminent)
                Button("Dismiss", action: onDismiss)
                    .buttonStyle(.glass)
            }
            .controlSize(.small)
        }
        .padding(12)
        .glassEffect(.regular, in: .rect(cornerRadius: 16))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Writing partner suggestion: \(title). \(why)")
    }
}

#Preview("Introduction", traits: .sizeThatFitsLayout) {
    PartnerIntroductionCard(privacy: WritingPartnerCopy.privacy(signedIn: false), onChooseMode: { _ in }, onDismiss: {})
        .padding()
        .frame(width: 420)
}

#Preview("Introduction, signed in", traits: .sizeThatFitsLayout) {
    PartnerIntroductionCard(privacy: WritingPartnerCopy.privacy(signedIn: true), onChooseMode: { _ in }, onDismiss: {})
        .padding()
        .frame(width: 360)
        .preferredColorScheme(.dark)
}

#Preview("Undo reminder", traits: .sizeThatFitsLayout) {
    PartnerUndoReminderCard(text: "Pause for this document in the Writing menu, or turn the partner off in Settings › Writing Partner.",
                            onPause: {}, onDismiss: {})
        .padding()
        .frame(width: 420)
}

#Preview("Suggestion", traits: .sizeThatFitsLayout) {
    PartnerSuggestionCard(title: "List", why: "These three lines read as a list.", symbol: "list.bullet",
                          onAccept: {}, onDismiss: {})
        .padding()
        .frame(width: 360)
}
#endif

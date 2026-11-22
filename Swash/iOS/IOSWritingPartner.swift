//
//  IOSWritingPartner.swift
//  Swash
//
//  The writing partner on iPhone and iPad (#109). The session (WritingPartnerSession.swift) is the
//  Mac's; here are the iOS editors as its `WritingPartnerHost`, and `IOSWritingPartnerOverlay`, the
//  canvas it draws on: suggestion and mark underlines, the partner's cursor and the word it is
//  typing (drawn, never written, until it lands: GOTCHAS #79), and its notes in place.
//

#if os(iOS)
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
final class IOSWritingPartnerOverlay: UIView, WritingPartnerCanvas {
    static let tint = UIColor.systemPurple

    private weak var host: IOSWritingPartnerHost?
    private let sweepLayer = CALayer()
    private let suggestionLayer = CAShapeLayer()
    private let suggestionTintLayer = CAShapeLayer()
    private let markLayer = CAShapeLayer()
    private let caretLayer = CALayer()
    private let changedLayer = CAShapeLayer()
    private let ghostCover = CAShapeLayer()
    private let ghostLabel = UILabel()

    private weak var carets: AgentCaretStore?
    private var subscription: UUID?
    private weak var target: WritingPartnerTarget?

    private var introduction: UIView?
    private var undoReminder: UIView?
    private var suggestionPrompt: UIView?

    init(host: IOSWritingPartnerHost) {
        self.host = host
        super.init(frame: .zero)
        isUserInteractionEnabled = true
        backgroundColor = .clear
        accessibilityElementsHidden = false
        for layer in [sweepLayer, suggestionTintLayer, suggestionLayer, markLayer, changedLayer, ghostCover, caretLayer] as [CALayer] {
            layer.contentsScale = traitCollection.displayScale
            self.layer.addSublayer(layer)
        }
        suggestionTintLayer.fillColor = Self.tint.withAlphaComponent(0.10).cgColor
        suggestionLayer.strokeColor = Self.tint.cgColor
        suggestionLayer.lineWidth = 2
        suggestionLayer.fillColor = nil
        markLayer.strokeColor = Self.tint.withAlphaComponent(0.7).cgColor
        markLayer.lineWidth = 2
        markLayer.lineDashPattern = [1.5, 3]
        markLayer.lineCap = .round
        markLayer.fillColor = nil
        changedLayer.fillColor = Self.tint.withAlphaComponent(0.14).cgColor
        caretLayer.backgroundColor = Self.tint.cgColor
        caretLayer.cornerRadius = 1
        caretLayer.isHidden = true
        ghostLabel.isHidden = true
        ghostLabel.isAccessibilityElement = false
        addSubview(ghostLabel)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    deinit {
        if let subscription { MainActor.assumeIsolated { carets?.unsubscribe(subscription) } }
    }

    /// Covers the text view's whole content (it scrolls with the text), and stays on top of it.
    private func fit() {
        guard let textView = superview as? UITextView else { return }
        let size = CGSize(width: textView.bounds.width, height: max(textView.contentSize.height, textView.bounds.height))
        if frame.size != size || frame.origin != .zero {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            frame = CGRect(origin: .zero, size: size)
            for layer in [sweepLayer, suggestionTintLayer, suggestionLayer, markLayer, changedLayer, ghostCover] as [CALayer] {
                layer.frame = bounds
            }
            CATransaction.commit()
        }
        if textView.subviews.last !== self { textView.bringSubviewToFront(self) }
    }

    override func didMoveToSuperview() {
        super.didMoveToSuperview()
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

    // MARK: Underlines

    func sweep(_ rects: [CGRect]) {
        fit()
        guard !UIAccessibility.isReduceMotionEnabled, !rects.isEmpty else { return }
        let path = UIBezierPath()
        for rect in rects { path.append(UIBezierPath(roundedRect: rect, cornerRadius: 3)) }
        let shape = CAShapeLayer()
        shape.path = path.cgPath
        shape.fillColor = Self.tint.withAlphaComponent(0.12).cgColor
        shape.frame = bounds
        sweepLayer.addSublayer(shape)
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 1
        fade.toValue = 0
        fade.duration = 0.5
        fade.isRemovedOnCompletion = false
        fade.fillMode = .forwards
        CATransaction.begin()
        CATransaction.setCompletionBlock { shape.removeFromSuperlayer() }
        shape.add(fade, forKey: "fade")
        CATransaction.commit()
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
        subscription = carets.subscribe { [weak self] _ in self?.renderPartner() }
    }

    func renderPartner() {
        guard let host, let textView = host.textView, let target else { return }
        fit()
        let carets = self.carets?.carets ?? []
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }

        // What it just changed, tinted until the director clears it
        let changed = UIBezierPath()
        for caret in carets {
            for range in caret.changed {
                for rect in host.partnerRects(forRaw: target.realRange(forAgent: range)) {
                    changed.append(UIBezierPath(roundedRect: rect, cornerRadius: 3))
                }
            }
        }
        changedLayer.path = changed.cgPath

        // The word it is typing: the old word covered, the new one drawn in its place
        if let ghost = target.ghost, let layout = ghostLayout(ghost, in: textView) {
            let cover = UIBezierPath()
            for rect in layout.covered { cover.append(UIBezierPath(rect: rect.insetBy(dx: -1, dy: 0))) }
            ghostCover.path = cover.cgPath
            ghostCover.fillColor = (textView.backgroundColor ?? .systemBackground).cgColor
            ghostLabel.attributedText = NSAttributedString(string: ghost.text, attributes: layout.attributes)
            ghostLabel.sizeToFit()
            ghostLabel.frame.origin = layout.origin
            ghostLabel.isHidden = false
        } else {
            ghostCover.path = nil
            ghostLabel.isHidden = true
        }

        // Its caret
        if let caret = carets.first, let rect = caretRect(atAgent: caret.head, target: target) {
            caretLayer.frame = CGRect(x: rect.minX, y: rect.minY, width: 2, height: rect.height)
            caretLayer.isHidden = false
        } else {
            caretLayer.isHidden = true
        }
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
                return CGRect(x: layout.origin.x + prefix.size().width, y: layout.origin.y, width: 2, height: layout.height)
            }
        }
        return host.partnerCaretRect(atRaw: target.realPosition(forAgent: position))
    }

    private func ghostLayout(_ ghost: (range: NSRange, text: String), in textView: UITextView)
        -> (origin: CGPoint, height: CGFloat, attributes: [NSAttributedString.Key: Any], covered: [CGRect])? {
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
        let font = attributes[.font] as? UIFont ?? .preferredFont(forTextStyle: .body)
        // The drawn word's line is centred on the caret's, which UIKit sizes from the same font
        let origin = CGPoint(x: caret.minX, y: caret.midY - font.lineHeight / 2)
        return (origin, caret.height, attributes, IOSWritingPartnerHost.rects(forStorage: range, in: textView))
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
        if let textView = superview as? UITextView, y + size.height > textView.contentOffset.y + textView.bounds.height - margin {
            y = max(margin, rect.minY - size.height - 8)
        }
        hosting.view.frame = CGRect(x: x, y: y, width: size.width, height: size.height)
        addSubview(hosting.view)
        UIAccessibility.post(notification: .layoutChanged, argument: hosting.view)
        return hosting.view
    }
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
                Button("Automatically") { onChooseMode(.automatic) }
                    .buttonStyle(.glassProminent)
                Button("Suggest") { onChooseMode(.suggest) }
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

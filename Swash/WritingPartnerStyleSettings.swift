//
//  WritingPartnerStyleSettings.swift
//  Swash
//
//  Settings › Writing: how the writing partner's fixes look (#100). The styles are Flair's text
//  treatments, and the preview plays the chosen one on a sample sentence: the partner's cursor
//  selects a misspelt word, types the right one over it, and the fix lands.
//

#if os(macOS)
import AppKit
import FlairEffects
import SwiftUI

/// The "Partner style" picker and its preview.
struct WritingPartnerStyleSection: View {
    @AppStorage(WritingPartnerDefaults.style) private var style = WritingPartnerDefaults.defaultStyle

    /// Every treatment, the partner's default first.
    private var styles: [FlairTextTreatment] {
        FlairTextTreatments.all.sorted { a, b in
            (a.id == WritingPartnerDefaults.defaultStyle ? 0 : 1) < (b.id == WritingPartnerDefaults.defaultStyle ? 0 : 1)
        }
    }

    var body: some View {
        Section {
            Picker("Partner style", selection: $style) {
                ForEach(styles, id: \.id) { treatment in
                    Text(treatment.name).tag(treatment.id)
                }
            }
            WritingPartnerStylePreview(style: style)
                .frame(height: 64)
                .accessibilityLabel("A preview of the partner fixing a misspelt word in this style")
        } footer: {
            // Other targets compile this file without SettingsView's footer style
            Text(FlairTextTreatments.treatment(id: style)?.description ?? "")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }
}

private struct WritingPartnerStylePreview: NSViewRepresentable {
    let style: String

    func makeNSView(context: Context) -> WritingPartnerStylePreviewView { WritingPartnerStylePreviewView() }

    func updateNSView(_ view: WritingPartnerStylePreviewView, context: Context) { view.style = style }
}

/// A sample sentence with one wrong word, fixed over and over in a style.
final class WritingPartnerStylePreviewView: NSView {
    private static let before = "It fixes the odd "
    private static let wrong = "wrod"
    private static let right = "word"
    private static let after = " as you write."

    /// The script, in ms: the cursor arrives, selects the word, types the new one a letter at a
    /// time, the fix lands and stays, then it starts again.
    private static let selectAt: Double = 700
    private static let typeMs: Double = 70
    private static let hold: Double = 2600

    var style = WritingPartnerDefaults.defaultStyle {
        didSet { if style != oldValue { look = nil; start = WritingPartnerStylePreviewView.now } }
    }

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
    }

    required init?(coder: NSCoder) { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        timer?.invalidate()
        timer = nil
        guard window != nil else { return }
        start = Self.now
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

    private func draw() {
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
        let origin = NSPoint(x: 14, y: (bounds.height - lineHeight) / 2)
        let wordX = origin.x + width(Self.before)
        let line = { (word: String) in NSRect(x: wordX, y: origin.y, width: self.width(word), height: lineHeight) }
        let caret = { (x: CGFloat) in FlairTreatmentCaret(x: Double(x), y: Double(origin.y), height: Double(lineHeight)) }

        let typeEnd = Self.selectAt + WritingPartnerOverlay.selectMs + Self.typeMs * Double(Self.right.count + 1)
        var time = Self.now - start
        if time > typeEnd + Self.hold {
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
            let target = FlairTreatmentTarget(lines: [line(Self.right)], caret: caret(wordX + width(Self.right)))
            let landed = look.plan(.landed, at: time - typeEnd, over: target)
            if !landed.done { plans.append(landed) }
        }

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        label.contentsScale = window?.backingScaleFactor ?? 2
        label.foregroundColor = ink.cgColor
        label.string = Self.before + shown + Self.after
        label.frame = NSRect(x: origin.x, y: origin.y, width: bounds.width - origin.x * 2, height: lineHeight + 2)
        CATransaction.commit()
        renderer.contentsScale = label.contentsScale
        renderer.draw(plans, font: font)
    }
}
#endif

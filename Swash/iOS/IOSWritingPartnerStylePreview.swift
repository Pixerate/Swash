//
//  IOSWritingPartnerStylePreview.swift
//  Swash
//
//  Settings › Writing Partner › Partner style on iPhone and iPad (#229): the same Flair text
//  treatments and level-aware sample as the Mac's (WritingPartnerStyleSettings.swift), drawn in a
//  UIView. Off shows the sentence as typed; Copyedit fixes a misspelt word; Ghostwrite rewrites
//  rough notes as prose.
//

#if os(iOS)
import FlairEffects
import SwiftUI
import UIKit

/// The "Partner style" picker and its preview of `level`.
struct IOSWritingPartnerStyleSection: View {
    var level: WritingPartnerMode
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
            IOSWritingPartnerStylePreview(style: style, level: level)
                .frame(height: 56)
                .listRowInsets(EdgeInsets())
                .accessibilityElement()
                .accessibilityLabel(WritingPartnerPreviewScript.script(for: level).accessibilityLabel)
        } footer: {
            Text(FlairTextTreatments.treatment(id: style)?.description ?? "")
        }
    }
}

private struct IOSWritingPartnerStylePreview: UIViewRepresentable {
    let style: String
    let level: WritingPartnerMode

    func makeUIView(context: Context) -> IOSWritingPartnerStylePreviewView { IOSWritingPartnerStylePreviewView() }

    func updateUIView(_ view: IOSWritingPartnerStylePreviewView, context: Context) {
        view.style = style
        view.level = level
    }
}

/// A sample sentence the partner's cursor changes in the chosen style, as the chosen level would.
final class IOSWritingPartnerStylePreviewView: UIView {
    private static let selectAt: Double = 700
    private static let selectMs: Double = 180
    private static let typeMs: Double = 70
    private static let hold: Double = 2600

    var style = WritingPartnerDefaults.defaultStyle {
        didSet { if style != oldValue { stages = nil; restart() } }
    }

    var level: WritingPartnerMode = .copyedit {
        didSet {
            guard level != oldValue else { return }
            script = WritingPartnerPreviewScript.script(for: level)
            restart()
        }
    }

    private var script = WritingPartnerPreviewScript.script(for: .copyedit)
    private let renderer = FlairTextTreatmentRenderer()
    private let label = CATextLayer()
    private var stages: FlairJSON?
    private var start = CACurrentMediaTime() * 1000
    private var link: CADisplayLink?
    private let font = UIFont.preferredFont(forTextStyle: .body)

    private var typeEnd: Double {
        Self.selectAt + Self.selectMs + Self.typeMs * Double(script.right.count + 1)
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        isAccessibilityElement = false
        label.font = font
        label.fontSize = font.pointSize
        label.actions = ["contents": NSNull(), "string": NSNull(), "foregroundColor": NSNull()]
        layer.addSublayer(renderer.behindLayer)
        layer.addSublayer(label)
        layer.addSublayer(renderer.aboveLayer)
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (self: Self, _: UITraitCollection) in
            self.stages = nil
            self.draw()
        }
    }

    required init?(coder: NSCoder) { nil }

    /// Nonisolated: an isolated deinit crashes on the iOS Simulator (GOTCHAS #103).
    nonisolated deinit {}

    override func didMoveToWindow() {
        super.didMoveToWindow()
        restart()
    }

    private func restart() {
        link?.invalidate()
        link = nil
        start = CACurrentMediaTime() * 1000
        draw()
        guard window != nil, script.plays else { return }
        let link = CADisplayLink(target: self, selector: #selector(tick))
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    override func removeFromSuperview() {
        link?.invalidate()
        link = nil
        super.removeFromSuperview()
    }

    @objc private func tick() { draw() }

    private func width(_ text: String) -> CGFloat {
        (text as NSString).size(withAttributes: [.font: font]).width
    }

    private static func rgba(_ color: UIColor, in traits: UITraitCollection) -> FlairRGBA {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        color.resolvedColor(with: traits).getRed(&r, green: &g, blue: &b, alpha: &a)
        return FlairRGBA(Double(r), Double(g), Double(b), Double(a))
    }

    private func resolvedStages() -> FlairJSON? {
        if let stages { return stages }
        guard let treatment = FlairTextTreatments.treatment(id: style)
                ?? FlairTextTreatments.treatment(id: WritingPartnerDefaults.defaultStyle)
                ?? FlairTextTreatments.all.first else { return nil }
        let tint = Self.rgba(IOSWritingPartnerOverlay.tint, in: traitCollection)
        let values = treatment.values(values: [
            "color": .string(String(format: "#%02X%02X%02X", Int((tint.r * 255).rounded()),
                                    Int((tint.g * 255).rounded()), Int((tint.b * 255).rounded()))),
            "darkTheme": .bool(traitCollection.userInterfaceStyle == .dark),
            "nameTag": .bool(false),
        ])
        stages = FlairTextTreatments.resolve(treatment, values: values)
        return stages
    }

    private func draw() {
        guard let stages = resolvedStages() else { return }
        let reduceMotion = UIAccessibility.isReduceMotionEnabled
        let plan = { (stage: FlairTextTreatmentStage, time: Double, target: FlairTreatmentTarget) in
            FlairTextTreatments.planResolved(stages, stage: stage, time: max(0, time), target: target, reduceMotion: reduceMotion)
        }
        let ink = UIColor.label.resolvedColor(with: traitCollection)
        let background = UIColor.secondarySystemGroupedBackground.resolvedColor(with: traitCollection)
        backgroundColor = background

        let lineHeight = font.lineHeight
        let origin = CGPoint(x: 16, y: max(4, (bounds.height - lineHeight) / 2))
        let wordX = origin.x + width(script.before)
        let line = { (word: String) in CGRect(x: wordX, y: origin.y, width: self.width(word), height: lineHeight) }
        let caret = { (x: CGFloat) in FlairTreatmentCaret(x: Double(x), y: Double(origin.y), height: Double(lineHeight)) }

        var time = CACurrentMediaTime() * 1000 - start
        if time > typeEnd + Self.hold {
            start = CACurrentMediaTime() * 1000
            time = 0
        }

        var plans: [FlairTextTreatmentPlan] = []
        var shown = script.wrong
        if !script.plays {
            // Off: the sentence as typed, and no partner
        } else if time < Self.selectAt {
            plans.append(plan(.caret, time, FlairTreatmentTarget(caret: caret(wordX + width(script.wrong)))))
        } else if time < Self.selectAt + Self.selectMs {
            let target = FlairTreatmentTarget(lines: [line(script.wrong)], caret: caret(wordX + width(script.wrong)))
            plans.append(plan(.selecting, time - Self.selectAt, target))
            plans.append(plan(.caret, time, FlairTreatmentTarget(caret: target.caret)))
        } else if time < typeEnd {
            let typing = time - Self.selectAt - Self.selectMs
            let typed = String(script.right.prefix(min(script.right.count, Int(typing / Self.typeMs))))
            let head = caret(wordX + width(typed))
            let target = FlairTreatmentTarget(lines: [line(script.wrong)], caret: head, text: typed,
                                              color: Self.rgba(ink, in: traitCollection),
                                              background: Self.rgba(background, in: traitCollection))
            plans.append(plan(.typing, typing, target))
            plans.append(plan(.caret, time, FlairTreatmentTarget(caret: head)))
        } else {
            shown = script.right
            let target = FlairTreatmentTarget(lines: [line(script.right)], caret: caret(wordX + width(script.right)))
            let landed = plan(.landed, time - typeEnd, target)
            if !landed.done { plans.append(landed) }
        }

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        label.contentsScale = window?.screen.scale ?? 2
        label.foregroundColor = ink.cgColor
        label.string = script.before + shown + script.after
        label.frame = CGRect(x: origin.x, y: origin.y, width: max(120, bounds.width - origin.x * 2), height: lineHeight + 2)
        CATransaction.commit()
        renderer.contentsScale = label.contentsScale
        renderer.draw(plans, font: font as CTFont)
    }
}

#Preview("Partner style", traits: .sizeThatFitsLayout) {
    @Previewable @State var level = WritingPartnerMode.copyedit
    Form {
        Picker("Level", selection: $level) {
            ForEach(WritingPartnerMode.allCases) { Text($0.title).tag($0) }
        }
        .pickerStyle(.segmented)
        IOSWritingPartnerStyleSection(level: level)
    }
}
#endif

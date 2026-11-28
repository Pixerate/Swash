//
//  StyledLayoutManager.swift
//  Swash
//
//  TextKit 1 layout manager for the iOS Edit Text editor. It draws what the macOS
//  SwashLayoutManager and NSTextBlock draw there: quote, alert and code boxes and rules
//  (`.blockDecorations`), list bullets and checkboxes (SF Symbols), code-block language badges, alert icons and
//  rendered math and Mermaid previews.
//

#if os(iOS)
import UIKit

final class StyledLayoutManager: NSLayoutManager {
    /// The text view using this layout manager.
    weak var styledTextView: StyledUITextView?

    /// The storage character range kept at full strength in Focus Mode (nil when Focus Mode is off).
    var focusedCharacterRange: NSRange?
    static let unfocusedAlpha: CGFloat = 0.3

    /// Nonisolated: an isolated deinit crashes on the iOS Simulator (GOTCHAS #103).
    nonisolated deinit {}

    func focusAlpha(for characterIndex: Int) -> CGFloat {
        guard let focused = focusedCharacterRange else { return 1 }
        return NSLocationInRange(characterIndex, focused) ? 1 : Self.unfocusedAlpha
    }

    override func drawGlyphs(forGlyphRange glyphsToShow: NSRange, at origin: CGPoint) {
        guard let focused = focusedCharacterRange, let context = UIGraphicsGetCurrentContext() else {
            super.drawGlyphs(forGlyphRange: glyphsToShow, at: origin)
            return
        }
        // The range can be stale for a moment after an edit shortens the text
        let length = textStorage?.length ?? 0
        let clamped = NSIntersectionRange(focused, NSRange(location: 0, length: length))
        let focusedGlyphs = glyphRange(forCharacterRange: clamped, actualCharacterRange: nil)
        let before = NSIntersectionRange(glyphsToShow, NSRange(location: 0, length: focusedGlyphs.location))
        let inside = NSIntersectionRange(glyphsToShow, focusedGlyphs)
        let afterStart = NSMaxRange(focusedGlyphs)
        let after = afterStart < NSMaxRange(glyphsToShow)
            ? NSIntersectionRange(glyphsToShow, NSRange(location: afterStart, length: NSMaxRange(glyphsToShow) - afterStart))
            : NSRange(location: 0, length: 0)
        for dimmed in [before, after] where dimmed.length > 0 {
            context.saveGState()
            context.setAlpha(Self.unfocusedAlpha)
            super.drawGlyphs(forGlyphRange: dimmed, at: origin)
            context.restoreGState()
        }
        if inside.length > 0 {
            super.drawGlyphs(forGlyphRange: inside, at: origin)
        }
    }

    private var currentTraits: UITraitCollection {
        styledTextView?.traitCollection ?? .current
    }

    private var canvasBackground: UIColor {
        if let tv = styledTextView {
            if let bg = tv.backgroundColor, bg != UIColor.clear {
                return bg
            }
            if let bg = tv.coordinator?.parent.typography.theme.background {
                return bg
            }
        }
        return .systemBackground
    }

    private var themeAccentColor: UIColor {
        if let accent = styledTextView?.coordinator?.parent.typography.accentColor {
            return accent
        }
        return styledTextView?.tintColor ?? .tintColor
    }

    override func drawBackground(forGlyphRange glyphsToShow: NSRange, at origin: CGPoint) {
        drawBlockDecorations(forGlyphRange: glyphsToShow, at: origin)
        super.drawBackground(forGlyphRange: glyphsToShow, at: origin)

        guard let textStorage = textStorage, let context = UIGraphicsGetCurrentContext() else { return }
        let charRange = characterRange(forGlyphRange: glyphsToShow, actualGlyphRange: nil)

        textStorage.enumerateAttribute(.codeBadge, in: charRange, options: []) { value, range, _ in
            guard let badge = value as? CodeBadgeInfo else { return }
            let lineRect = lineFragmentRect(forGlyphAt: glyphIndexForCharacter(at: range.location), effectiveRange: nil)
            let rect = badge.rect(in: textLineRect(lineRect, at: range.location)).offsetBy(dx: origin.x, dy: origin.y)
            var attributes = CodeBadgeInfo.attributes
            if self.focusAlpha(for: range.location) < 1 {
                attributes[.foregroundColor] = UIColor.tertiaryLabel.withAlphaComponent(Self.unfocusedAlpha)
            }
            (badge.title as NSString).draw(at: CGPoint(x: rect.minX + 2, y: rect.minY + 1), withAttributes: attributes)
        }

        textStorage.enumerateAttribute(.alertIcon, in: charRange, options: []) { value, range, _ in
            guard let icon = value as? AlertIconInfo, let image = icon.image else { return }
            let glyph = glyphIndexForCharacter(at: range.location)
            let lineRect = lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
            let used = lineFragmentUsedRect(forGlyphAt: glyph, effectiveRange: nil)
            let titleX = lineRect.origin.x + location(forGlyphAt: glyph).x
            let size = image.size
            image.draw(in: CGRect(x: origin.x + titleX - size.width - 5, y: origin.y + used.midY - size.height / 2, width: size.width, height: size.height),
                       blendMode: .normal, alpha: self.focusAlpha(for: range.location))
        }

        textStorage.enumerateAttribute(.richPreview, in: charRange, options: []) { value, range, _ in
            guard let info = value as? RichPreviewInfo else { return }
            drawRichPreview(info, atCharacter: range.location, origin: origin)
        }

        textStorage.enumerateAttribute(.listMarker, in: charRange, options: []) { value, range, _ in
            guard let marker = value as? ListMarkerInfo else { return }
            let markerGlyphs = glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            guard let geometry = self.listMarkerGeometry(forMarkerGlyphs: markerGlyphs, indent: marker.indent) else { return }
            let textFont = geometry.font
            let markerRect = ListMarkerRenderer.markerRect(for: marker, geometry: geometry).offsetBy(dx: origin.x, dy: origin.y)
            let alpha = self.focusAlpha(for: range.location)
            let traits = self.currentTraits
            let canvasBg = self.canvasBackground

            if alpha < 1 {
                context.saveGState()
                context.setAlpha(alpha)
            }

            if let image = ListMarkerRenderer.symbolImage(for: marker, font: textFont) {
                // SF Symbols, like Reminders' circles and the system's list bullets (#184)
                let base: UIColor = marker.isChecked
                    ? (marker.color ?? self.themeAccentColor)
                    : ListMarkerRenderer.neutralColor(for: traits)
                let tint = ListMarkerRenderer.accessibleColor(for: base, on: canvasBg, traits: traits, minContrast: 3.0)
                // UIImage drawing sets its own alpha, so the Focus Mode fade is passed in rather than taken from the context
                image.withTintColor(tint, renderingMode: .alwaysOriginal).draw(in: markerRect, blendMode: .normal, alpha: alpha)
            } else {
                let numberFont = ListMarkerRenderer.numberFont(for: textFont)
                let baseColor = marker.color ?? ListMarkerRenderer.neutralColor(for: traits)
                let numberColor = ListMarkerRenderer.accessibleColor(for: baseColor, on: canvasBg, traits: traits, minContrast: 3.0)
                let attributes: [NSAttributedString.Key: Any] = [
                    .font: numberFont,
                    .foregroundColor: numberColor
                ]
                (marker.text as NSString).draw(in: CGRect(x: markerRect.minX, y: markerRect.minY, width: markerRect.width + 4.0, height: markerRect.height), withAttributes: attributes)
            }

            if alpha < 1 {
                context.restoreGState()
            }
        }
    }

    /// Where a list marker's item text sits, in text-container coordinates, for drawing the marker and hit-testing it.
    func listMarkerGeometry(forMarkerGlyphs markerGlyphs: NSRange, indent: CGFloat) -> ListMarkerGeometry? {
        listMarkerGeometry(forMarkerGlyphs: markerGlyphs, indent: indent, defaultFont: defaultBodyFont)
    }

    private var defaultBodyFont: UIFont {
        if let typography = styledTextView?.coordinator?.parent.typography {
            return typography.font(ofSize: typography.textSize * MarkdownEditorStyler.fontScale, weight: .regular)
        }
        return UIFont.systemFont(ofSize: 14 * MarkdownEditorStyler.fontScale)
    }

    /// Every code-block language badge, in text-container coordinates.
    func codeBadgeRects() -> [(location: Int, info: CodeBadgeInfo, rect: CGRect)] {
        guard let storage = textStorage else { return [] }
        var result: [(location: Int, info: CodeBadgeInfo, rect: CGRect)] = []
        storage.enumerateAttribute(.codeBadge, in: NSRange(location: 0, length: storage.length), options: []) { value, range, _ in
            guard let badge = value as? CodeBadgeInfo else { return }
            let lineRect = lineFragmentRect(forGlyphAt: glyphIndexForCharacter(at: range.location), effectiveRange: nil)
            result.append((range.location, badge, badge.rect(in: textLineRect(lineRect, at: range.location))))
        }
        return result
    }

    /// The line fragment narrowed to the content area of the innermost box around `location`, as
    /// NSTextBlock line fragments are on macOS.
    private func textLineRect(_ lineRect: CGRect, at location: Int) -> CGRect {
        guard let storage = textStorage, location < storage.length,
              let box = (storage.attribute(.blockDecorations, at: location, effectiveRange: nil) as? [BlockDecoration])?.last else { return lineRect }
        let padding = textContainers.first?.lineFragmentPadding ?? 0
        let left = box.left + box.leftBorderWidth
        let right = box.right + box.borderWidth
        return CGRect(x: lineRect.minX + padding + left, y: lineRect.minY,
                      width: max(0, lineRect.width - padding * 2 - left - right), height: lineRect.height)
    }

    // MARK: Boxes and rules

    /// Paints each visible decoration once, over the full height of the paragraphs it covers.
    private func drawBlockDecorations(forGlyphRange glyphsToShow: NSRange, at origin: CGPoint) {
        guard let storage = textStorage, let container = textContainers.first else { return }
        let charRange = characterRange(forGlyphRange: glyphsToShow, actualGlyphRange: nil)
        var painted = Set<ObjectIdentifier>()
        storage.enumerateAttribute(.blockDecorations, in: charRange, options: []) { value, range, _ in
            guard let decorations = value as? [BlockDecoration] else { return }
            for decoration in decorations where !painted.contains(ObjectIdentifier(decoration)) {
                painted.insert(ObjectIdentifier(decoration))
                let extent = self.extent(of: decoration, around: range.location, in: storage)
                let glyphs = glyphRange(forCharacterRange: extent, actualCharacterRange: nil)
                guard glyphs.length > 0 else { continue }
                var top = CGFloat.greatestFiniteMagnitude
                var bottom = -CGFloat.greatestFiniteMagnitude
                var lineMinX: CGFloat = 0
                var lineMaxX: CGFloat = container.size.width
                enumerateLineFragments(forGlyphRange: glyphs) { rect, _, _, _, _ in
                    top = min(top, rect.minY)
                    bottom = max(bottom, rect.maxY)
                    lineMinX = rect.minX
                    lineMaxX = rect.maxX
                }
                guard top < bottom else { continue }
                let padding = container.lineFragmentPadding
                let left = origin.x + lineMinX + padding + decoration.left
                let right = origin.x + lineMaxX - padding - decoration.right
                let box = CGRect(x: left, y: origin.y + top, width: max(0, right - left), height: bottom - top)
                draw(decoration, in: box)
            }
        }
    }

    private func draw(_ decoration: BlockDecoration, in box: CGRect) {
        switch decoration.kind {
        case .rule:
            decoration.fill?.setFill()
            UIRectFillUsingBlendMode(CGRect(x: box.minX, y: box.midY - 0.5, width: box.width, height: 1), .normal)
        case .box:
            if let fill = decoration.fill {
                fill.setFill()
                UIRectFillUsingBlendMode(box, .normal)
            }
            guard let border = decoration.borderColor else { return }
            border.setFill()
            if decoration.borderWidth > 0 {
                let w = decoration.borderWidth
                UIRectFillUsingBlendMode(CGRect(x: box.minX, y: box.minY, width: box.width, height: w), .normal)
                UIRectFillUsingBlendMode(CGRect(x: box.minX, y: box.maxY - w, width: box.width, height: w), .normal)
                UIRectFillUsingBlendMode(CGRect(x: box.maxX - w, y: box.minY, width: w, height: box.height), .normal)
            }
            if decoration.leftBorderWidth > 0 {
                UIRectFillUsingBlendMode(CGRect(x: box.minX, y: box.minY, width: decoration.leftBorderWidth, height: box.height), .normal)
            }
        }
    }

    /// The characters whose `.blockDecorations` include `decoration`, around `location`.
    private func extent(of decoration: BlockDecoration, around location: Int, in storage: NSTextStorage) -> NSRange {
        func contains(_ index: Int) -> NSRange? {
            guard index >= 0, index < storage.length else { return nil }
            var run = NSRange()
            let value = storage.attribute(.blockDecorations, at: index, effectiveRange: &run) as? [BlockDecoration]
            return value?.contains(where: { $0 === decoration }) == true ? run : nil
        }
        guard var range = contains(location) else { return NSRange(location: location, length: 0) }
        while let previous = contains(range.location - 1) { range = NSUnionRange(range, previous) }
        while let next = contains(NSMaxRange(range)) { range = NSUnionRange(range, next) }
        return range
    }

    // MARK: Rendered math and diagrams

    /// Draws a rendered formula or diagram centred in the paragraph spacing below its block's last line.
    private func drawRichPreview(_ info: RichPreviewInfo, atCharacter location: Int, origin: CGPoint) {
        let glyph = glyphIndexForCharacter(at: location)
        guard glyph < numberOfGlyphs else { return }
        let lineRect = textLineRect(lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil), at: location)
        let used = lineFragmentUsedRect(forGlyphAt: glyph, effectiveRange: nil)
        var y = origin.y + used.maxY + RichPreviewInfo.spacing
        if let error = info.error {
            ("⚠︎ " + error as NSString).draw(with: CGRect(x: origin.x + lineRect.minX + 4, y: y, width: max(0, lineRect.width - 8), height: RichPreviewInfo.errorHeight),
                                            options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine], attributes: RichPreviewInfo.errorAttributes, context: nil)
            y += RichPreviewInfo.errorHeight
        }
        guard info.size.width > 0, info.size.height > 0 else { return }
        var size = info.size
        let available = max(20, lineRect.width - 8)
        if size.width > available {
            size = CGSize(width: available, height: size.height * available / size.width)
        }
        let rect = CGRect(x: origin.x + lineRect.minX + (lineRect.width - size.width) / 2, y: y, width: size.width, height: size.height)
        info.image.draw(in: rect, blendMode: .normal, alpha: info.alpha)
    }
}

/// SF Symbol choice, sizing and accessible contrast for list markers.
enum ListMarkerRenderer {
    /// The SF Symbol a marker is drawn with (see `ListMarkerStyle`), or nil for an ordered item.
    static func symbolName(for marker: ListMarkerInfo) -> String? {
        ListMarkerStyle.symbolName(for: marker)
    }

    /// The symbol configuration for a marker, sized from its line's font so it follows Dynamic Type and
    /// the Typography setting.
    static func symbolConfiguration(for marker: ListMarkerInfo, font: UIFont) -> UIImage.SymbolConfiguration {
        let pointSize = ListMarkerStyle.symbolPointSize(for: marker, fontSize: font.pointSize)
        return marker.isTask
            ? UIImage.SymbolConfiguration(pointSize: pointSize, weight: .regular, scale: .medium)
            : UIImage.SymbolConfiguration(pointSize: pointSize, weight: .bold, scale: .small)
    }

    /// The (untinted) symbol image for a marker, or nil for an ordered item.
    static func symbolImage(for marker: ListMarkerInfo, font: UIFont) -> UIImage? {
        guard let name = symbolName(for: marker) else { return nil }
        return UIImage(systemName: name, withConfiguration: symbolConfiguration(for: marker, font: font))
    }

    /// The size a marker's symbol draws at (zero for an ordered item).
    static func symbolSize(for marker: ListMarkerInfo, font: UIFont) -> CGSize {
        symbolImage(for: marker, font: font)?.size ?? .zero
    }

    /// The checkbox circle's size and its tap target (at least 44 pt, as the HIG asks).
    static func checkboxMetrics(for font: UIFont) -> (size: CGSize, hitTarget: CGFloat) {
        let size = symbolSize(for: ListMarkerInfo(text: "☐", indent: 0), font: font)
        return (size, max(44.0, max(size.width, size.height) + 16.0))
    }

    /// The colour of unticked checkboxes, bullets and numbers: `secondaryLabel`, or `label` under Increase Contrast.
    static func neutralColor(for traits: UITraitCollection) -> UIColor {
        traits.accessibilityContrast == .high ? .label : .secondaryLabel
    }

    /// The checkbox circle for a task item, just left of the item's text and centred on its first line.
    static func checkboxRect(_ geometry: ListMarkerGeometry) -> CGRect {
        ListMarkerStyle.checkboxRect(size: checkboxMetrics(for: geometry.font).size, geometry: geometry)
    }

    /// The font an ordered item's number is drawn in, with monospaced digits so numbers line up.
    static func numberFont(for font: UIFont) -> UIFont {
        UIFont.monospacedDigitSystemFont(ofSize: max(12.0, font.pointSize - 1.0), weight: .regular)
    }

    /// The rect a marker is drawn in: the checkbox, the bullet, or the number's text box.
    static func markerRect(for marker: ListMarkerInfo, geometry: ListMarkerGeometry) -> CGRect {
        if marker.isTask { return checkboxRect(geometry) }
        if marker.bulletKind != nil {
            return ListMarkerStyle.bulletRect(size: symbolSize(for: marker, font: geometry.font),
                                              checkboxSize: checkboxMetrics(for: geometry.font).size, geometry: geometry)
        }
        let numberFont = numberFont(for: geometry.font)
        let size = (marker.text as NSString).size(withAttributes: [.font: numberFont])
        return CGRect(x: geometry.contentX - size.width - 8.0, y: geometry.baselineY - numberFont.ascender, width: size.width, height: size.height)
    }

    static func rgbaComponents(for color: UIColor, traits: UITraitCollection) -> (r: CGFloat, g: CGFloat, b: CGFloat, a: CGFloat) {
        let resolved = color.resolvedColor(with: traits)
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        if resolved.getRed(&r, green: &g, blue: &b, alpha: &a) {
            return (r, g, b, a)
        }
        if let components = resolved.cgColor.converted(to: CGColorSpace(name: CGColorSpace.sRGB)!, intent: .defaultIntent, options: nil)?.components,
           components.count >= 3 {
            return (components[0], components[1], components[2], components.count > 3 ? components[3] : 1.0)
        }
        return (0.5, 0.5, 0.5, 1.0)
    }

    static func relativeLuminance(r: CGFloat, g: CGFloat, b: CGFloat) -> CGFloat {
        ListMarkerStyle.relativeLuminance(r: r, g: g, b: b)
    }

    static func contrastRatio(_ l1: CGFloat, _ l2: CGFloat) -> CGFloat {
        ListMarkerStyle.contrastRatio(l1, l2)
    }

    /// `foreground`, adjusted if needed to reach at least `minContrast` (default 3:1) against `background` under `traits`.
    static func accessibleColor(for foreground: UIColor, on background: UIColor, traits: UITraitCollection, minContrast: CGFloat = 3.0) -> UIColor {
        let fgResolved = foreground.resolvedColor(with: traits)
        let (bgR, bgG, bgB, _) = rgbaComponents(for: background, traits: traits)
        let (fgR, fgG, fgB, fgA) = rgbaComponents(for: fgResolved, traits: traits)
        let adjusted = ListMarkerStyle.contrastAdjusted((fgR, fgG, fgB), on: (bgR, bgG, bgB), minContrast: minContrast)
        if adjusted == (fgR, fgG, fgB) { return fgResolved }
        return UIColor(red: adjusted.r, green: adjusted.g, blue: adjusted.b, alpha: fgA)
    }
}
#endif

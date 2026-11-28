//
//  StyledLayoutManager.swift
//  Swash
//
//  TextKit 1 layout manager for the iOS Edit Text editor. It draws what the macOS
//  SwashLayoutManager and NSTextBlock draw there: quote, alert and code boxes and rules
//  (`.blockDecorations`), list bullets and checkboxes, code-block language badges, alert icons and
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

            if marker.isTask {
                let metrics = ListMarkerRenderer.checkboxMetrics(for: textFont)
                let boxRect = markerRect

                if marker.isChecked {
                    let baseAccent = marker.color ?? self.themeAccentColor
                    let fillColor = ListMarkerRenderer.accessibleColor(for: baseAccent, on: canvasBg, traits: traits, minContrast: 3.0)
                    let fillPath = UIBezierPath(roundedRect: boxRect, cornerRadius: metrics.cornerRadius)
                    fillColor.setFill()
                    fillPath.fill()

                    let checkPath = UIBezierPath()
                    checkPath.move(to: CGPoint(x: boxRect.minX + boxRect.width * 0.26, y: boxRect.minY + boxRect.height * 0.52))
                    checkPath.addLine(to: CGPoint(x: boxRect.minX + boxRect.width * 0.42, y: boxRect.minY + boxRect.height * 0.70))
                    checkPath.addLine(to: CGPoint(x: boxRect.minX + boxRect.width * 0.74, y: boxRect.minY + boxRect.height * 0.32))
                    checkPath.lineWidth = max(1.5, round(metrics.boxSize * 0.12))
                    checkPath.lineCapStyle = .round
                    checkPath.lineJoinStyle = .round
                    canvasBg.resolvedColor(with: traits).setStroke()
                    checkPath.stroke()
                } else {
                    let baseBorder = marker.color ?? UIColor.secondaryLabel
                    let strokeColor = ListMarkerRenderer.accessibleColor(for: baseBorder, on: canvasBg, traits: traits, minContrast: 3.0)
                    let strokeRect = boxRect.insetBy(dx: metrics.lineWidth / 2.0, dy: metrics.lineWidth / 2.0)
                    let strokePath = UIBezierPath(roundedRect: strokeRect, cornerRadius: metrics.cornerRadius)
                    strokePath.lineWidth = metrics.lineWidth
                    strokeColor.setStroke()
                    strokePath.stroke()
                }
            } else if let bulletKind = marker.bulletKind {
                let metrics = ListMarkerRenderer.bulletMetrics(for: textFont)
                let bulletRect = markerRect
                let baseColor = marker.color ?? UIColor.secondaryLabel
                let bulletColor = ListMarkerRenderer.accessibleColor(for: baseColor, on: canvasBg, traits: traits, minContrast: 3.0)

                switch bulletKind {
                case .disc:
                    let discPath = UIBezierPath(ovalIn: bulletRect)
                    bulletColor.setFill()
                    discPath.fill()
                case .ring:
                    let ringRect = bulletRect.insetBy(dx: metrics.ringStrokeWidth / 2.0, dy: metrics.ringStrokeWidth / 2.0)
                    let ringPath = UIBezierPath(ovalIn: ringRect)
                    ringPath.lineWidth = metrics.ringStrokeWidth
                    bulletColor.setStroke()
                    ringPath.stroke()
                case .square:
                    let squarePath = UIBezierPath(roundedRect: bulletRect, cornerRadius: metrics.squareCornerRadius)
                    bulletColor.setFill()
                    squarePath.fill()
                }
            } else {
                let numberFont = ListMarkerRenderer.numberFont(for: textFont)
                let baseColor = marker.color ?? UIColor.secondaryLabel
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
        guard let textStorage, markerGlyphs.length > 0, markerGlyphs.location < numberOfGlyphs else { return nil }
        var lineGlyphs = NSRange()
        let lineRect = lineFragmentRect(forGlyphAt: markerGlyphs.location, effectiveRange: &lineGlyphs)

        // A hidden marker is set in a 0.01 pt font (MarkdownEditorStyler.hide), so it can't stand in for the item's text
        func visibleFont(atGlyph glyph: Int) -> UIFont? {
            let char = characterIndexForGlyph(at: glyph)
            guard char < textStorage.length, let font = textStorage.attribute(.font, at: char, effectiveRange: nil) as? UIFont,
                  font.pointSize >= 1 else { return nil }
            return font
        }

        // The item's first visible glyph on this line: an empty item at the end of the document has none, and
        // its content glyph clamps to the hidden marker itself
        var anchorGlyph: Int?
        var anchorFont: UIFont?
        let searchStart = max(NSMaxRange(markerGlyphs), lineGlyphs.location)
        if searchStart < NSMaxRange(lineGlyphs) {
            for glyph in searchStart..<NSMaxRange(lineGlyphs) {
                if let font = visibleFont(atGlyph: glyph) {
                    anchorGlyph = glyph
                    anchorFont = font
                    break
                }
            }
        }
        let textFont = anchorFont ?? defaultBodyFont

        // Without visible text, the item's text would start where the (practically zero-width) hidden marker sits
        let contentX = lineRect.minX + location(forGlyphAt: anchorGlyph ?? (NSMaxRange(markerGlyphs) - 1)).x
        let effectiveContentX = contentX > 0 ? contentX : indent

        let baselineY: CGFloat
        if let anchorGlyph, location(forGlyphAt: anchorGlyph).y > 1 {
            baselineY = lineRect.minY + location(forGlyphAt: anchorGlyph).y
        } else {
            // Nothing visible to measure (an empty `- ` or `- [ ] ` item): centre the body font's line in the
            // line fragment, keeping the marker inside its own line rather than on its top edge (#190)
            let used = lineFragmentUsedRect(forGlyphAt: markerGlyphs.location, effectiveRange: nil)
            let band = used.height >= textFont.lineHeight * 0.5 ? used : lineRect
            baselineY = band.midY + (textFont.ascender + textFont.descender) / 2.0
        }
        return ListMarkerGeometry(lineRect: lineRect, font: textFont, baselineY: baselineY, contentX: effectiveContentX)
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

/// Where a list item's text sits on its first line, in text-container coordinates.
struct ListMarkerGeometry {
    let lineRect: CGRect
    /// The item text's font (the body font for an empty item).
    let font: UIFont
    let baselineY: CGFloat
    /// The x where the item's text starts; markers are drawn just left of it.
    let contentX: CGFloat

    /// The visual centre of the item's text (half its cap height above the baseline).
    var midY: CGFloat { baselineY - font.capHeight / 2.0 }
}

/// Vector geometry, dynamic scaling and accessible contrast calculation for list markers.
enum ListMarkerRenderer {
    /// The checkbox square for a task item.
    static func checkboxRect(_ geometry: ListMarkerGeometry) -> CGRect {
        let boxSize = checkboxMetrics(for: geometry.font).boxSize
        return CGRect(x: geometry.contentX - boxSize - 6.0, y: geometry.midY - boxSize / 2.0, width: boxSize, height: boxSize)
    }

    /// The font an ordered item's number is drawn in.
    static func numberFont(for font: UIFont) -> UIFont {
        UIFont.systemFont(ofSize: max(12.0, font.pointSize - 1.0), weight: .regular)
    }

    /// The rect a marker is drawn in: the checkbox, the bullet, or the number's text box.
    static func markerRect(for marker: ListMarkerInfo, geometry: ListMarkerGeometry) -> CGRect {
        if marker.isTask { return checkboxRect(geometry) }
        if marker.bulletKind != nil {
            let bulletSize = bulletMetrics(for: geometry.font).bulletSize
            let centerX = checkboxRect(geometry).midX
            return CGRect(x: centerX - bulletSize / 2.0, y: geometry.midY - bulletSize / 2.0, width: bulletSize, height: bulletSize)
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
        func channel(_ val: CGFloat) -> CGFloat {
            val <= 0.04045 ? val / 12.92 : pow((val + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * channel(r) + 0.7152 * channel(g) + 0.0722 * channel(b)
    }

    static func contrastRatio(_ l1: CGFloat, _ l2: CGFloat) -> CGFloat {
        let lighter = max(l1, l2)
        let darker = min(l1, l2)
        return (lighter + 0.05) / (darker + 0.05)
    }

    /// Dynamically adjusts foreground color to guarantee at least `minContrast` (default 3.0:1) against `background` under `traits`.
    static func accessibleColor(for foreground: UIColor, on background: UIColor, traits: UITraitCollection, minContrast: CGFloat = 3.0) -> UIColor {
        let bgResolved = background.resolvedColor(with: traits)
        let fgResolved = foreground.resolvedColor(with: traits)
        let (bgR, bgG, bgB, _) = rgbaComponents(for: bgResolved, traits: traits)
        let (fgR, fgG, fgB, fgA) = rgbaComponents(for: fgResolved, traits: traits)
        let bgLum = relativeLuminance(r: bgR, g: bgG, b: bgB)
        let fgLum = relativeLuminance(r: fgR, g: fgG, b: fgB)

        let currentContrast = contrastRatio(bgLum, fgLum)
        if currentContrast >= minContrast {
            return fgResolved
        }

        let maxWhiteContrast = contrastRatio(bgLum, 1.0)
        let maxBlackContrast = contrastRatio(bgLum, 0.0)
        let targetIsWhite = maxWhiteContrast >= minContrast && (fgLum >= bgLum || maxBlackContrast < minContrast)

        let targetR: CGFloat = targetIsWhite ? 1.0 : 0.0
        let targetG: CGFloat = targetIsWhite ? 1.0 : 0.0
        let targetB: CGFloat = targetIsWhite ? 1.0 : 0.0

        var low: CGFloat = 0.0
        var high: CGFloat = 1.0
        var bestR = fgR
        var bestG = fgG
        var bestB = fgB

        for _ in 0..<16 {
            let mid = (low + high) / 2.0
            let r = fgR + (targetR - fgR) * mid
            let g = fgG + (targetG - fgG) * mid
            let b = fgB + (targetB - fgB) * mid
            let lum = relativeLuminance(r: r, g: g, b: b)
            let cr = contrastRatio(bgLum, lum)
            if cr >= minContrast {
                bestR = r
                bestG = g
                bestB = b
                high = mid
            } else {
                low = mid
            }
        }
        return UIColor(red: bestR, green: bestG, blue: bestB, alpha: fgA)
    }

    /// Checkbox dimensions scaled proportionally to font size.
    static func checkboxMetrics(for font: UIFont) -> (boxSize: CGFloat, cornerRadius: CGFloat, lineWidth: CGFloat) {
        let boxSize = round(max(14.0, font.pointSize * 0.95))
        let cornerRadius = max(2.0, round(boxSize * 0.22))
        let lineWidth = max(1.2, round(boxSize * 0.08))
        return (boxSize, cornerRadius, lineWidth)
    }

    /// Bullet dimensions scaled proportionally to font size.
    static func bulletMetrics(for font: UIFont) -> (bulletSize: CGFloat, ringStrokeWidth: CGFloat, squareCornerRadius: CGFloat) {
        let bulletSize = round(max(5.0, font.pointSize * 0.35))
        let ringStrokeWidth = max(1.2, round(bulletSize * 0.22))
        let squareCornerRadius = max(1.0, round(bulletSize * 0.18))
        return (bulletSize, ringStrokeWidth, squareCornerRadius)
    }
}
#endif

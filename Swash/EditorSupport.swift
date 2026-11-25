//
//  EditorSupport.swift
//  Swash
//
//  Pieces shared by the macOS (NSTextView) and iOS (UITextView) Edit Text editors: list marker
//  attributes, the attachment protocol and the map between text-storage and raw-Markdown offsets.
//

import Foundation
#if os(macOS)
import AppKit
#else
import UIKit
#endif

extension NSAttributedString.Key {
    static let listMarker = NSAttributedString.Key("SwashListMarkerKey")
}

extension Notification.Name {
    static let cellSelectionDidChange = Notification.Name("cellSelectionDidChange")
    static let removeCurrentTable = Notification.Name("removeCurrentTable")
}

/// A list bullet, number or task checkbox drawn by the layout manager in place of the hidden marker.
struct ListMarkerInfo: Hashable {
    enum Kind: Hashable {
        case bullet(level: Int)
        case task(checked: Bool)
        case number
    }

    let text: String
    let indent: CGFloat
    var color: PlatformColor? = nil
    var kind: Kind = .bullet(level: 1)

    init(text: String, indent: CGFloat, color: PlatformColor? = nil, kind: Kind? = nil) {
        self.text = text
        self.indent = indent
        self.color = color
        if let kind {
            self.kind = kind
        } else if text == "☐" || text == "☑" {
            self.kind = .task(checked: text == "☑")
        } else if text == "•" {
            self.kind = .bullet(level: 1)
        } else if text == "◦" {
            self.kind = .bullet(level: 2)
        } else if text == "▪" {
            self.kind = .bullet(level: 3)
        } else {
            self.kind = .number
        }
    }

    /// Task items keep a ☐/☑ glyph (written out by rich-text copies) but are drawn as checkboxes.
    var isTask: Bool {
        if case .task = kind { return true }
        return text == "☐" || text == "☑"
    }
    var isChecked: Bool {
        if case .task(let checked) = kind { return checked }
        return text == "☑"
    }

    // MARK: - Brand Inline Marker Metrics & Palette (docs/BRAND.md)

    /// Primary Swash fuchsia accent (`#C800DE` in Light, `#EE6BFF` in Dark; `docs/BRAND.md`).
    static let brandAccentColor = PlatformColor.appearanceAware(
        light: PlatformColor(srgbRed: 0xC8 / 255.0, green: 0x00 / 255.0, blue: 0xDE / 255.0, alpha: 1),
        dark: PlatformColor(srgbRed: 0xEE / 255.0, green: 0x6B / 255.0, blue: 0xFF / 255.0, alpha: 1)
    )

    /// Brand gradient stops for ticked checkboxes (`#EC4899` → `#E12AFB` → `#8E51FF`).
    static let brandGradientColors: [PlatformColor] = [
        PlatformColor(srgbRed: 0xEC / 255.0, green: 0x48 / 255.0, blue: 0x99 / 255.0, alpha: 1),
        PlatformColor(srgbRed: 0xE1 / 255.0, green: 0x2A / 255.0, blue: 0xFB / 255.0, alpha: 1),
        PlatformColor(srgbRed: 0x8E / 255.0, green: 0x51 / 255.0, blue: 0xFF / 255.0, alpha: 1),
    ]

    /// Pixel-square corner radius ratio (~28% of side).
    static let pixelCornerRatio: CGFloat = 0.28

    /// Checkbox side length (~0.9× the line's font cap height).
    static func checkboxSide(for font: PlatformFont) -> CGFloat {
        max(10, round(font.capHeight * 0.9 * 2) / 2)
    }

    /// Bullet diameter / side length (~0.35× the line's font x-height, with a crisp minimum).
    static func bulletSide(for font: PlatformFont, level: Int) -> CGFloat {
        let base = max(5.5, round(font.xHeight * 0.65 * 2) / 2)
        return level >= 3 ? max(4.5, round(font.xHeight * 0.55 * 2) / 2) : base
    }

    /// Bounding rect of a checkbox or bullet in layout coordinates, given the item's `contentX`
    /// and first-line `baselineY`.
    /// - Checkboxes are centred on the first line's cap height (`baselineY - font.capHeight / 2`).
    /// - Bullets are centred on the first line's x-height (`baselineY - font.xHeight / 2`).
    func markerRect(contentX: CGFloat, baselineY: CGFloat, font: PlatformFont) -> CGRect {
        let anchorX = contentX > 0 ? contentX : indent
        switch kind {
        case .task:
            let side = Self.checkboxSide(for: font)
            let midY = baselineY - font.capHeight / 2
            return CGRect(x: anchorX - side - 8, y: midY - side / 2, width: side, height: side)
        case .bullet(let level):
            let side = Self.bulletSide(for: font, level: max(1, level))
            let midY = baselineY - font.xHeight / 2
            return CGRect(x: anchorX - side - 10, y: midY - side / 2, width: side, height: side)
        case .number:
            let numFont = Self.monospacedNumberFont(for: font)
            let size = (text as NSString).size(withAttributes: [.font: numFont])
            return CGRect(x: anchorX - size.width - 8, y: baselineY - numFont.ascender, width: size.width + 4, height: size.height)
        }
    }

    /// Monospaced-digit font matching `font`'s size for numbered list markers.
    static func monospacedNumberFont(for font: PlatformFont) -> PlatformFont {
        PlatformFont.monospacedDigitSystemFont(ofSize: font.pointSize, weight: .regular)
    }

    /// Muted marker colour that meets >= 3:1 contrast in Light, Dark, and Increase Contrast.
    /// Under Increase Contrast, returns `primaryTextColor` (`label` / `labelColor`) per `docs/BRAND.md`.
    static func mutedMarkerColor(highContrast: Bool = false) -> PlatformColor {
        #if os(iOS)
        if highContrast { return .label }
        return UIColor { traits in
            if traits.accessibilityContrast == .high {
                return UIColor.label.resolvedColor(with: traits)
            }
            if traits.userInterfaceStyle == .dark {
                return UIColor(white: 0.68, alpha: 1)
            } else {
                return UIColor(white: 0.42, alpha: 1)
            }
        }
        #else
        if highContrast || NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast {
            return .labelColor
        }
        return NSColor(name: nil) { appearance in
            if NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast {
                return .labelColor
            }
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            return isDark ? NSColor(srgbRed: 0.68, green: 0.68, blue: 0.70, alpha: 1)
                          : NSColor(srgbRed: 0.42, green: 0.42, blue: 0.45, alpha: 1)
        }
        #endif
    }

    /// Level-1 bullet accent colour (uses custom theme colour when provided, or the Swash brand fuchsia).
    static func bulletAccentColor(custom: PlatformColor?, highContrast: Bool = false) -> PlatformColor {
        #if os(iOS)
        let base = custom ?? brandAccentColor
        return UIColor { traits in
            let resolved = base.resolvedColor(with: traits)
            if highContrast || traits.accessibilityContrast == .high {
                return resolved
            }
            return resolved.withAlphaComponent(0.85)
        }
        #else
        let base = custom ?? brandAccentColor
        if highContrast || NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast {
            return base
        }
        return base.withAlphaComponent(0.85)
        #endif
    }

    /// Draws this list marker in the current Core Graphics context at `origin` + layout coordinates.
    func draw(in cgContext: CGContext, contentX: CGFloat, baselineY: CGFloat, font: PlatformFont, alpha: CGFloat = 1, highContrast: Bool = false) {
        let rect = markerRect(contentX: contentX, baselineY: baselineY, font: font)
        cgContext.saveGState()
        defer { cgContext.restoreGState() }
        if alpha < 1 {
            cgContext.setAlpha(alpha)
        }

        switch kind {
        case .task(let checked):
            let radius = rect.width * Self.pixelCornerRatio
            let path = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
            if checked {
                cgContext.saveGState()
                cgContext.addPath(path)
                cgContext.clip()
                let cgColors = Self.brandGradientColors.map(\.cgColor) as CFArray
                let locations: [CGFloat] = [0.0, 0.5, 1.0]
                if let space = CGColorSpace(name: CGColorSpace.sRGB),
                   let gradient = CGGradient(colorsSpace: space, colors: cgColors, locations: locations) {
                    cgContext.drawLinearGradient(
                        gradient,
                        start: CGPoint(x: rect.minX, y: rect.minY),
                        end: CGPoint(x: rect.maxX, y: rect.maxY),
                        options: [.drawsBeforeStartLocation, .drawsAfterEndLocation]
                    )
                } else {
                    cgContext.setFillColor(Self.brandAccentColor.cgColor)
                    cgContext.fill(rect)
                }
                cgContext.restoreGState()

                // White calligraphic swash-stroke tick: tapered left entry, thicker downstroke vertex, tapered upper-right flourish
                let tick = Self.swashTickPath(in: rect)
                cgContext.setFillColor(PlatformColor.white.cgColor)
                cgContext.addPath(tick)
                cgContext.fillPath()
            } else {
                let insetRect = rect.insetBy(dx: 0.75, dy: 0.75)
                let strokeRadius = max(1, insetRect.width * Self.pixelCornerRatio)
                let strokePath = CGPath(roundedRect: insetRect, cornerWidth: strokeRadius, cornerHeight: strokeRadius, transform: nil)
                let strokeColor = Self.mutedMarkerColor(highContrast: highContrast)
                cgContext.setStrokeColor(strokeColor.cgColor)
                cgContext.setLineWidth(1.5)
                cgContext.addPath(strokePath)
                cgContext.strokePath()
            }

        case .bullet(let level):
            let effectiveLevel = max(1, level)
            if effectiveLevel == 1 {
                let radius = rect.width * Self.pixelCornerRatio
                let path = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
                let fill = Self.bulletAccentColor(custom: color, highContrast: highContrast)
                cgContext.setFillColor(fill.cgColor)
                cgContext.addPath(path)
                cgContext.fillPath()
            } else if effectiveLevel == 2 {
                let strokeWidth: CGFloat = max(1.25, rect.width * 0.2)
                let insetRect = rect.insetBy(dx: strokeWidth / 2, dy: strokeWidth / 2)
                let radius = max(0.75, insetRect.width * Self.pixelCornerRatio)
                let path = CGPath(roundedRect: insetRect, cornerWidth: radius, cornerHeight: radius, transform: nil)
                let strokeColor = Self.mutedMarkerColor(highContrast: highContrast)
                cgContext.setStrokeColor(strokeColor.cgColor)
                cgContext.setLineWidth(strokeWidth)
                cgContext.addPath(path)
                cgContext.strokePath()
            } else {
                let path = CGPath(ellipseIn: rect, transform: nil)
                let fill = Self.mutedMarkerColor(highContrast: highContrast)
                cgContext.setFillColor(fill.cgColor)
                cgContext.addPath(path)
                cgContext.fillPath()
            }

        case .number:
            let numFont = Self.monospacedNumberFont(for: font)
            let fg = color ?? Self.mutedMarkerColor(highContrast: highContrast)
            let attrs: [NSAttributedString.Key: Any] = [
                .font: numFont,
                .foregroundColor: fg,
            ]
            (text as NSString).draw(in: rect, withAttributes: attrs)
        }
    }

    /// Calligraphic swash-stroke checkmark inside `rect` (thin tapered entry, fuller vertex, tapered tip).
    static func swashTickPath(in rect: CGRect) -> CGPath {
        let w = rect.width
        let h = rect.height
        func pt(_ nx: CGFloat, _ ny: CGFloat) -> CGPoint {
            CGPoint(x: rect.minX + nx * w, y: rect.minY + ny * h)
        }
        let path = CGMutablePath()
        // Start at left tail, curve down to bottom vertex, sweep up to top-right tip, and return along upper edge
        path.move(to: pt(0.22, 0.53))
        path.addQuadCurve(to: pt(0.43, 0.74), control: pt(0.32, 0.65))
        path.addQuadCurve(to: pt(0.80, 0.28), control: pt(0.60, 0.52))
        path.addQuadCurve(to: pt(0.73, 0.22), control: pt(0.78, 0.23))
        path.addQuadCurve(to: pt(0.43, 0.58), control: pt(0.57, 0.41))
        path.addQuadCurve(to: pt(0.27, 0.46), control: pt(0.35, 0.51))
        path.closeSubpath()
        return path
    }
}

/// An attachment that stands in for a span of Markdown source (a table or an image).
protocol RawMarkdownAttachment: AnyObject {
    var rawMarkdown: String { get }
}

/// The markdown source an attachment stands in for, or nil for non-Swash attachments.
func swashRawMarkdown(for attachment: Any?) -> String? {
    (attachment as? RawMarkdownAttachment)?.rawMarkdown
}

/// Maps between text-storage offsets (where each table/image is a single attachment character)
/// and raw-markdown offsets (where it is its full source). All public selection ranges and all
/// edits coming from SwiftUI are expressed in raw-markdown offsets.
struct AttachmentOffsetMap {
    /// Storage location of each attachment and the UTF-16 length of the markdown it replaces, ascending.
    private(set) var spans: [(storage: Int, rawLength: Int)] = []

    static let identity = AttachmentOffsetMap()

    init() {}

    init(storage: NSAttributedString) {
        storage.enumerateAttribute(.attachment, in: NSRange(location: 0, length: storage.length), options: []) { value, range, _ in
            if let raw = swashRawMarkdown(for: value) {
                for i in 0..<range.length {
                    spans.append((storage: range.location + i, rawLength: (raw as NSString).length))
                }
            }
        }
    }

    func rawLocation(forStorage location: Int) -> Int {
        var delta = 0
        for span in spans {
            guard span.storage < location else { break }
            delta += span.rawLength - 1
        }
        return location + delta
    }

    func rawRange(forStorage range: NSRange) -> NSRange {
        let start = rawLocation(forStorage: range.location)
        let end = rawLocation(forStorage: range.location + range.length)
        return NSRange(location: start, length: end - start)
    }

    /// A raw location inside an attachment's source snaps to the attachment's start (or end when `roundUp`).
    func storageLocation(forRaw location: Int, roundUp: Bool) -> Int {
        var delta = 0
        for span in spans {
            let rawStart = span.storage + delta
            if location <= rawStart { break }
            if location < rawStart + span.rawLength {
                return roundUp ? span.storage + 1 : span.storage
            }
            delta += span.rawLength - 1
        }
        return location - delta
    }

    func storageRange(forRaw range: NSRange) -> NSRange {
        let start = storageLocation(forRaw: range.location, roundUp: false)
        let end = storageLocation(forRaw: range.location + range.length, roundUp: range.length > 0)
        return NSRange(location: start, length: max(0, end - start))
    }
}

/// Replaces every Swash attachment in `storage` with the Markdown it stands for.
func swashRawMarkdown(from storage: NSAttributedString) -> String {
    let result = NSMutableString(string: storage.string)
    storage.enumerateAttribute(.attachment, in: NSRange(location: 0, length: storage.length), options: .reverse) { value, range, _ in
        if let markdown = swashRawMarkdown(for: value) {
            result.replaceCharacters(in: range, with: markdown)
        }
    }
    return result as String
}

/// Expands `range` to whole lines if the selection covers list items or table rows.
func expandedRangeForClipboardCopy(in storage: NSAttributedString, range: NSRange) -> NSRange {
    guard range.length > 0, NSMaxRange(range) <= storage.length else { return range }
    let lineRange = (storage.string as NSString).lineRange(for: range)
    var coversListOrTable = false
    storage.enumerateAttributes(in: range, options: []) { attributes, _, stop in
        if attributes[.listMarker] != nil || attributes[.attachment] is TableTextAttachment {
            coversListOrTable = true
            stop.pointee = true
        }
    }
    if !coversListOrTable && lineRange.location < storage.length {
        storage.enumerateAttribute(.listMarker, in: lineRange, options: []) { value, _, stop in
            if value != nil {
                if NSMaxRange(range) >= NSMaxRange(lineRange) || (storage.string as NSString).substring(with: range).contains("\n") {
                    coversListOrTable = true
                    stop.pointee = true
                }
            }
        }
    }
    return coversListOrTable ? lineRange : range
}

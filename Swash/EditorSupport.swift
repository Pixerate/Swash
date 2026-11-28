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
struct ListMarkerInfo {
    enum BulletKind: Equatable {
        case disc
        case ring
        case square
    }

    let text: String
    let indent: CGFloat
    var color: PlatformColor? = nil
    
    /// Task items keep a ☐/☑ glyph (written out by rich-text copies) but are drawn as checkboxes.
    var isTask: Bool { text == "☐" || text == "☑" }
    var isChecked: Bool { text == "☑" }

    /// Bullet kind by list level (drawn as SF Symbols in the iOS editor).
    var bulletKind: BulletKind? {
        switch text {
        case "•": return .disc
        case "◦": return .ring
        case "▪": return .square
        default: return nil
        }
    }
}

/// Where a list item's text sits on its first line, in text-container coordinates.
struct ListMarkerGeometry {
    let lineRect: CGRect
    /// The item text's font (the body font for an empty item).
    let font: PlatformFont
    let baselineY: CGFloat
    /// The x where the item's text starts; markers are drawn just left of it.
    let contentX: CGFloat

    /// The visual centre of the item's text (half its cap height above the baseline).
    var midY: CGFloat { baselineY - font.capHeight / 2.0 }
}

/// How both editors draw list markers (#184): SF Symbols sized from the line's font — Reminders-style
/// circles for tasks and the system's bullets by level — just left of the item's text and centred on
/// its first line, at 3:1 contrast or better. The image and drawing calls are each platform's own.
enum ListMarkerStyle {
    /// The SF Symbol a marker is drawn with, or nil for an ordered item, whose number is drawn as text.
    static func symbolName(for marker: ListMarkerInfo) -> String? {
        if marker.isTask { return marker.isChecked ? "checkmark.circle.fill" : "circle" }
        switch marker.bulletKind {
        case .disc: return "circle.fill"
        case .ring: return "circle"
        case .square: return "square.fill"
        case nil: return nil
        }
    }

    /// A bullet's symbol point size as a share of its line's font size (drawn at the small scale, bold).
    static let bulletPointSizeRatio: CGFloat = 0.42

    /// The symbol point size for a marker: a checkbox matches the text (at the medium scale, regular
    /// weight), a bullet is small, as in the system's lists.
    static func symbolPointSize(for marker: ListMarkerInfo, fontSize: CGFloat) -> CGFloat {
        marker.isTask ? fontSize : max(4.0, fontSize * bulletPointSizeRatio)
    }

    /// The gap between a checkbox and its item's text.
    static let checkboxGap: CGFloat = 6.0

    /// A checkbox of `size` just left of the item's text, centred on its first line.
    static func checkboxRect(size: CGSize, geometry: ListMarkerGeometry) -> CGRect {
        CGRect(x: geometry.contentX - size.width - checkboxGap, y: geometry.midY - size.height / 2.0, width: size.width, height: size.height)
    }

    /// A bullet of `size` centred in the checkbox column (whose circle is `checkboxSize`).
    static func bulletRect(size: CGSize, checkboxSize: CGSize, geometry: ListMarkerGeometry) -> CGRect {
        let centerX = checkboxRect(size: checkboxSize, geometry: geometry).midX
        return CGRect(x: centerX - size.width / 2.0, y: geometry.midY - size.height / 2.0, width: size.width, height: size.height)
    }

    // MARK: Contrast

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

    /// `foreground` (sRGB) moved toward white or black just far enough to reach `minContrast` against `background`.
    static func contrastAdjusted(_ foreground: (r: CGFloat, g: CGFloat, b: CGFloat), on background: (r: CGFloat, g: CGFloat, b: CGFloat),
                                 minContrast: CGFloat = 3.0) -> (r: CGFloat, g: CGFloat, b: CGFloat) {
        let bgLum = relativeLuminance(r: background.r, g: background.g, b: background.b)
        let fgLum = relativeLuminance(r: foreground.r, g: foreground.g, b: foreground.b)
        if contrastRatio(bgLum, fgLum) >= minContrast { return foreground }

        let maxWhiteContrast = contrastRatio(bgLum, 1.0)
        let maxBlackContrast = contrastRatio(bgLum, 0.0)
        let targetIsWhite = maxWhiteContrast >= minContrast && (fgLum >= bgLum || maxBlackContrast < minContrast)
        let target: CGFloat = targetIsWhite ? 1.0 : 0.0

        var low: CGFloat = 0.0
        var high: CGFloat = 1.0
        var best = foreground
        for _ in 0..<16 {
            let mid = (low + high) / 2.0
            let candidate = (r: foreground.r + (target - foreground.r) * mid,
                             g: foreground.g + (target - foreground.g) * mid,
                             b: foreground.b + (target - foreground.b) * mid)
            if contrastRatio(bgLum, relativeLuminance(r: candidate.r, g: candidate.g, b: candidate.b)) >= minContrast {
                best = candidate
                high = mid
            } else {
                low = mid
            }
        }
        return best
    }
}

extension NSLayoutManager {
    /// Where a list marker's item text sits, in text-container coordinates, for drawing the marker and
    /// hit-testing it. `defaultFont` (the body font) stands in when the item has no visible text.
    func listMarkerGeometry(forMarkerGlyphs markerGlyphs: NSRange, indent: CGFloat, defaultFont: PlatformFont) -> ListMarkerGeometry? {
        guard let textStorage, markerGlyphs.length > 0, markerGlyphs.location < numberOfGlyphs else { return nil }
        var lineGlyphs = NSRange()
        let lineRect = lineFragmentRect(forGlyphAt: markerGlyphs.location, effectiveRange: &lineGlyphs)

        // A hidden marker is set in a 0.01 pt font (MarkdownEditorStyler.hide), so it can't stand in for the item's text
        func visibleFont(atGlyph glyph: Int) -> PlatformFont? {
            let char = characterIndexForGlyph(at: glyph)
            guard char < textStorage.length, let font = textStorage.attribute(.font, at: char, effectiveRange: nil) as? PlatformFont,
                  font.pointSize >= 1 else { return nil }
            return font
        }

        // The item's first visible glyph on this line: an empty item at the end of the document has none, and
        // its content glyph clamps to the hidden marker itself
        var anchorGlyph: Int?
        var anchorFont: PlatformFont?
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
        let textFont = anchorFont ?? defaultFont

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
            let lineHeight = textFont.ascender - textFont.descender + textFont.leading
            let band = used.height >= lineHeight * 0.5 ? used : lineRect
            baselineY = band.midY + (textFont.ascender + textFont.descender) / 2.0
        }
        return ListMarkerGeometry(lineRect: lineRect, font: textFont, baselineY: baselineY, contentX: effectiveContentX)
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

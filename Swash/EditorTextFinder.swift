//
//  EditorTextFinder.swift
//  Swash
//
//  The Mac editor's find bar (#271). NSTextView's own (`usesFindBar`) can't be told what may be
//  replaced: its NSTextFinder client is private. So `SwashNSTextView` has an `NSTextFinder` of its
//  own, with `EditorTextFinderClient` as the client, which follows the rules in EditorFind.swift:
//  - a match that takes in a hidden Markdown marker or an attachment is never replaced (Replace
//    All counts it as skipped), so Formatted's formatting isn't cut in half;
//  - a Replace or Replace All is one undo step, made through `shouldChangeText(inRanges:)` and
//    `didChangeText()`, so the coordinator restyles and the binding updates as for typing;
//  - matches inside tables and images, which the bar can't show, are counted for the hint.
//  See GOTCHAS #126.
//

#if os(macOS)
import AppKit

@MainActor
final class EditorTextFinderClient: NSObject, NSTextFinderClient {
    weak var textView: SwashNSTextView?
    /// The ranges NSTextFinder is replacing now that may be replaced, between `shouldReplace…`
    /// and `didReplaceCharacters`.
    private var replaceable: Set<NSRange> = []
    private var skipped = 0
    private var replacingCount = 0

    init(textView: SwashNSTextView) {
        self.textView = textView
    }

    /// Nonisolated, like the editor's other classes (GOTCHAS #103).
    nonisolated deinit {}

    var isEditable: Bool { textView?.isEditable ?? false }
    var allowsMultipleSelection: Bool { false }
    var string: String { textView?.string ?? "" }

    var firstSelectedRange: NSRange { textView?.selectedRange() ?? NSRange(location: 0, length: 0) }

    var selectedRanges: [NSValue] {
        get { textView?.selectedRanges ?? [] }
        set { textView?.selectedRanges = newValue }
    }

    func scrollRangeToVisible(_ range: NSRange) {
        textView?.scrollRangeToVisible(range)
    }

    func shouldReplaceCharacters(inRanges ranges: [NSValue], with strings: [String]) -> Bool {
        guard let textView, let storage = textView.textStorage else { return false }
        var allowedRanges: [NSValue] = []
        var allowedStrings: [String] = []
        for (index, value) in ranges.enumerated() where !EditorFind.crossesHiddenMarker(value.rangeValue, in: storage) {
            allowedRanges.append(value)
            allowedStrings.append(index < strings.count ? strings[index] : strings.last ?? "")
        }
        skipped = ranges.count - allowedRanges.count
        replacingCount = allowedRanges.count
        guard !allowedRanges.isEmpty else {
            textView.noteFindReplacement(skipped: skipped)
            return false
        }
        textView.isReplacingFoundText = true
        // Registers the undo step for every range at once, and asks the delegate as typing does
        guard textView.shouldChangeText(inRanges: allowedRanges, replacementStrings: allowedStrings) else {
            textView.isReplacingFoundText = false
            return false
        }
        replaceable = Set(allowedRanges.map(\.rangeValue))
        return true
    }

    func replaceCharacters(in range: NSRange, with string: String) {
        guard let textView, let storage = textView.textStorage, replaceable.contains(range) else { return }
        let attributes = range.length > 0 && range.location < storage.length
            ? storage.attributes(at: range.location, effectiveRange: nil) : textView.typingAttributes
        storage.replaceCharacters(in: range, with: NSAttributedString(string: string, attributes: attributes))
    }

    func didReplaceCharacters() {
        guard let textView else { return }
        let replaced = !replaceable.isEmpty
        replaceable = []
        if replaced {
            textView.didChangeText()
            textView.undoManager?.setActionName(replacingCount > 1 ? "Replace All" : "Replace")
        }
        textView.isReplacingFoundText = false
        textView.noteFindReplacement(skipped: skipped)
    }

    func contentView(at index: Int, effectiveCharacterRange outRange: NSRangePointer) -> NSView {
        outRange.pointee = NSRange(location: 0, length: (textView?.string as NSString?)?.length ?? 0)
        return textView ?? NSView()
    }

    func rects(forCharacterRange range: NSRange) -> [NSValue]? {
        guard let textView, let layoutManager = textView.layoutManager, let container = textView.textContainer else { return nil }
        let glyphs = layoutManager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
        let origin = textView.textContainerOrigin
        var rects: [NSValue] = []
        layoutManager.enumerateEnclosingRects(forGlyphRange: glyphs, withinSelectedGlyphRange: NSRange(location: NSNotFound, length: 0),
                                              in: container) { rect, _ in
            rects.append(NSValue(rect: rect.offsetBy(dx: origin.x, dy: origin.y)))
        }
        return rects
    }

    var visibleCharacterRanges: [NSValue] {
        guard let textView, let layoutManager = textView.layoutManager, let container = textView.textContainer else { return [] }
        let origin = textView.textContainerOrigin
        let visible = textView.visibleRect.offsetBy(dx: -origin.x, dy: -origin.y)
        let glyphs = layoutManager.glyphRange(forBoundingRect: visible, in: container)
        return [NSValue(range: layoutManager.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil))]
    }

    func drawCharacters(in range: NSRange, forContentView view: NSView) {
        guard let textView, let layoutManager = textView.layoutManager else { return }
        let glyphs = layoutManager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
        layoutManager.drawGlyphs(forGlyphRange: glyphs, at: textView.textContainerOrigin)
    }
}

/// The search the find bar last ran, from the find pasteboard NSTextFinder shares it on.
enum FindPasteboard {
    static func search() -> (query: String, options: NSString.CompareOptions, wordMatch: EditorFindWordMatch)? {
        let pasteboard = NSPasteboard(name: .find)
        guard let query = pasteboard.string(forType: .string), !query.isEmpty else { return nil }
        var options: NSString.CompareOptions = []
        var wordMatch = EditorFindWordMatch.contains
        // Keys NSFindPanelCaseInsensitiveSearch and NSFindPanelSubstringMatch (NSFindPanelSubstringMatchType)
        if let settings = pasteboard.propertyList(forType: .findPanelSearchOptions) as? [String: Any] {
            if settings["NSFindPanelCaseInsensitiveSearch"] as? Bool ?? true {
                options.insert(.caseInsensitive)
            }
            switch settings["NSFindPanelSubstringMatch"] as? Int {
            case 1: wordMatch = .startsWith
            case 2: wordMatch = .fullWord
            default: wordMatch = .contains
            }
        } else {
            options.insert(.caseInsensitive)
        }
        return (query, options, wordMatch)
    }
}
#endif

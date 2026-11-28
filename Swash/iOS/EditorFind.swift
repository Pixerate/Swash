//
//  EditorFind.swift
//  Swash
//
//  Find and replace in the iOS Source and Formatted editors (#271). The system find bar
//  (`UIFindInteraction`) drives `MarkdownEditingTextView`'s `UITextSearching` methods; the rules
//  for what matches and what may be replaced live here, so tests can check them without the bar.
//
//  Matching runs over the text view's storage. In Source that's the Markdown itself. In Formatted
//  it's the Markdown with its syntax markers hidden (a 0.01 pt font or a clear colour) and each
//  table or image collapsed into one attachment character (GOTCHAS #9), so:
//  - a match that takes in a hidden marker (searching `old**` in `**bold**`) is found but never
//    replaced, and Replace All counts it as skipped;
//  - text inside tables and images can't be shown as a match, so it's counted and offered in Source.
//  The writing partner's ghost text is drawn on an overlay, never in the storage, so it can't match.
//

#if os(iOS)
import SwiftUI
import UIKit

enum EditorFind {
    /// The ranges of `query` in `text`, in order, without overlaps.
    static func matches(of query: String, in text: NSString,
                        options: NSString.CompareOptions = [.caseInsensitive],
                        wordMatch: UITextSearchOptions.WordMatchMethod = .contains) -> [NSRange] {
        let needle = query as NSString
        guard needle.length > 0, text.length >= needle.length else { return [] }
        let options = options.subtracting([.backwards, .anchored])
        var found: [NSRange] = []
        var location = 0
        while location < text.length {
            let range = text.range(of: query, options: options, range: NSRange(location: location, length: text.length - location))
            guard range.location != NSNotFound, range.length > 0 else { break }
            if fits(range, in: text, wordMatch: wordMatch) {
                found.append(range)
                location = NSMaxRange(range)
            } else {
                // A candidate the word option rejects moves the search on by one character only
                location = range.location + 1
            }
        }
        return found
    }

    /// Whether a candidate meets the find bar's word option (Contains, Starts With, Whole Word).
    private static func fits(_ range: NSRange, in text: NSString, wordMatch: UITextSearchOptions.WordMatchMethod) -> Bool {
        func isWordCharacter(at index: Int) -> Bool {
            guard index >= 0, index < text.length else { return false }
            guard let scalar = UnicodeScalar(text.character(at: index)) else { return true }
            return CharacterSet.alphanumerics.contains(scalar) || scalar == "_"
        }
        switch wordMatch {
        case .startsWith:
            return !isWordCharacter(at: range.location - 1)
        case .fullWord:
            return !isWordCharacter(at: range.location - 1) && !isWordCharacter(at: NSMaxRange(range))
        default:
            return true
        }
    }

    /// Whether a storage character is a hidden Markdown marker (collapsed font or clear colour), as
    /// the Formatted editor's caret snapping sees it.
    static func isHiddenMarker(at index: Int, in storage: NSAttributedString) -> Bool {
        guard index >= 0, index < storage.length else { return false }
        if storage.attribute(.attachment, at: index, effectiveRange: nil) != nil { return false }
        if let font = storage.attribute(.font, at: index, effectiveRange: nil) as? UIFont, font.pointSize < 1 { return true }
        if let color = storage.attribute(.foregroundColor, at: index, effectiveRange: nil) as? UIColor, color == .clear { return true }
        return false
    }

    /// Whether replacing `range` would take in a hidden marker, or an attachment, leaving the
    /// formatting around it broken. Such matches are skipped.
    static func crossesHiddenMarker(_ range: NSRange, in storage: NSAttributedString) -> Bool {
        guard range.length > 0, NSMaxRange(range) <= storage.length else { return false }
        for index in range.location..<NSMaxRange(range) {
            if isHiddenMarker(at: index, in: storage) { return true }
            if storage.attribute(.attachment, at: index, effectiveRange: nil) != nil { return true }
        }
        return false
    }

    /// Matches inside collapsed tables and images, which the find bar can't show.
    static func attachmentMatches(of query: String, in storage: NSAttributedString,
                                  options: NSString.CompareOptions = [.caseInsensitive],
                                  wordMatch: UITextSearchOptions.WordMatchMethod = .contains) -> (tables: Int, images: Int) {
        var tables = 0
        var images = 0
        storage.enumerateAttribute(.attachment, in: NSRange(location: 0, length: storage.length)) { value, _, _ in
            guard let raw = swashRawMarkdown(for: value) else { return }
            let count = matches(of: query, in: raw as NSString, options: options, wordMatch: wordMatch).count
            if value is TableTextAttachment { tables += count } else { images += count }
        }
        return (tables, images)
    }
}

/// The find bar's searchable object for one editor: matches come from `EditorFind`, replacing goes
/// through the editor, and highlighting, ordering and scrolling are UITextView's own.
@MainActor
final class EditorTextSearcher: NSObject, UITextSearching, UIFindInteractionDelegate {
    typealias DocumentIdentifier = AnyHashable?

    private weak var textView: MarkdownEditingTextView?

    init(textView: MarkdownEditingTextView) {
        self.textView = textView
    }

    /// Nonisolated: an isolated deinit crashes on the iOS Simulator (GOTCHAS #103).
    nonisolated deinit {}

    // MARK: UIFindInteractionDelegate

    func findInteraction(_ interaction: UIFindInteraction, sessionFor view: UIView) -> UIFindSession? {
        UITextSearchingFindSession(searchableObject: self)
    }

    func findInteraction(_ interaction: UIFindInteraction, didEnd session: UIFindSession) {
        textView?.findHint = nil
    }

    // MARK: UITextSearching

    var selectedTextRange: UITextRange? { textView?.selectedTextRange }

    var supportsTextReplacement: Bool { textView?.isEditable ?? false }

    func compare(_ foundRange: UITextRange, toRange: UITextRange, document: AnyHashable??) -> ComparisonResult {
        guard let textView else { return .orderedSame }
        return textView.compare(foundRange.start, to: toRange.start)
    }

    func performTextSearch(queryString: String, options: UITextSearchOptions, resultAggregator: UITextSearchAggregator<AnyHashable?>) {
        guard let textView else { return resultAggregator.finishedSearching() }
        for range in textView.findMatches(of: queryString, options: options) {
            guard let found = textRange(range) else { continue }
            resultAggregator.foundRange(found, searchString: queryString, document: nil)
        }
        resultAggregator.finishedSearching()
        textView.noteSearch(queryString, options: options)
    }

    func decorate(foundTextRange: UITextRange, document: AnyHashable??, usingStyle style: UITextSearchFoundTextStyle) {
        textView?.decorate(foundTextRange: foundTextRange, document: nil, usingStyle: style)
    }

    func clearAllDecoratedFoundText() {
        textView?.clearAllDecoratedFoundText()
    }

    func shouldReplace(foundTextRange: UITextRange, document: AnyHashable??, withText: String) -> Bool {
        guard let textView, let range = nsRange(foundTextRange) else { return false }
        return textView.canReplaceFoundRange(range)
    }

    func replace(foundTextRange: UITextRange, document: AnyHashable??, withText replacement: String) {
        guard let textView, let range = nsRange(foundTextRange) else { return }
        textView.replaceFoundRanges([range], with: replacement, actionName: "Replace")
    }

    func replaceAll(queryString: String, options: UITextSearchOptions, withText replacement: String) {
        guard let textView else { return }
        let skipped = textView.replaceFoundRanges(textView.findMatches(of: queryString, options: options),
                                                  with: replacement, actionName: "Replace All")
        textView.noteReplaceAll(queryString, skipped: skipped)
    }

    func willHighlight(foundTextRange: UITextRange, document: AnyHashable??) {
        textView?.willHighlight(foundTextRange: foundTextRange, document: nil)
    }

    func scrollRangeToVisible(_ range: UITextRange, inDocument: AnyHashable??) {
        textView?.scrollRangeToVisible(range, inDocument: AnyHashable??.none)
    }

    // MARK: Ranges

    private func textRange(_ range: NSRange) -> UITextRange? {
        guard let textView,
              let start = textView.position(from: textView.beginningOfDocument, offset: range.location),
              let end = textView.position(from: start, offset: range.length) else { return nil }
        return textView.textRange(from: start, to: end)
    }

    private func nsRange(_ range: UITextRange) -> NSRange? {
        guard let textView else { return nil }
        let location = textView.offset(from: textView.beginningOfDocument, to: range.start)
        let length = textView.offset(from: range.start, to: range.end)
        guard location >= 0, length >= 0, location + length <= textView.textStorage.length else { return nil }
        return NSRange(location: location, length: length)
    }
}

/// What the find bar can't show: matches inside tables and images, and matches Replace All left
/// alone because they cross hidden formatting.
struct EditorFindHint: Equatable {
    var query: String
    var tables = 0
    var images = 0
    var skipped = 0

    var isEmpty: Bool { tables == 0 && images == 0 && skipped == 0 }

    var message: String {
        var parts: [String] = []
        if tables > 0 { parts.append(tables == 1 ? "1 more in a table" : "\(tables) more in tables") }
        if images > 0 { parts.append(images == 1 ? "1 more in an image" : "\(images) more in images") }
        if skipped > 0 {
            parts.append(skipped == 1 ? "1 not replaced: it crosses formatting" : "\(skipped) not replaced: they cross formatting")
        }
        return parts.joined(separator: " · ")
    }
}

/// Shown over the Formatted editor while a search has matches the find bar can't show.
struct EditorFindHintView: View {
    let hint: EditorFindHint
    var onShowInSource: () -> Void
    var onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text(hint.message)
                .font(.footnote)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            Button("Show in Source", action: onShowInSource)
                .font(.footnote.weight(.semibold))
                .accessibilityHint("Switches to Source and searches for “\(hint.query)” there")
            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.footnote.weight(.semibold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .accessibilityLabel("Dismiss")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .glassEffect(.regular, in: .capsule)
        .padding(.horizontal, 12)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("FindHint")
    }
}

#Preview("Find Hint - Tables") {
    EditorFindHintView(hint: EditorFindHint(query: "total", tables: 3), onShowInSource: {}, onDismiss: {})
}

#Preview("Find Hint - Skipped", traits: .sizeThatFitsLayout) {
    @Previewable @State var hint = EditorFindHint(query: "bold", tables: 1, images: 2, skipped: 2)
    EditorFindHintView(hint: hint, onShowInSource: { hint.skipped = 0 }, onDismiss: {})
        .padding()
}
#endif

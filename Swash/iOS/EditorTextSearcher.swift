//
//  EditorFind.swift (iOS)
//  Swash
//
//  The iOS find bar (#271): `UIFindInteraction` drives `EditorTextSearcher`, which matches and
//  replaces by the shared rules in Swash/EditorFind.swift. See GOTCHAS #126.
//

#if os(iOS)
import UIKit

extension EditorFindWordMatch {
    init(_ method: UITextSearchOptions.WordMatchMethod) {
        switch method {
        case .startsWith: self = .startsWith
        case .fullWord: self = .fullWord
        default: self = .contains
        }
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
#endif

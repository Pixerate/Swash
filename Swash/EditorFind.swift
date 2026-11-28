//
//  EditorFind.swift
//  Swash
//
//  Find and replace rules shared by the iOS and macOS editors (#271). Each platform's find bar
//  (`UIFindInteraction` with `EditorTextSearcher` on iOS, `NSTextFinder` with
//  `EditorTextFinderClient` on macOS) asks these what matches and what may be replaced, so tests
//  can check them without the bar.
//
//  Matching runs over the text view's storage. In Source that's the Markdown itself. In Formatted
//  it's the Markdown with its syntax markers hidden (a 0.01 pt font or a clear colour) and each
//  table or image collapsed into one attachment character (GOTCHAS #9), so:
//  - a match that takes in a hidden marker (searching `old**` in `**bold**`) is found but never
//    replaced, and Replace All counts it as skipped;
//  - text inside tables and images can't be shown as a match, so it's counted and offered in Source.
//  The writing partner's ghost text is drawn on an overlay, never in the storage, so it can't match.
//

import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// The find bar's word option: Contains, Starts With or Whole Word.
enum EditorFindWordMatch: Equatable {
    case contains, startsWith, fullWord
}

enum EditorFind {
    /// The ranges of `query` in `text`, in order, without overlaps.
    static func matches(of query: String, in text: NSString,
                        options: NSString.CompareOptions = [.caseInsensitive],
                        wordMatch: EditorFindWordMatch = .contains) -> [NSRange] {
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
    private static func fits(_ range: NSRange, in text: NSString, wordMatch: EditorFindWordMatch) -> Bool {
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
        if let font = storage.attribute(.font, at: index, effectiveRange: nil) as? PlatformFont, font.pointSize < 1 { return true }
        if let color = storage.attribute(.foregroundColor, at: index, effectiveRange: nil) as? PlatformColor, color == .clear { return true }
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
                                  wordMatch: EditorFindWordMatch = .contains) -> (tables: Int, images: Int, blocks: Int) {
        var tables = 0
        var images = 0
        var blocks = 0
        storage.enumerateAttribute(.attachment, in: NSRange(location: 0, length: storage.length)) { value, _, _ in
            guard let raw = swashRawMarkdown(for: value) else { return }
            let count = matches(of: query, in: raw as NSString, options: options, wordMatch: wordMatch).count
            // By its source, so this file doesn't depend on either platform's attachment classes
            let source = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if source.hasPrefix("|") {
                tables += count
            } else if source.hasPrefix("![") || source.hasPrefix("<img") {
                images += count
            } else {
                blocks += count
            }
        }
        return (tables, images, blocks)
    }
}

/// What the find bar can't show: matches inside tables and images, and matches Replace All left
/// alone because they cross hidden formatting.
struct EditorFindHint: Equatable {
    var query: String
    var tables = 0
    var images = 0
    /// Other blocks shown as attachments (widgets).
    var blocks = 0
    var skipped = 0

    var isEmpty: Bool { tables == 0 && images == 0 && blocks == 0 && skipped == 0 }

    var message: String {
        var parts: [String] = []
        if tables > 0 { parts.append(tables == 1 ? "1 more in a table" : "\(tables) more in tables") }
        if images > 0 { parts.append(images == 1 ? "1 more in an image" : "\(images) more in images") }
        if blocks > 0 { parts.append(blocks == 1 ? "1 more in a block" : "\(blocks) more in blocks") }
        if skipped > 0 {
            parts.append(skipped == 1 ? "1 not replaced: it crosses formatting" : "\(skipped) not replaced: they cross formatting")
        }
        return parts.joined(separator: " · ")
    }
}

/// Shown over the Formatted editor (iOS and macOS) while a search has matches the find bar can't show.
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
        .findHintBackground()
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

private extension View {
    /// Liquid Glass where there is one (iOS and macOS 26), a material capsule before.
    @ViewBuilder
    func findHintBackground() -> some View {
        if #available(iOS 26.0, macOS 26.0, *) {
            glassEffect(.regular, in: .capsule)
        } else {
            background(.regularMaterial, in: Capsule())
        }
    }
}

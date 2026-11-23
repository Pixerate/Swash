//
//  MarkdownFlavor.swift
//  Swash
//
//  Created by Jack James on 01/08/2026.
//

import Foundation

nonisolated enum MarkdownFlavor: String, CaseIterable, Identifiable, Sendable {
    case github = "GitHub"
    case commonMark = "CommonMark"
    case original = "Original"
    case slack = "Slack"
    
    var id: String { self.rawValue }
    
    var displayName: String {
        switch self {
        case .github: return "GitHub Markdown"
        case .commonMark: return "CommonMark"
        case .original: return "Original Markdown"
        case .slack: return "Slack mrkdwn"
        }
    }
}

// MARK: - Detection

nonisolated extension MarkdownFlavor {
    /// Guesses a document's flavour from its syntax when it is opened. Only the start of a long
    /// document is examined: the signatures show up early and opening a file stays fast.
    ///
    /// Slack mrkdwn is chosen only when its signals outweigh Markdown's. Many Slack-looking
    /// signals are also ordinary Markdown (`*text*` is CommonMark emphasis, `<https://…>` an
    /// autolink, `:name:` a GitHub emoji shortcode), so they score low, while syntax Slack never
    /// uses (`**bold**`, `__bold__`, `[text](url)`, `#` headings, tables) counts against it.
    /// Code is ignored, so `*` or `~` inside code spans and blocks don't count.
    static func detect(in fullText: String) -> MarkdownFlavor {
        let fullNS = fullText as NSString
        if fullNS.length == 0 { return .github }
        let sampleLength = 32 * 1024
        let sample = fullNS.length > sampleLength
            ? fullNS.substring(with: fullNS.rangeOfComposedCharacterSequences(for: NSRange(location: 0, length: sampleLength)))
            : fullText
        let (text, fences) = FlavorSignals.withoutCode(sample)
        func count(_ regex: NSRegularExpression) -> Int {
            regex.numberOfMatches(in: text, options: [], range: NSRange(location: 0, length: (text as NSString).length))
        }

        // Slack: <url|text> and <@user>/<#channel>/<!here> are Slack-only; the rest are weak.
        var slackScore = 0
        slackScore += count(FlavorSignals.slackPipeLink) * 4
        slackScore += count(FlavorSignals.slackMention) * 4
        slackScore += count(FlavorSignals.angleLink) * 1
        slackScore += count(FlavorSignals.singleTildeStrike) * 2
        slackScore += count(FlavorSignals.singleAsteriskBold) * 2
        slackScore += count(FlavorSignals.emojiShortcode) * 1

        // Markdown that Slack never writes, shared by GitHub, CommonMark and Original.
        var markdownScore = 0
        markdownScore += count(FlavorSignals.doubleAsteriskStrong) * 3
        markdownScore += count(FlavorSignals.doubleUnderscoreStrong) * 3
        markdownScore += count(FlavorSignals.inlineLink) * 3
        markdownScore += count(FlavorSignals.atxHeading) * 3
        markdownScore += fences.withInfoString * 2

        // GitHub extensions: ~~strikethrough~~, task lists, tables.
        var gfmScore = 0
        gfmScore += count(FlavorSignals.doubleTildeStrike) * 4
        gfmScore += count(FlavorSignals.taskListItem) * 4
        gfmScore += count(FlavorSignals.tableRow) * 2

        if slackScore > markdownScore + gfmScore {
            return .slack
        }

        // Original Markdown: 4-space indented code blocks and no fenced ones.
        let sampleRange = NSRange(location: 0, length: (sample as NSString).length)
        let hasFourSpaceIndent = FlavorSignals.fourSpaceIndent.firstMatch(in: sample, options: [], range: sampleRange) != nil
        if hasFourSpaceIndent && fences.count == 0 && 4 > gfmScore {
            return .original
        }
        return .github
    }
}

/// The syntax signatures `MarkdownFlavor.detect(in:)` scores.
private nonisolated enum FlavorSignals {
    private static func regex(_ pattern: String, _ options: NSRegularExpression.Options = []) -> NSRegularExpression {
        try! NSRegularExpression(pattern: pattern, options: options)
    }

    static let slackPipeLink = regex("<https?://[^>|\\s]+\\|[^>|\\n]+>")
    static let slackMention = regex("<(?:@|#|!(?!--))[A-Za-z0-9^][^>\\s]*>")
    static let angleLink = regex("<https?://[^>|\\s]+>")
    // Slack's delimiters need a non-space just inside them and no word character just outside.
    static let singleTildeStrike = regex("(?<![~\\w])~(?=[^\\s~])[^~\\n]*?[^\\s~]~(?![~\\w])")
    static let singleAsteriskBold = regex("(?<![*\\w])\\*(?=[^\\s*])[^*\\n]*?[^\\s*]\\*(?![*\\w])")
    static let emojiShortcode = regex("(?<![\\w:]):[a-z][a-z0-9_+\\-]*:(?![\\w:])")

    static let doubleAsteriskStrong = regex("\\*\\*(?=\\S)[^*\\n]+?\\*\\*")
    static let doubleUnderscoreStrong = regex("(?<!\\w)__(?=\\S)[^_\\n]+?__(?!\\w)")
    static let inlineLink = regex("\\[[^\\]\\n]+\\]\\([^\\)\\n]+\\)")
    static let atxHeading = regex("^ {0,3}#{1,6}[ \\t]+\\S", [.anchorsMatchLines])

    static let doubleTildeStrike = regex("~~([^~\\n]+?)~~")
    static let taskListItem = regex("^\\s*[-*]\\s+\\[[ xX]\\]\\s+", [.anchorsMatchLines])
    static let tableRow = regex("^\\|.*\\|\\s*$", [.anchorsMatchLines])

    static let fourSpaceIndent = regex("^ {4}\\S", [.anchorsMatchLines])
    static let codeSpan = regex("`[^`\\n]+`")

    /// `text` with fenced code blocks and code spans removed, plus how many fences it has and
    /// how many of those name a language (` ```swift `), which Slack's fences never do.
    static func withoutCode(_ text: String) -> (text: String, fences: (count: Int, withInfoString: Int)) {
        var kept: [Substring] = []
        var fenceCount = 0
        var withInfo = 0
        var openFence: String?
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.drop(while: { $0 == " " })
            let marker = trimmed.hasPrefix("```") ? "```" : (trimmed.hasPrefix("~~~") ? "~~~" : nil)
            if let fence = openFence {
                if let marker, marker == fence { openFence = nil }
                continue
            }
            guard let marker, line.count - trimmed.count <= 3 else {
                kept.append(line)
                continue
            }
            fenceCount += 1
            let rest = trimmed.drop(while: { String($0) == String(marker.first!) })
            if rest.contains(marker) { continue } // ```code``` on one line, as Slack writes it
            if rest.first?.isLetter == true { withInfo += 1 }
            openFence = marker
        }
        let joined = kept.joined(separator: "\n")
        let stripped = codeSpan.stringByReplacingMatches(
            in: joined, options: [], range: NSRange(location: 0, length: (joined as NSString).length), withTemplate: "")
        return (stripped, (fenceCount, withInfo))
    }
}

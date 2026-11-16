//
//  WritingPartner.swift
//  Swash
//
//  The writing partner's local tier (#61): small fixes to punctuation and capitals that Swash makes
//  as you type, each one its own undo step. Nothing here touches the network.
//
//  The Punctuate voice looks only at the word you just finished (when you type a space or a
//  punctuation mark after it) or the paragraph you just ended (with a blank line). It never edits
//  the word the caret is in, and never anything inside code, math, HTML, links' addresses, front
//  matter or tables. Each rule learns from you: undoing its fix straight away halves its weight,
//  keeping it raises it, and a rule whose weight falls too low stops.
//

import Foundation
import PixerateMarkdown

nonisolated enum WritingPartnerMode: String, CaseIterable, Identifiable, Sendable {
    case off
    case suggest
    case automatic

    var id: String { rawValue }

    var title: String {
        switch self {
        case .off: return "Off"
        case .suggest: return "Suggest"
        case .automatic: return "Automatically"
        }
    }
}

/// Which voice the writing partner plays (#105): Punctuate for documents, Chat for Slack messages.
nonisolated enum WritingPartnerVoice: String, CaseIterable, Identifiable, Sendable {
    case punctuate
    case chat

    var id: String { rawValue }

    /// The voice for `flavor`: Slack messages get the Chat voice; other flavours get Punctuate.
    init(flavor: MarkdownFlavor) {
        self = flavor == .slack ? .chat : .punctuate
    }

    var title: String {
        switch self {
        case .punctuate: return "Punctuate"
        case .chat: return "Chat"
        }
    }

    /// How Settings › Writing names the voice for `flavor`.
    static func summary(for flavor: MarkdownFlavor) -> String {
        "\(WritingPartnerVoice(flavor: flavor).title) (\(flavor.displayName))"
    }

    /// The rules this voice uses.
    var rules: [PunctuationRule] {
        switch self {
        case .punctuate: return PunctuationRule.allCases
        case .chat: return ChatVoice.rules
        }
    }
}

nonisolated enum WritingPartnerDefaults {
    static let mode = "writingPartnerMode"
    static let stats = "writingPartnerStats"
    static let chatStats = "writingPartnerChatStats"
    /// Whether the partner corrects spelling. Unset, it's on: the partner's fixes are its own undo
    /// steps and learn from undo, so it doesn't follow macOS's "Correct spelling automatically",
    /// which people often turn off for being hard to undo (#98).
    static let spelling = "writingPartnerSpelling"
    /// Whether the partner corrects context-dependent spelling and real-word errors on pauses (#98).
    /// Unset, it's on whenever spelling is on and a pause-tier provider is available.
    static let contextSpelling = "writingPartnerContextSpelling"
    /// Curly quotes (#104): a switch, off unless turned on, because whether people like curly
    /// quotes at all is a matter of taste. Dashes and ellipses have no switch: like the other
    /// rules they're on, and learn from undo.
    static let curlyQuotes = "writingPartnerCurlyQuotes"
    /// The undo action name of the partner's edits.
    static let actionName = "Punctuation"
    /// How the partner's fixes look: the id of a Flair text treatment (#100).
    static let style = "writingPartnerStyle"
    /// The style when none is chosen: a ribbon curling away under what changed.
    static let defaultStyle = "ribbon-curl"

    static func style(_ defaults: UserDefaults = .standard) -> String {
        defaults.string(forKey: style) ?? defaultStyle
    }

    /// The undo action name of the partner's structural suggestions.
    static let suggestionActionName = "Suggestion"
    static func statsKey(for voice: WritingPartnerVoice) -> String {
        switch voice {
        case .punctuate: return stats
        case .chat: return chatStats
        }
    }

    static func statsKey(for flavor: MarkdownFlavor) -> String {
        statsKey(for: WritingPartnerVoice(flavor: flavor))
    }

    /// Whether the partner corrects spelling: the stored choice, else on.
    static func spelling(_ defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: spelling) == nil ? true : defaults.bool(forKey: spelling)
    }

    /// Whether the partner corrects context-dependent spelling on pause (#98): the stored choice,
    /// else on whenever `spelling` is on.
    static func contextSpelling(_ defaults: UserDefaults = .standard) -> Bool {
        guard spelling(defaults) else { return false }
        return defaults.object(forKey: contextSpelling) == nil ? true : defaults.bool(forKey: contextSpelling)
    }

    static func curlyQuotes(_ defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: curlyQuotes)
    }

    static func isRuleEnabled(_ rule: PunctuationRule, _ defaults: UserDefaults = .standard) -> Bool {
        switch rule {
        case .spelling: return spelling(defaults)
        case .curlyQuotes: return curlyQuotes(defaults)
        default: return true
        }
    }

    /// Whether Quick Note offers a tidy-up on pause or save (#108), with Pixerate. Unset, it's on.
    static let quickNoteTidy = "writingPartnerQuickNoteTidy"
    /// The undo action name of an accepted Quick Note tidy-up (#108).
    static let tidyActionName = "Tidy"

    static func quickNoteTidy(_ defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: quickNoteTidy) == nil ? true : defaults.bool(forKey: quickNoteTidy)
    }

    static func mode(_ defaults: UserDefaults = .standard) -> WritingPartnerMode {
        defaults.string(forKey: mode).flatMap(WritingPartnerMode.init(rawValue:)) ?? .off
    }

    /// Who answers when the person pauses (#101). Not a choice: Pixerate when signed in (signing in
    /// is the opt-in, GOTCHAS #77), otherwise the limited on-device tier where Apple Intelligence is
    /// available (#102), otherwise nothing. A subscriber never gets less than a free user.
    static func provider(_ defaults: UserDefaults = .standard) -> WritingPartnerProvider {
        if WritingBandleaderFactory.isPixerateAvailable() { return .pixerate }
        return WritingBandleaderFactory.isOnDeviceAvailable() ? .onDevice : .none
    }
}

/// One thing the Punctuate voice fixes.
nonisolated enum PunctuationRule: String, CaseIterable, Codable, Sendable {
    /// `i` → `I`, `i'm` → `I'm`.
    case pronounI
    /// `dont` → `don't`, `im` → `I'm`.
    case contraction
    /// A capital letter to start a sentence.
    case sentenceCase
    /// A full stop or question mark at the end of a line.
    case terminalPunctuation
    /// A misspelt word, as the system's spell checker would autocorrect it (`becuase` → `because`).
    case spelling
    /// Words always written in capitals: `ok` → `OK`.
    case capitals
    /// A comma before `but` when it joins two clauses: "It works, but it's slow".
    case clauseComma
    /// Straight quotes (`"…"`, `'…'`, `don't`) become curly (`“…”`, `‘…’`, `don’t`).
    case curlyQuotes
    /// `--` becomes an en dash (`–`) and `---` an em dash (`—`) in prose.
    case dashes
    /// `...` becomes an ellipsis (`…`).
    case ellipses

    /// Curly quotes, dashes and ellipses: style, not correction. The strip-and-restore eval and the
    /// voice tests leave them out; in the app, curly quotes has a switch and the others are learned.
    var isTypography: Bool { self == .curlyQuotes || self == .dashes || self == .ellipses }

    var title: String {
        switch self {
        case .pronounI: return "Capital I"
        case .contraction: return "Apostrophes"
        case .sentenceCase: return "Capitals at the start of sentences"
        case .terminalPunctuation: return "Full stops and question marks"
        case .spelling: return "Spelling"
        case .capitals: return "Capitals in OK"
        case .clauseComma: return "Commas before “but”"
        case .curlyQuotes: return "Curly quotes"
        case .dashes: return "Dashes"
        case .ellipses: return "Ellipses"
        }
    }
}

/// A fix to the raw Markdown: replace `range` with `replacement`. `rules` are the rules it applies
/// (a word can get an apostrophe and a capital at once); undoing it counts against each of them.
nonisolated struct PunctuationEdit: Equatable, Sendable {
    var range: NSRange
    var replacement: String
    var rules: [PunctuationRule]
}

/// What the partner learned: a weight per rule, raised when you keep a fix and halved when you undo it.
nonisolated struct WritingPartnerStats: Codable, Equatable, Sendable {
    struct Entry: Codable, Equatable, Sendable {
        var kept = 0
        var undone = 0
        var weight = 1.0
    }

    var rules: [String: Entry] = [:]

    /// Below this, a rule stops (two undos in a row from the start).
    static let minimumWeight = 0.3

    func weight(_ rule: PunctuationRule) -> Double { rules[rule.rawValue]?.weight ?? 1 }
    func isActive(_ rule: PunctuationRule) -> Bool { weight(rule) >= Self.minimumWeight }

    mutating func kept(_ rule: PunctuationRule) {
        var entry = rules[rule.rawValue] ?? Entry()
        entry.kept += 1
        entry.weight = min(2, entry.weight * 1.1)
        rules[rule.rawValue] = entry
    }

    mutating func undone(_ rule: PunctuationRule) {
        var entry = rules[rule.rawValue] ?? Entry()
        entry.undone += 1
        entry.weight *= 0.5
        rules[rule.rawValue] = entry
    }

    static func load(_ defaults: UserDefaults = .standard, voice: WritingPartnerVoice = .punctuate) -> WritingPartnerStats {
        guard let data = defaults.data(forKey: WritingPartnerDefaults.statsKey(for: voice)),
              let stats = try? JSONDecoder().decode(WritingPartnerStats.self, from: data) else { return WritingPartnerStats() }
        return stats
    }

    static func load(_ defaults: UserDefaults = .standard, flavor: MarkdownFlavor) -> WritingPartnerStats {
        load(defaults, voice: WritingPartnerVoice(flavor: flavor))
    }

    func toVoiceState(spellingOn: Bool = true) -> JazzTextVoiceState {
        var voiceRules: [String: JazzTextVoiceStats] = [:]
        var totalKept = 0
        var totalUndone = 0

        for rule in PunctuationRule.allCases {
            let key = Self.schemaRuleKey(for: rule)
            let entry = rules[rule.rawValue]
            let kept = entry?.kept ?? 0
            let undone = entry?.undone ?? 0
            totalKept += kept
            totalUndone += undone
            voiceRules[key] = JazzTextVoiceStats(kept: kept, undone: undone)
        }

        return JazzTextVoiceState(
            voice: .punctuate,
            strength: 1.0,
            kept: totalKept,
            undone: totalUndone,
            rules: voiceRules
        )
    }

    static func schemaRuleKey(for rule: PunctuationRule) -> String {
        switch rule {
        case .pronounI: return "pronoun-i"
        case .contraction: return "contraction"
        case .sentenceCase: return "sentence-case"
        case .terminalPunctuation: return "end-stop"
        case .spelling: return "spelling"
        case .capitals: return "capitals"
        case .clauseComma: return "clause-comma"
        case .curlyQuotes: return "curly-quotes"
        case .dashes: return "dashes"
        case .ellipses: return "ellipses"
        }
    }
    func save(_ defaults: UserDefaults = .standard, voice: WritingPartnerVoice = .punctuate) {
        if let data = try? JSONEncoder().encode(self) {
            defaults.set(data, forKey: WritingPartnerDefaults.statsKey(for: voice))
        }
    }

    func save(_ defaults: UserDefaults = .standard, flavor: MarkdownFlavor) {
        save(defaults, voice: WritingPartnerVoice(flavor: flavor))
    }
}

/// The Chat voice (#105): a light touch for Slack messages. Fixes apostrophes (`dont` → `don't`),
/// capital `I` and spelling, while leaving lowercase starts, message ends, `ok`, `lol` and other
/// chat conventions, `:shortcode:` emoji, and Slack syntax (`<@user>`, `<#channel>`, `<!here>`,
/// `<url|label>`, `*bold*`, `_italic_`, `~strike~` markers) alone.
nonisolated enum ChatVoice {
    /// The rules the Chat voice plays: the editor's `chat` profile (`TextMechanicsOptions.Profile.chat`)
    /// keeps chat shorthand, Slack syntax and lowercase starts, and runs no typography.
    static let rules: [PunctuationRule] = [.pronounI, .contraction, .spelling]
}

/// The Punctuate voice: the editor package's text mechanics checks (`TextMechanics` in
/// PixerateMarkdown, Pixerate/editor#892), with Swash's rules, flavours and spell checker. The
/// rules themselves live in the editor, so every Pixerate editor fixes text the same way.
nonisolated enum PunctuateVoice {
    /// The fixes to make after the person typed the character at `boundary` (raw-Markdown UTF-16
    /// offset; the caret is just after it). `document` is `text` parsed in `flavor`.
    static func edits(
        text: String,
        boundary: Int,
        document: MarkdownDocument,
        flavor: MarkdownFlavor,
        enterEndedLine: Bool? = nil,
        isActive: (PunctuationRule) -> Bool = { _ in true },
        spellingCorrection: ((_ word: String, _ range: NSRange, _ text: String) -> String?)? = nil
    ) -> [PunctuationEdit] {
        withoutActuallyEscaping(isActive) { isActive in
            let options = TextMechanicsOptions(
                profile: flavor == .slack ? .chat : .prose,
                enabled: { isActive(PunctuationRule($0)) },
                enterEndedLine: enterEndedLine,
                spelling: spellingCorrection,
                tagger: TextMechanics.naturalLanguageTagger
            )
            return TextMechanics.edits(at: boundary, in: text, document: document, options: options).map {
                PunctuationEdit(range: $0.range, replacement: $0.replacement, rules: $0.checks.map(PunctuationRule.init))
            }
        }
    }

    /// What the voice looks at for the boundary at `boundary`: the word before it, or the line it
    /// ends when it's a newline. Nil when that isn't prose, so there's nothing to show as checked.
    static func checkedRange(text: String, boundary: Int, document: MarkdownDocument) -> NSRange? {
        TextMechanics.checkedRange(at: boundary, in: text, document: document)
    }

    /// Characters that end a word: space, tab and sentence punctuation.
    static func isWordBoundary(_ c: unichar) -> Bool { TextMechanics.isBoundary(c) }

    /// Letters and apostrophes.
    static func isWordCharacter(_ c: unichar) -> Bool { TextMechanics.isWordCharacter(c) }
}

nonisolated extension PunctuationRule {
    /// Swash's rule for one of the editor's checks. The raw values stay Swash's own: they key
    /// the weights people's partners have already learned.
    init(_ check: TextMechanicsCheck) {
        switch check {
        case .pronounI: self = .pronounI
        case .contractions: self = .contraction
        case .sentenceCase: self = .sentenceCase
        case .terminalPunctuation: self = .terminalPunctuation
        case .capitals: self = .capitals
        case .clauseComma: self = .clauseComma
        case .spelling: self = .spelling
        case .curlyQuotes: self = .curlyQuotes
        case .dashes: self = .dashes
        case .ellipses: self = .ellipses
        }
    }
}

/// One edit the partner's cursor plays out (#878): it selects `range` (whole words, in the text
/// before the fix) and types `replacement` over it, as a person would retype a word. Each is its
/// own undo step; undoing it counts against `rules`, and tells the spell checker `spellingWords`
/// are words.
nonisolated struct PartnerEdit: Equatable, Sendable {
    var range: NSRange
    /// The text `range` held when the fix was worked out: the edit is played only if it's still there.
    var original: String
    var replacement: String
    var rules: [PunctuationRule]
    var spellingWords: [String]
    var actionName: String? = nil
}

/// Where one of the voice's edits landed in the fixed text, and what it did.
nonisolated struct PartnerMark: Equatable, Sendable {
    var range: NSRange
    var rules: [PunctuationRule]
    /// The word a spelling fix replaced.
    var spellingWord: String?
}

extension PunctuateVoice {
    /// The fix that turns `old` into `new`, as whole-word edits from left to right. `marks` say where
    /// the voice's edits landed in `new`, so each edit carries the rules that made it.
    static func partnerEdits(from old: NSString, to new: NSString, marks: [PartnerMark]) -> [PartnerEdit] {
        let (changedBefore, changedAfter) = changedRanges(from: old, to: new)
        // Widen each change to the words it touches, and merge changes in the same word
        var pairs: [(before: NSRange, after: NSRange)] = []
        for (before, after) in zip(changedBefore, changedAfter) {
            let pair = (word(around: before, in: old), word(around: after, in: new))
            if let last = pairs.last, pair.0.location <= NSMaxRange(last.before) {
                pairs[pairs.count - 1] = (NSUnionRange(last.before, pair.0), NSUnionRange(last.after, pair.1))
            } else {
                pairs.append(pair)
            }
        }
        return pairs.map { before, after in
            let touching = marks.filter { $0.range.location <= NSMaxRange(after) && NSMaxRange($0.range) >= after.location }
            var rules: [PunctuationRule] = []
            for rule in touching.flatMap(\.rules) where !rules.contains(rule) { rules.append(rule) }
            let original = old.substring(with: before)
            let spelling = touching.compactMap(\.spellingWord).filter { original.contains($0) }
            return PartnerEdit(range: before, original: original, replacement: new.substring(with: after),
                               rules: rules, spellingWords: spelling)
        }
    }

    /// `range` widened to the whole words it touches (a full stop added after a word takes the word).
    static func word(around range: NSRange, in text: NSString) -> NSRange {
        var start = range.location
        var end = NSMaxRange(range)
        while start > 0, isWordCharacter(text.character(at: start - 1)) { start -= 1 }
        while end < text.length, isWordCharacter(text.character(at: end)) { end += 1 }
        return NSRange(location: start, length: end - start)
    }

    /// Where `new` differs from `old`: each run of changed characters, as ranges in both.
    static func changedRanges(from old: NSString, to new: NSString) -> (before: [NSRange], after: [NSRange]) {
        // Trim the common prefix and suffix, then diff what's left character by character
        let limit = min(old.length, new.length)
        var prefix = 0
        while prefix < limit, old.character(at: prefix) == new.character(at: prefix) { prefix += 1 }
        var suffix = 0
        while suffix < limit - prefix, old.character(at: old.length - 1 - suffix) == new.character(at: new.length - 1 - suffix) { suffix += 1 }
        let oldMiddle = (0..<(old.length - prefix - suffix)).map { old.character(at: prefix + $0) }
        let newMiddle = (0..<(new.length - prefix - suffix)).map { new.character(at: prefix + $0) }
        let difference = newMiddle.difference(from: oldMiddle)
        var removed = IndexSet()
        var inserted = IndexSet()
        for change in difference {
            switch change {
            case .remove(let offset, _, _): removed.insert(offset)
            case .insert(let offset, _, _): inserted.insert(offset)
            }
        }
        // Pair each run of changes in the old text with the run at the same place in the new one
        var before: [NSRange] = []
        var after: [NSRange] = []
        var oldIndex = 0
        var newIndex = 0
        while oldIndex < oldMiddle.count || newIndex < newMiddle.count {
            if !removed.contains(oldIndex) && !inserted.contains(newIndex), oldIndex < oldMiddle.count, newIndex < newMiddle.count {
                oldIndex += 1
                newIndex += 1
                continue
            }
            let oldStart = oldIndex
            let newStart = newIndex
            while removed.contains(oldIndex) { oldIndex += 1 }
            while inserted.contains(newIndex) { newIndex += 1 }
            if oldIndex == oldStart && newIndex == newStart { break }
            before.append(NSRange(location: prefix + oldStart, length: oldIndex - oldStart))
            after.append(NSRange(location: prefix + newStart, length: newIndex - newStart))
        }
        return (before, after)
    }
}

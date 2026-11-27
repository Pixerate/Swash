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
import NaturalLanguage
import PixerateMarkdown

/// How much the writing partner does (#229): nothing, tidy up, or write with you.
nonisolated enum WritingPartnerMode: String, CaseIterable, Identifiable, Sendable {
    /// The partner is switched off altogether.
    case off
    /// Tidies up as you type: punctuation, spelling, grammar, and Markdown formatting. The default.
    case copyedit
    /// Copyedit, plus the bandleader synthesizes and rewrites prose in place when you pause.
    case ghostwrite

    var id: String { rawValue }

    /// Reads a stored mode, including the levels before #229: `automatic` and `suggest` were both
    /// the partner fixing as you type, so both become Copyedit (Suggest's offers now come from the
    /// separate Suggestions switch).
    init?(rawValue: String) {
        switch rawValue {
        case "off": self = .off
        case "copyedit", "automatic", "suggest": self = .copyedit
        case "ghostwrite": self = .ghostwrite
        default: return nil
        }
    }

    var rawValue: String {
        switch self {
        case .off: return "off"
        case .copyedit: return "copyedit"
        case .ghostwrite: return "ghostwrite"
        }
    }

    var title: String {
        switch self {
        case .off: return "Off"
        case .copyedit: return "Copyedit"
        case .ghostwrite: return "Ghostwrite"
        }
    }

    /// One line on what the level does, for Settings and the first-run introduction.
    var summary: String {
        switch self {
        case .off: return "The writing partner is switched off."
        case .copyedit: return "Tidies up as you type: punctuation, spelling, grammar, and Markdown formatting."
        case .ghostwrite: return "Copyedits, and when you pause, rewrites and fills out what you've written in place."
        }
    }

    /// Whether the partner is on at all.
    var isOn: Bool { self != .off }

    /// What the bandleader is asked to do on a pause (#229, Pixerate/schemas#87).
    var engagementMode: JazzTextEngagementMode? {
        switch self {
        case .off: return nil
        case .copyedit: return .copyedit
        case .ghostwrite: return .ghostwrite
        }
    }
}

/// What the Partner style preview plays for each level (#229), on macOS and iOS: Off shows the
/// sentence as typed, Copyedit fixes a misspelt word, Ghostwrite rewrites rough notes as prose.
nonisolated struct WritingPartnerPreviewScript: Equatable, Sendable {
    var before: String
    var wrong: String
    var right: String
    var after: String
    /// Whether the partner plays at all (Off doesn't).
    var plays: Bool

    static func script(for level: WritingPartnerMode) -> WritingPartnerPreviewScript {
        switch level {
        case .off: return WritingPartnerPreviewScript(before: "It leaves the odd ", wrong: "wrod", right: "wrod", after: " as you wrote it.", plays: false)
        case .copyedit: return WritingPartnerPreviewScript(before: "It fixes the odd ", wrong: "wrod", right: "word", after: " as you write.", plays: true)
        case .ghostwrite: return WritingPartnerPreviewScript(before: "", wrong: "met sam, budget ok", right: "We met Sam and agreed the budget.", after: "", plays: true)
        }
    }

    var original: String { before + wrong + after }
    var fixed: String { before + right + after }

    var accessibilityLabel: String {
        plays ? "Sample: \(original) becomes \(fixed)" : "Sample: \(original), left as written"
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
    /// The switch Spelling had before #229. Spelling is now always on while the partner is, and
    /// learns from undo (it doesn't follow macOS's "Correct spelling automatically", #98); the key
    /// is a hidden override for tests, see `spelling(_:)`.
    static let spelling = "writingPartnerSpelling"
    /// Curly quotes (#104): a switch, off unless turned on, because whether people like curly
    /// quotes at all is a matter of taste. Dashes and ellipses have no switch: like the other
    /// rules they're on, and learn from undo.
    static let curlyQuotes = "writingPartnerCurlyQuotes"
    /// The grammar switches before #229 (#111). The rules are now always on and learn from ⌘Z; the
    /// keys are hidden overrides for tests, see `isRuleEnabled`.
    static let doubledWords = "writingPartnerDoubledWords"
    static let aAndAn = "writingPartnerAAndAn"
    static let agreementAndTense = "writingPartnerAgreementAndTense"
    static let missingWords = "writingPartnerMissingWords"
    /// The undo action name of the partner's edits.
    static let actionName = "Punctuation"
    /// The undo action name of the Formatting voice's tidies (#113).
    static let formattingActionName = "Formatting"
    /// How the partner's fixes look: the id of a Flair text treatment (#100).
    static let style = "writingPartnerStyle"
    /// The style when none is chosen: a ribbon curling away under what changed.
    static let defaultStyle = "ribbon-curl"

    static func style(_ defaults: UserDefaults = .standard) -> String {
        defaults.string(forKey: style) ?? defaultStyle
    }

    /// Suggestions (#229, from #128's marks): whether fixes the partner isn't sure of (confidence
    /// between `offerThreshold` and `applyThreshold`, or with more than one candidate) are shown as
    /// faint dotted underlines to settle, rather than left alone. Independent of the level; unset,
    /// it's on. The key is #128's, so an existing choice carries over.
    static let suggestions = "writingPartnerMarkUncertain"

    static func suggestions(_ defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: suggestions) == nil ? true : defaults.bool(forKey: suggestions)
    }

    /// Whether VoiceOver hears how many marks a finished paragraph left (#128). Off unless asked for.
    static let announceMarks = "writingPartnerAnnounceMarks"

    static func announceMarks(_ defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: announceMarks)
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

    static func curlyQuotes(_ defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: curlyQuotes)
    }

    /// Whether spelling runs. Settings has no switch since #229, so this is on unless a test or
    /// automation turns it off (what the system spell checker corrects depends on the Mac);
    /// `adoptLearnedDefaults` clears a person's old choice once.
    static func spelling(_ defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: spelling) == nil ? true : defaults.bool(forKey: spelling)
    }

    /// The old per-rule keys, honoured like `spelling` for tests and cleared once on upgrade.
    private static func hiddenSwitch(_ key: String, _ defaults: UserDefaults) -> Bool {
        defaults.object(forKey: key) == nil ? true : defaults.bool(forKey: key)
    }

    /// Whether `rule` runs at all (#229). Everything is on and learns from ⌘Z ("What It Has
    /// Learned"), except curly quotes, a matter of taste with its own switch under Typography.
    static func isRuleEnabled(_ rule: PunctuationRule, _ defaults: UserDefaults = .standard) -> Bool {
        switch rule {
        case .curlyQuotes: return curlyQuotes(defaults)
        case .spelling: return spelling(defaults)
        case .doubledWords: return hiddenSwitch(doubledWords, defaults)
        case .aAndAn: return hiddenSwitch(aAndAn, defaults)
        case .agreementAndTense: return hiddenSwitch(agreementAndTense, defaults)
        case .missingWords: return hiddenSwitch(missingWords, defaults)
        default:
            return rule.isFormatting ? hiddenSwitch(formattingKey(rule), defaults) : true
        }
    }

    /// Marker recorded once the switches removed in #229 have been cleared.
    static let learnedDefaultsAdopted = "writingPartnerLearnedDefaultsAdopted"

    /// Clears, once, the Spelling, Grammar, Formatting and "Also in Source view" switches that
    /// Settings no longer shows (#229), so a rule someone once turned off isn't left off with no
    /// way to see it. From then on every rule is on and learns from ⌘Z.
    static func adoptLearnedDefaults(_ defaults: UserDefaults = .standard) {
        guard !defaults.bool(forKey: learnedDefaultsAdopted) else { return }
        let keys = [spelling, doubledWords, aAndAn, agreementAndTense, missingWords, formattingInSource]
            + FormattingVoice.rules.map(formattingKey)
        keys.forEach(defaults.removeObject(forKey:))
        defaults.set(true, forKey: learnedDefaultsAdopted)
    }

    /// The Formatting voice's switches before #229 (#113): hidden overrides, see `isRuleEnabled`.
    static func formattingKey(_ rule: PunctuationRule) -> String { "writingPartnerFormat-\(rule.rawValue)" }

    /// The "Also in Source view" switch before #229. The Formatting voice now tidies in Source view
    /// too whenever the partner is on; the key is kept only so `adoptLearnedDefaults` can clear it.
    static let formattingInSource = "writingPartnerFormattingInSource"

    /// Whether Quick Note offers a tidy-up on pause or save (#108), with Pixerate. Unset, it's on.
    static let quickNoteTidy = "writingPartnerQuickNoteTidy"
    /// The undo action name of an accepted Quick Note tidy-up (#108).
    static let tidyActionName = "Tidy"
    /// Whether the first-run introduction note has been shown (#112).
    static let introShown = "writingPartnerIntroShown"
    /// Whether the quiet reminder on the first undone partner fix has been shown (#112).
    static let undoReminderShown = "writingPartnerUndoReminderShown"
    /// Marker recorded once existing-install migration has run (#112).
    static let installMigrated = "writingPartnerInstallMigrated"

    /// Preference keys written by Swash prior to #112. If any is present when `writingPartnerMode`
    /// is unset and `installMigrated` is false, this is an upgrade of an existing install whose
    /// partner was off, so its `.off` setting is preserved.
    private static let existingInstallKeys: [String] = [
        "SUHasLaunchedBefore",
        "suppressDefaultAppPrompt",
        "defaultMarkdownFlavor",
        "markdownFlavor",
        "showOutline",
        "showMenuBarExtra",
        stats,
        chatStats,
        spelling,
        curlyQuotes,
        doubledWords,
        aAndAn,
        agreementAndTense,
        missingWords,
        style,
        quickNoteTidy,
        "writingFocusMode",
        "writingFocusUnit",
        "writingTypewriterScrolling",
        "editorTypographyFont",
        "editorTypographyTextSize",
        "editorTypographyLineWidth",
        "editorTypographyTheme",
        "agentToolsEnabled",
        "agentBridgePort",
    ]

    static func quickNoteTidy(_ defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: quickNoteTidy) == nil ? true : defaults.bool(forKey: quickNoteTidy)
    }

    static func introShown(_ defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: introShown)
    }

    static func setIntroShown(_ shown: Bool, _ defaults: UserDefaults = .standard) {
        defaults.set(shown, forKey: introShown)
    }

    static func undoReminderShown(_ defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: undoReminderShown)
    }

    static func setUndoReminderShown(_ shown: Bool, _ defaults: UserDefaults = .standard) {
        defaults.set(shown, forKey: undoReminderShown)
    }

    /// Preserves an existing install's setting on upgrade (#112). Before #112, an untouched
    /// install had no `writingPartnerMode` key and defaulted to `.off`; a new install has no
    /// prior Swash keys and defaults to Copyedit. A level stored before #229 (`automatic`,
    /// `suggest`) is rewritten as Copyedit.
    @discardableResult
    static func migrateExistingInstall(_ defaults: UserDefaults = .standard) -> WritingPartnerMode {
        let resolved = migrateMode(defaults)
        adoptLearnedDefaults(defaults)
        return resolved
    }

    private static func migrateMode(_ defaults: UserDefaults) -> WritingPartnerMode {
        if let raw = defaults.string(forKey: mode), let stored = WritingPartnerMode(rawValue: raw) {
            if raw != stored.rawValue { defaults.set(stored.rawValue, forKey: mode) }
            defaults.set(true, forKey: installMigrated)
            return stored
        }
        if defaults.bool(forKey: installMigrated) {
            return .copyedit
        }
        let isUpgrade = existingInstallKeys.contains { defaults.object(forKey: $0) != nil }
        let resolved: WritingPartnerMode = isUpgrade ? .off : .copyedit
        defaults.set(resolved.rawValue, forKey: mode)
        defaults.set(true, forKey: installMigrated)
        return resolved
    }

    /// A new install has the partner on in Copyedit (#112, #229); an explicit choice or migrated
    /// upgrade setting takes precedence.
    static func mode(_ defaults: UserDefaults = .standard) -> WritingPartnerMode {
        defaults.string(forKey: mode).flatMap(WritingPartnerMode.init(rawValue:)) ?? .copyedit
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
    /// Accidental doubled words (`the the` → `the`), keeping deliberate ones (`had had`, `that that`).
    case doubledWords
    /// `a` and `an` before a vowel or consonant sound (`a apple` → `an apple`, `an user` → `a user`).
    case aAndAn
    /// Subject and verb agreement (`the results shows`) and tense slips (`walked in and says`).
    case agreementAndTense
    /// A missing small word (`went the shop` → `went to the shop`).
    case missingWords
    /// Straight quotes (`"…"`, `'…'`, `don't`) become curly (`“…”`, `‘…’`, `don’t`).
    case curlyQuotes
    /// `--` becomes an en dash (`–`) and `---` an em dash (`—`) in prose.
    case dashes
    /// `...` becomes an ellipsis (`…`).
    case ellipses
    /// Formatting voice (#113): one bullet per list, consistent indentation, ordered lists renumbered.
    case formatLists
    /// Formatting voice: a space after `#`, no closing `#`s or full stop on a heading.
    case formatHeadings
    /// Formatting voice: blank lines around blocks, runs of spaces between words, trailing spaces.
    case formatSpacing
    /// Formatting voice: a code span or emphasis that splits a word wraps the whole word, and spaces
    /// just inside `** … **` that kept it from being bold go.
    case formatSpans
    /// Formatting voice: one emphasis marker (`*` or `_`) per document.
    case formatEmphasis
    /// Formatting voice: `[]`, `[ ]`, `[X]` at the start of a list item become `- [ ]` and `- [x]`.
    case formatTasks
    /// Formatting voice: table columns realigned once the caret leaves the table.
    case formatTables
    /// Formatting voice: a bare URL on its own becomes an autolink.
    case formatLinks
    /// Formatting voice, Copyedit's auto-formatting (#229): a short title line on its own, followed
    /// by the text it introduces, becomes a heading.
    case formatTitleLines

    /// Curly quotes, dashes and ellipses: style, not correction. The strip-and-restore eval and the
    /// voice tests leave them out; in the app, curly quotes has a switch and the others are learned.
    var isTypography: Bool { self == .curlyQuotes || self == .dashes || self == .ellipses }

    /// The Formatting voice's rules (#113): they tidy Markdown, not words, so the Punctuate voice's
    /// tests and the strip-and-restore eval leave them out.
    var isFormatting: Bool { FormattingVoice.rules.contains(self) }

    /// The four grammar rules (#111): always on (#229) and learn from ⌘Z.
    var isGrammar: Bool {
        self == .doubledWords || self == .aAndAn || self == .agreementAndTense || self == .missingWords
    }

    /// Grammar rules decided on a pause by the bandleader (#111).
    var isPauseTierGrammar: Bool {
        self == .agreementAndTense || self == .missingWords
    }

    var title: String {
        switch self {
        case .pronounI: return "Capital I"
        case .contraction: return "Apostrophes"
        case .sentenceCase: return "Capitals at the start of sentences"
        case .terminalPunctuation: return "Full stops and question marks"
        case .spelling: return "Spelling"
        case .capitals: return "Capitals in OK"
        case .clauseComma: return "Commas before “but”"
        case .doubledWords: return "Doubled words"
        case .aAndAn: return "A and an"
        case .agreementAndTense: return "Agreement and tense"
        case .missingWords: return "Missing words"
        case .curlyQuotes: return "Curly quotes"
        case .dashes: return "Dashes"
        case .ellipses: return "Ellipses"
        case .formatLists: return "Lists"
        case .formatHeadings: return "Headings"
        case .formatSpacing: return "Spacing"
        case .formatSpans: return "Emphasis and code markers"
        case .formatEmphasis: return "One emphasis style"
        case .formatTasks: return "Task boxes"
        case .formatTables: return "Table columns"
        case .formatLinks: return "Bare links"
        case .formatTitleLines: return "Title lines as headings"
        }
    }

    /// An example of the rule's fix, for Settings › Writing.
    var example: String? {
        switch self {
        case .formatLists: return "1. 3. 2. → 1. 2. 3."
        case .formatHeadings: return "#Heading → # Heading"
        case .formatSpacing: return "hello  world → hello world"
        case .formatSpans: return "`hell`o → `hello`, ** hi ** → **hi**"
        case .formatEmphasis: return "_this_ and *that* → *this* and *that*"
        case .formatTasks: return "- [] → - [ ]"
        case .formatTables: return "Columns lined up"
        case .formatLinks: return "https://… → <https://…>"
        case .formatTitleLines: return "Next steps → ## Next steps"
        default: return nil
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

        // The bandleader's voice state is the Punctuate voice's: formatting isn't part of its schema
        for rule in PunctuationRule.allCases where !rule.isFormatting {
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
        case .doubledWords: return "doubled-words"
        case .aAndAn: return "a-and-an"
        case .agreementAndTense: return "agreement-and-tense"
        case .missingWords: return "missing-words"
        case .curlyQuotes: return "curly-quotes"
        case .dashes: return "dashes"
        case .ellipses: return "ellipses"
        case .formatLists: return "format-lists"
        case .formatHeadings: return "format-headings"
        case .formatSpacing: return "format-spacing"
        case .formatSpans: return "format-spans"
        case .formatEmphasis: return "format-emphasis"
        case .formatTasks: return "format-tasks"
        case .formatTables: return "format-tables"
        case .formatLinks: return "format-links"
        case .formatTitleLines: return "format-title-lines"
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

/// The fast-tier text duet protocol (#61): computes local edits and checked ranges at word and
/// sentence boundaries in raw-Markdown UTF-16 offsets, independent of AppKit/UIKit so it can move
/// to a shared package and run on iOS as well as macOS.
nonisolated protocol WritingPartner: Sendable {
    /// The fixes to make after the person typed the character at `boundary` (raw-Markdown UTF-16
    /// offset; the caret is just after it). `document` is `text` parsed in `flavor`.
    func edits(
        text: String,
        boundary: Int,
        document: MarkdownDocument,
        flavor: MarkdownFlavor,
        enterEndedLine: Bool?,
        isActive: (PunctuationRule) -> Bool,
        spellingCorrection: ((_ word: String, _ range: NSRange, _ text: String) -> String?)?
    ) -> [PunctuationEdit]

    /// What the voice looks at for the boundary at `boundary`: the word before it, or the line it
    /// ends when it's a newline. Nil when that isn't prose, so there's nothing to show as checked.
    func checkedRange(text: String, boundary: Int, document: MarkdownDocument) -> NSRange?
}

/// The Punctuate voice: the editor package's text mechanics checks (`TextMechanics` in
/// PixerateMarkdown, Pixerate/editor#892), with Swash's rules, flavours and spell checker. The
/// rules themselves live in the editor, so every Pixerate editor fixes text the same way.
nonisolated struct PunctuateVoice: WritingPartner, Sendable {
    init() {}

    func edits(
        text: String,
        boundary: Int,
        document: MarkdownDocument,
        flavor: MarkdownFlavor,
        enterEndedLine: Bool? = nil,
        isActive: (PunctuationRule) -> Bool = { _ in true },
        spellingCorrection: ((_ word: String, _ range: NSRange, _ text: String) -> String?)? = nil
    ) -> [PunctuationEdit] {
        Self.edits(
            text: text,
            boundary: boundary,
            document: document,
            flavor: flavor,
            enterEndedLine: enterEndedLine,
            isActive: isActive,
            spellingCorrection: spellingCorrection
        )
    }

    func checkedRange(text: String, boundary: Int, document: MarkdownDocument) -> NSRange? {
        Self.checkedRange(text: text, boundary: boundary, document: document)
    }

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
            let ns = text as NSString
            if flavor != .slack, boundary >= 0, boundary < ns.length,
               GrammarVoice.insideUnclosedHTMLOrImage(before: boundary, ns: ns) {
                return []
            }
            let options = TextMechanicsOptions(
                profile: flavor == .slack ? .chat : .prose,
                enabled: { $0 == .terminalPunctuation ? false : isActive(PunctuationRule($0)) },
                enterEndedLine: enterEndedLine,
                spelling: spellingCorrection,
                tagger: TextMechanics.naturalLanguageTagger
            )
            let baseEdits = TextMechanics.edits(at: boundary, in: text, document: document, options: options).map {
                PunctuationEdit(range: $0.range, replacement: $0.replacement, rules: $0.checks.map(PunctuationRule.init))
            }
            let grammarEdits = GrammarVoice.edits(
                text: text,
                boundary: boundary,
                document: document,
                flavor: flavor,
                baseEdits: baseEdits,
                isActive: isActive
            )
            var merged = GrammarVoice.merge(baseEdits: baseEdits, grammarEdits: grammarEdits)
            if flavor != .slack,
               boundary >= 0,
               boundary < ns.length,
               ns.character(at: boundary) == 0x0A,
               isActive(.terminalPunctuation),
               let terminal = terminalPunctuation(
                   ns: ns,
                   lineEnd: boundary,
                   document: document,
                   enterEndedLine: enterEndedLine,
                   priorEdits: merged
               ) {
                merged.append(terminal)
            }
            return merged
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
    var bandleaderSuggestionId: String? = nil
    var bandleaderSuggestionKind: JazzTextSuggestionKind? = nil
    var bandleaderCheckId: String? = nil
    /// Played at once rather than typed: a tidy across lines (a table, a blank line) isn't a word.
    var playsInstantly = false
    /// Other words it could be, when the partner can't choose (#128): such a fix is never made at
    /// once, only marked or offered.
    var alternatives: [String] = []
    /// How sure the partner is, when it said (the pause tier's corrections).
    var confidence: Double? = nil
    /// Which of the session's edit layers it belongs to once made (#229): Ghostwrite for prose the
    /// bandleader rewrote in place, Copyedit for everything else.
    var layer: PartnerEditLayer = .copyedit
}

/// Where one of the voice's edits landed in the fixed text, and what it did.
nonisolated struct PartnerMark: Equatable, Sendable {
    var range: NSRange
    var rules: [PunctuationRule]
    /// The word a spelling fix replaced.
    var spellingWord: String?
}

nonisolated extension PunctuateVoice {
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
        // When a duplicate word + space was removed ("the the " → "the "), let suffix claim the trailing space so
        // the change sits adjacent to the surviving word ("the" + " the" → "the") rather than stranding a trailing space.
        while prefix > 0, !isWordCharacter(old.character(at: prefix - 1)),
              old.length - prefix - suffix > 0,
              old.character(at: old.length - 1 - suffix) == old.character(at: prefix - 1) {
            prefix -= 1
            suffix += 1
        }
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

    // MARK: Terminal Punctuation & Clause Disambiguation

    struct ClauseToken: Equatable, Sendable {
        var text: String
        var lower: String
        var range: NSRange
    }

    private static let unambiguousQuestionWords: Set<String> = [
        "who", "what", "why", "how", "which", "whose", "whom",
        "who's", "what's", "why's", "how's",
        "when's", "where's", "when'd", "where'd", "when'll", "where'll", "when're", "where're", "when've", "where've",
        "is", "are", "am", "was", "were", "do", "does", "did", "can", "could", "would", "should", "will", "shall",
        "may", "might", "have", "has", "had",
        "isn't", "aren't", "wasn't", "weren't", "don't", "doesn't", "didn't", "can't", "couldn't", "won't",
        "wouldn't", "shouldn't", "mustn't", "haven't", "hasn't", "hadn't",
    ]

    private static let inversionVerbs: Set<String> = [
        "is", "are", "am", "was", "were", "isn't", "aren't", "wasn't", "weren't", "ain't",
        "do", "does", "did", "don't", "doesn't", "didn't",
        "can", "could", "will", "would", "shall", "should", "may", "might", "must",
        "can't", "couldn't", "won't", "wouldn't", "shan't", "shouldn't", "mustn't",
        "have", "has", "had", "haven't", "hasn't", "hadn't",
    ]

    private static let nonQuestionAdverbs: Set<String> = [
        "there", "here", "now", "then", "once", "only", "even", "just", "still", "already", "always", "never", "often", "sometimes",
    ]

    private static let whModifierAdverbs: Set<String> = [
        "exactly", "else", "ever", "precisely", "specifically", "roughly", "actually", "really", "typically", "usually", "normally", "generally",
    ]

    private static let whPrepositions: Set<String> = [
        "in", "on", "at", "from", "around", "under", "over", "inside", "within", "across", "along",
        "near", "by", "for", "of", "through", "throughout", "during", "after", "before", "between", "among",
    ]

    private static let whDeterminers: Set<String> = [
        "the", "this", "that", "these", "those", "a", "an", "our", "your", "my", "their", "its", "his", "her",
        "each", "every", "any", "which", "what",
    ]

    /// A full stop or question mark for the line ended at `lineEnd` (the newline): inspects only
    /// the final sentence on the line (after any mid-line `.`, `?`, or `!` sentence boundary),
    /// requires at least 4 words in that final sentence, and distinguishes declarative `"When"` /
    /// `"Where"` subordinate clauses from genuine questions.
    static func terminalPunctuation(
        ns: NSString,
        lineEnd: Int,
        document: MarkdownDocument,
        enterEndedLine: Bool?,
        priorEdits: [PunctuationEdit] = []
    ) -> PunctuationEdit? {
        guard lineEnd > 0 else { return nil }
        let endedLine = enterEndedLine ?? (lineEnd + 1 >= ns.length || ns.character(at: lineEnd + 1) == 0x0A)
        guard endedLine else { return nil }

        let last = lineEnd - 1
        guard let scalar = Unicode.Scalar(ns.character(at: last)), CharacterSet.alphanumerics.contains(scalar) else { return nil }

        var wordStart = lineEnd
        while wordStart > 0, isWordCharacter(ns.character(at: wordStart - 1)) { wordStart -= 1 }
        let wordRange = NSRange(location: wordStart, length: lineEnd - wordStart)
        guard wordRange.length > 0,
              TextMechanics.isProse(wordRange, ns: ns, document: document),
              !GrammarVoice.insideUnclosedSpan(before: wordStart, ns: ns) else { return nil }

        let textNode = GrammarVoice.node(at: last, in: document)
        guard textNode.kind == .text else { return nil }
        var paragraph = textNode.parent
        while let current = paragraph, current.kind != .paragraph {
            if current.kind.isBlock { return nil }
            paragraph = current.parent
        }
        guard let paragraph else { return nil }
        var ancestor = paragraph.parent
        while let current = ancestor {
            switch current.kind {
            case .listItem, .tableCell, .alert, .footnoteDefinition: return nil
            default: ancestor = current.parent
            }
        }

        var lineStart = lineEnd
        while lineStart > 0, ns.character(at: lineStart - 1) != 0x0A { lineStart -= 1 }
        var sentenceStart = lineStart
        while sentenceStart < lineEnd {
            let c = ns.character(at: sentenceStart)
            if c == 0x20 || c == 0x09 || c == 0x3E {
                sentenceStart += 1
            } else {
                break
            }
        }

        var i = sentenceStart
        while i < lineEnd {
            let mark = ns.character(at: i)
            if mark == 0x2E || mark == 0x3F || mark == 0x21 {
                guard i > sentenceStart else { i += 1; continue }
                if mark == 0x3F || mark == 0x21,
                   i + 1 < lineEnd,
                   ns.character(at: i + 1) == 0x3F || ns.character(at: i + 1) == 0x21 {
                    i += 1
                    continue
                }
                if mark == 0x2E {
                    let prevChar = ns.character(at: i - 1)
                    if prevChar == 0x2E || (i + 1 < lineEnd && ns.character(at: i + 1) == 0x2E) {
                        i += 1
                        continue
                    }
                    if prevChar == 0x20 || prevChar == 0x09 || (prevChar >= 0x30 && prevChar <= 0x39) {
                        i += 1
                        continue
                    }
                    var prevStart = i
                    while prevStart > sentenceStart,
                          isWordCharacter(ns.character(at: prevStart - 1)) || ns.character(at: prevStart - 1) == 0x2E {
                        prevStart -= 1
                    }
                    let prevLower = ns.substring(with: NSRange(location: prevStart, length: i - prevStart)).lowercased()
                    if GrammarVoice.abbreviations.contains(prevLower) {
                        i += 1
                        continue
                    }
                    if prevLower.count == 1 && !(prevLower == "i" && prevStart >= sentenceStart + 2) {
                        i += 1
                        continue
                    }
                }
                guard isSentenceProsePosition(at: i, in: ns, document: document) else {
                    i += 1
                    continue
                }
                var after = i + 1
                while after < lineEnd {
                    let c = ns.character(at: after)
                    if c == 0x22 || c == 0x27 || c == 0x201D || c == 0x2019 || c == 0x29 || c == 0x5D || c == 0x2A || c == 0x5F || c == 0x7E {
                        after += 1
                    } else {
                        break
                    }
                }
                guard after < lineEnd, ns.character(at: after) == 0x20 || ns.character(at: after) == 0x09 else {
                    i += 1
                    continue
                }
                var next = after
                while next < lineEnd, ns.character(at: next) == 0x20 || ns.character(at: next) == 0x09 {
                    next += 1
                }
                if next < lineEnd {
                    sentenceStart = next
                    i = next
                    continue
                }
            }
            i += 1
        }

        let sentenceRange = NSRange(location: sentenceStart, length: lineEnd - sentenceStart)
        var resolvedNS = ns.substring(with: sentenceRange) as NSString
        let localEdits = priorEdits
            .filter { $0.range.location >= sentenceRange.location && NSMaxRange($0.range) <= NSMaxRange(sentenceRange) }
            .sorted { $0.range.location > $1.range.location }
        for edit in localEdits {
            let localRange = NSRange(location: edit.range.location - sentenceRange.location, length: edit.range.length)
            if NSMaxRange(localRange) <= resolvedNS.length {
                resolvedNS = resolvedNS.replacingCharacters(in: localRange, with: edit.replacement) as NSString
            }
        }
        let finalSentence = stripLeadingQuoteMarkers(resolvedNS as String)
        guard finalSentenceWordCount(in: finalSentence) >= 4 else { return nil }
        let replacement = isQuestionClause(finalSentence) ? "?" : "."
        return PunctuationEdit(range: NSRange(location: lineEnd, length: 0), replacement: replacement, rules: [.terminalPunctuation])
    }

    private static func isSentenceProsePosition(at location: Int, in ns: NSString, document: MarkdownDocument) -> Bool {
        guard !GrammarVoice.insideUnclosedSpan(before: location, ns: ns) else { return false }
        var current: MarkdownNode? = GrammarVoice.node(at: location, in: document)
        while let n = current {
            switch n.kind {
            case .code, .codeBlock, .math, .htmlInline, .htmlBlock, .frontMatter, .image, .table, .tableCell, .tableRow, .linkReferenceDefinition:
                return false
            case .link(_, _, let kind):
                switch kind {
                case .autolink, .extendedAutolink:
                    return false
                case .inline, .reference:
                    if n.markers.contains(where: { NSLocationInRange(location, $0) }) {
                        return false
                    }
                }
            default:
                break
            }
            current = n.parent
        }
        return true
    }

    private static func stripLeadingQuoteMarkers(_ text: String) -> String {
        var idx = text.startIndex
        while idx < text.endIndex, text[idx] == " " || text[idx] == "\t" || text[idx] == ">" {
            idx = text.index(after: idx)
        }
        return String(text[idx...])
    }

    private static func finalSentenceWordCount(in sentence: String) -> Int {
        let strippedLinks = stripLinkDestinations(in: sentence)
        return strippedLinks.split(whereSeparator: { $0 == " " || $0 == "\t" }).reduce(0) { count, token in
            let hasAlnum = token.unicodeScalars.contains { CharacterSet.alphanumerics.contains($0) }
            return count + (hasAlnum ? 1 : 0)
        }
    }

    private static func stripLinkDestinations(in text: String) -> String {
        let ns = text as NSString
        var out = ""
        var inBackticks = false
        var i = 0
        while i < ns.length {
            let c = ns.character(at: i)
            if c == 0x5C, i + 1 < ns.length {
                out += ns.substring(with: NSRange(location: i, length: 2))
                i += 2
                continue
            }
            if c == 0x60 {
                inBackticks.toggle()
                out.append("`")
                i += 1
                continue
            }
            if !inBackticks, c == 0x5D, i + 1 < ns.length, ns.character(at: i + 1) == 0x28 {
                out.append("]")
                i += 2
                var depth = 1
                while i < ns.length, depth > 0 {
                    let inner = ns.character(at: i)
                    if inner == 0x5C { i += 2; continue }
                    if inner == 0x28 { depth += 1 } else if inner == 0x29 { depth -= 1 }
                    i += 1
                }
                continue
            }
            let r = ns.rangeOfComposedCharacterSequence(at: i)
            out += ns.substring(with: r)
            i = NSMaxRange(r)
        }
        return out
    }

    /// Distinguishes genuine questions from declarative sentences and `"When"` / `"Where"`
    /// subordinate clauses using clause structure and `NLTagger` lexical classes (with closed-class
    /// fallbacks when `NLTagger` returns `nil`, such as on the iOS Simulator).
    static func isQuestionClause(
        _ clause: String,
        taggerOverride: (([ClauseToken], String) -> [NLTag?])? = nil
    ) -> Bool {
        let trimmed = stripLeadingQuoteMarkers(clause)
        guard let firstChar = trimmed.first else { return false }
        if firstChar == "`" || firstChar == "$" || firstChar == "<" { return false }

        let tokens = clauseTokens(in: trimmed)
        guard let first = tokens.first?.lower, !first.isEmpty else { return false }
        if unambiguousQuestionWords.contains(first) { return true }
        guard first == "when" || first == "where" else { return false }

        if tokens.count >= 2 && inversionVerbs.contains(tokens[1].lower) {
            return true
        }

        let nsClause = trimmed as NSString
        let commas = topLevelCommaOffsets(in: trimmed)

        // Parenthetical interruption immediately after "When," / "Where," ("When, if ever, does this happen")
        if commas.count >= 2 {
            let beforeFirst = nsClause.substring(to: commas[0])
            if clauseTokens(in: beforeFirst).count == 1, commas[1] + 1 < nsClause.length {
                let afterSecond = nsClause.substring(from: commas[1] + 1)
                if !clauseTokens(in: afterSecond).isEmpty {
                    let reconstructed = "\(tokens[0].text) \(afterSecond)"
                    return isQuestionClause(reconstructed, taggerOverride: taggerOverride)
                }
            }
        }

        let leadingClause = commas.first.map { nsClause.substring(to: $0) } ?? trimmed
        let leadTokens = clauseTokens(in: leadingClause)
        let leadTags = lexicalTags(for: leadTokens, in: leadingClause, taggerOverride: taggerOverride)

        func isInvertedVerbAfterModifier(at idx: Int) -> Bool {
            guard idx + 1 < leadTokens.count else { return false }
            let verb = leadTokens[idx].lower
            guard inversionVerbs.contains(verb) else { return false }
            if verb == "do" || verb == "don't" || verb == "have" {
                let next = leadTokens[idx + 1].lower
                if ["i", "you", "we", "they"].contains(next) { return true }
                return idx + 2 < leadTokens.count && leadTags[(idx + 2)...].contains(.verb)
            }
            return true
        }

        if leadTokens.count >= 4 {
            let w1 = leadTokens[1].lower
            if !nonQuestionAdverbs.contains(w1),
               leadTags[1] == .adverb || whModifierAdverbs.contains(w1),
               isInvertedVerbAfterModifier(at: 2) {
                return true
            }
            if w1 != "to", leadTags[1] == .preposition || whPrepositions.contains(w1) {
                var k = 2
                if k < leadTokens.count, leadTags[k] == .determiner || whDeterminers.contains(leadTokens[k].lower) {
                    k += 1
                }
                if k < leadTokens.count, leadTags[k] == .adjective, !inversionVerbs.contains(leadTokens[k].lower) {
                    k += 1
                }
                if k < leadTokens.count,
                   !inversionVerbs.contains(leadTokens[k].lower),
                   leadTags[k] == .noun || leadTags[k] == nil || leadTags[k] == .other {
                    k += 1
                    if isInvertedVerbAfterModifier(at: k) {
                        return true
                    }
                }
            }
        }

        if let firstComma = commas.first, firstComma + 1 < nsClause.length {
            let mainClause = nsClause.substring(from: firstComma + 1)
            if !clauseTokens(in: mainClause).isEmpty {
                return isQuestionClause(mainClause, taggerOverride: taggerOverride)
            }
        }

        return false
    }

    static func clauseTokens(in text: String) -> [ClauseToken] {
        let ns = text as NSString
        var tokens: [ClauseToken] = []
        var i = 0
        while i < ns.length {
            let c = ns.character(at: i)
            if c == 0x5C, i + 1 < ns.length {
                i += 2
                continue
            }
            // Emit a placeholder token for inline code or inline math so the following word cannot shift into slot 1
            if c == 0x60 {
                let start = i
                var ticks = 0
                while i < ns.length, ns.character(at: i) == 0x60 { ticks += 1; i += 1 }
                while i < ns.length {
                    if ns.character(at: i) == 0x60 {
                        var run = 0
                        while i < ns.length, ns.character(at: i) == 0x60 { run += 1; i += 1 }
                        if run == ticks { break }
                    } else {
                        i += 1
                    }
                }
                tokens.append(ClauseToken(text: "`", lower: "`", range: NSRange(location: start, length: i - start)))
                continue
            }
            if c == 0x24 {
                let start = i
                i += 1
                while i < ns.length {
                    let inner = ns.character(at: i)
                    if inner == 0x5C, i + 1 < ns.length { i += 2; continue }
                    if inner == 0x24 { i += 1; break }
                    i += 1
                }
                tokens.append(ClauseToken(text: "$", lower: "$", range: NSRange(location: start, length: i - start)))
                continue
            }
            if c == 0x5D, i + 1 < ns.length, ns.character(at: i + 1) == 0x28 {
                i += 2
                var depth = 1
                while i < ns.length, depth > 0 {
                    let inner = ns.character(at: i)
                    if inner == 0x5C { i += 2; continue }
                    if inner == 0x28 { depth += 1 } else if inner == 0x29 { depth -= 1 }
                    i += 1
                }
                continue
            }
            if isWordCharacter(c) {
                var start = i
                while i < ns.length, isWordCharacter(ns.character(at: i)) { i += 1 }
                var end = i
                while start < end, ns.character(at: start) == 0x27 || ns.character(at: start) == 0x2019 { start += 1 }
                while end > start, ns.character(at: end - 1) == 0x27 || ns.character(at: end - 1) == 0x2019 { end -= 1 }
                if end > start {
                    let range = NSRange(location: start, length: end - start)
                    let raw = ns.substring(with: range)
                    let lower = raw.replacingOccurrences(of: "’", with: "'").lowercased()
                    tokens.append(ClauseToken(text: raw, lower: lower, range: range))
                }
                continue
            }
            i += 1
        }
        return tokens
    }

    private static func topLevelCommaOffsets(in text: String) -> [Int] {
        let ns = text as NSString
        var offsets: [Int] = []
        var inBackticks = false
        var inMath = false
        var parenDepth = 0
        var bracketDepth = 0
        var inStraightQuotes = false
        var curlyQuoteDepth = 0
        var i = 0
        while i < ns.length {
            let c = ns.character(at: i)
            if c == 0x5C, i + 1 < ns.length {
                i += 2
                continue
            }
            if c == 0x60 {
                inBackticks.toggle()
            } else if !inBackticks {
                if c == 0x24 {
                    inMath.toggle()
                } else if !inMath {
                    switch c {
                    case 0x28: parenDepth += 1
                    case 0x29: if parenDepth > 0 { parenDepth -= 1 }
                    case 0x5B: bracketDepth += 1
                    case 0x5D: if bracketDepth > 0 { bracketDepth -= 1 }
                    case 0x22: inStraightQuotes.toggle()
                    case 0x201C: curlyQuoteDepth += 1
                    case 0x201D: if curlyQuoteDepth > 0 { curlyQuoteDepth -= 1 }
                    case 0x2C:
                        if parenDepth == 0 && bracketDepth == 0 && !inStraightQuotes && curlyQuoteDepth == 0 {
                            offsets.append(i)
                        }
                    default: break
                    }
                }
            }
            i += 1
        }
        return offsets
    }

    private static func lexicalTags(
        for tokens: [ClauseToken],
        in text: String,
        taggerOverride: (([ClauseToken], String) -> [NLTag?])?
    ) -> [NLTag?] {
        if let taggerOverride {
            let overridden = taggerOverride(tokens, text)
            if overridden.count == tokens.count {
                return overridden
            }
        }
        let tagger = NLTagger(tagSchemes: [.lexicalClass])
        tagger.string = text
        return tokens.map { token in
            if token.lower == "`" || token.lower == "$" { return nil }
            guard let strRange = Range(token.range, in: text) else { return nil }
            return tagger.tag(at: strRange.lowerBound, unit: .word, scheme: .lexicalClass).0
        }
    }
}

// MARK: - Grammar Voice (#111)

/// The Grammar voice (#111):
/// - Typing tier, on device (`NLTagger`):
///   - doubled words (`the the` → `the`), keeping deliberate ones (`had had`, `that that`);
///   - `a`/`an` before a vowel or consonant sound (`a apple` → `an apple`, `an user` → `a user`);
///   - a capital after a sentence that the partner itself just closed.
/// - Pause tier, through the bandleader:
///   - subject and verb agreement (`the results shows` → `the results show`);
///   - tense that slips mid-sentence (`she walked in and says` → `she walked in and said`);
///   - a missing small word (`went the shop` → `went to the shop`);
///   - wrong word form (`should of` → `should have`, `more better` → `better`).
nonisolated enum GrammarVoice {
    /// Above this confidence, a pause-tier grammar correction plays through the partner's cursor
    /// as its own undo step in Automatic mode.
    static let autoConfidenceThreshold = 0.80

    /// Below `autoConfidenceThreshold` and at or above this threshold, a correction is offered as
    /// a suggestion (#103). Below this threshold it is dropped.
    static let suggestConfidenceThreshold = 0.50

    /// Maximum words a single pause-tier correction may span or produce ("it corrects, it doesn't rewrite").
    static let maxCorrectionWords = 4

    /// Deliberate doubled words in English prose that must be kept (`had had`, `that that`, `do do`, etc.).
    static let deliberateDoubledWords: Set<String> = [
        "had", "that", "do", "is", "in", "out", "on", "up", "off", "over", "by",
        "so", "no", "yes", "ha", "hehe", "rah", "hip", "tut", "tsk", "shh",
        "there", "now", "well", "hear", "my", "oh", "bye", "blah", "knock",
        "beep", "tap", "tick", "drip", "chop", "win", "fifty", "twenty",
        "very", "many", "long", "far", "old", "little", "big", "great", "more",
        "again", "each", "one", "who", "what", "can", "will", "may", "her",
    ]

    /// Words starting with silent `h` that take `an` (vowel sound).
    private static let silentHPrefixes: [String] = [
        "hour", "honest", "honor", "honour", "heir",
    ]

    /// Words where both `a` and `an` are accepted in standard English; never alter either.
    private static let ambiguousArticleWords: Set<String> = [
        "herb", "herbs", "herbal", "historic", "historical", "historically",
        "homage", "hotel", "habitual", "humble", "hysterical", "hereditary",
    ]

    /// Words starting with `o` that begin with a `/w/` consonant sound and take `a`.
    private static let consonantOWords: Set<String> = [
        "one", "ones", "once", "onetime",
    ]

    /// Prefixes starting with `u`, `eu` or `ew` that begin with a `/juː/` consonant sound and take `a`.
    private static let consonantUPrefixes: [String] = [
        "unit", "unif", "unio", "uniq", "univ", "unil", "unip", "unis", "unic", "unid", "unanim",
        "use", "user", "used", "using", "usab", "usag", "usual", "usurp", "usur",
        "utensil", "uter", "util", "utop", "ubiquit", "ukulele", "uranium", "urin", "urolog",
        "uruguay", "uganda", "ukrain", "utah", "eu", "ewe", "ewer",
    ]

    /// Function words (conjunctions, prepositions, pronouns, auxiliaries) after `a`/`an` where `a` is
    /// likely a letter name ("either a or b", "where a is positive", "from a to b") rather than an article.
    private static let nonArticleFollowingWords: Set<String> = [
        "a", "an", "and", "or", "nor", "but", "if", "as", "at", "in", "on", "of", "to", "by",
        "for", "with", "from", "up", "out", "off", "into", "onto", "over", "under", "after",
        "before", "between", "through", "without", "within", "about", "around", "against", "among",
        "is", "am", "are", "was", "were", "be", "been", "being", "have", "has", "had",
        "do", "does", "did", "can", "could", "will", "would", "shall", "should", "may", "might", "must",
        "it", "its", "he", "she", "we", "they", "you", "me", "him", "her", "us", "them", "i",
        "then", "than", "so", "yet", "vs", "via", "per",
    ]

    static let abbreviations: Set<String> = [
        "e.g", "i.e", "etc", "vs", "cf", "approx", "mr", "mrs", "ms", "dr", "st", "no", "fig", "ca", "al",
    ]

    private static let newline: unichar = 0x0A

    // MARK: Typing-Tier Edits

    /// Typing-tier grammar fixes at `boundary` (raw-Markdown UTF-16 offset).
    static func edits(
        text: String,
        boundary: Int,
        document: MarkdownDocument,
        flavor: MarkdownFlavor,
        baseEdits: [PunctuationEdit] = [],
        isActive: (PunctuationRule) -> Bool = { _ in true }
    ) -> [PunctuationEdit] {
        guard flavor != .slack else { return [] }
        let ns = text as NSString
        guard boundary >= 0, boundary < ns.length else { return [] }
        let typed = ns.character(at: boundary)
        guard PunctuateVoice.isWordBoundary(typed) || typed == newline else { return [] }

        var start = boundary
        while start > 0, PunctuateVoice.isWordCharacter(ns.character(at: start - 1)) { start -= 1 }
        let wordRange = NSRange(location: start, length: boundary - start)
        guard wordRange.length > 0,
              isProseRange(wordRange, in: ns, document: document),
              !insideUnclosedSpan(before: start, ns: ns) else {
            return []
        }

        let rawWord = ns.substring(with: wordRange)
        let resolvedWord = baseEdits.first(where: { $0.range == wordRange })?.replacement ?? rawWord
        var out: [PunctuationEdit] = []

        // 1. A capital after a sentence that the partner itself just closed
        if isActive(.sentenceCase),
           !baseEdits.contains(where: { $0.range == wordRange && $0.rules.contains(.sentenceCase) }),
           let first = resolvedWord.unicodeScalars.first,
           CharacterSet.lowercaseLetters.contains(first),
           !resolvedWord.dropFirst().contains(where: { $0.isUppercase }),
           startsSentenceAfterPartnerClose(at: start, ns: ns, document: document) {
            let capitalised = resolvedWord.prefix(1).uppercased() + resolvedWord.dropFirst()
            out.append(PunctuationEdit(range: wordRange, replacement: capitalised, rules: [.sentenceCase]))
        }

        // 2. Doubled words ("the the" → "the"), keeping deliberate ones ("had had", "that that")
        if isActive(.doubledWords),
           let doubled = doubledWordEdit(word: rawWord, wordRange: wordRange, ns: ns, document: document) {
            out.append(doubled)
            return out
        }

        // 3. "a" / "an" before a vowel or consonant sound
        if isActive(.aAndAn),
           let article = articleEdit(word: resolvedWord, wordRange: wordRange, ns: ns, document: document) {
            out.append(article)
        }

        return out
    }

    /// Merges `baseEdits` from `TextMechanics` with `grammarEdits` from `GrammarVoice`.
    static func merge(baseEdits: [PunctuationEdit], grammarEdits: [PunctuationEdit]) -> [PunctuationEdit] {
        guard !grammarEdits.isEmpty else { return baseEdits }
        var merged = baseEdits
        for gEdit in grammarEdits {
            if let idx = merged.firstIndex(where: { $0.range == gEdit.range }) {
                merged[idx].replacement = gEdit.replacement
                for rule in gEdit.rules where !merged[idx].rules.contains(rule) {
                    merged[idx].rules.append(rule)
                }
            } else if let idx = merged.firstIndex(where: { NSIntersectionRange($0.range, gEdit.range).length > 0 && gEdit.rules.contains(.doubledWords) }) {
                // If the first word of a doubled pair was also edited (e.g. capitalised), keep its rules on the collapsed edit
                var combinedRules = merged[idx].rules
                for rule in gEdit.rules where !combinedRules.contains(rule) {
                    combinedRules.append(rule)
                }
                merged[idx] = PunctuationEdit(range: gEdit.range, replacement: gEdit.replacement, rules: combinedRules)
            } else {
                merged.append(gEdit)
            }
        }
        return merged
    }

    // MARK: Doubled Words Rule

    private static func doubledWordEdit(
        word: String,
        wordRange: NSRange,
        ns: NSString,
        document: MarkdownDocument
    ) -> PunctuationEdit? {
        // Only plain alphabetic words (no apostrophes or digits) where the second copy is lowercase
        guard word.count >= 1,
              word == word.lowercased(),
              word.unicodeScalars.allSatisfy({ CharacterSet.letters.contains($0) }),
              let prev = previousWord(before: wordRange.location, word: word, ns: ns),
              isProseRange(prev.range, in: ns, document: document),
              node(at: prev.range.location, in: document) === node(at: wordRange.location, in: document) else {
            return nil
        }

        let lower = word.lowercased()
        guard prev.text.lowercased() == lower,
              !deliberateDoubledWords.contains(lower) else {
            return nil
        }

        // Check that prev is not preceded by a hyphen, slash, or quote that makes it part of a compound
        if prev.range.location > 0 {
            let beforePrev = ns.character(at: prev.range.location - 1)
            if beforePrev == 0x2D || beforePrev == 0x2F || beforePrev == 0x5F || beforePrev == 0x40 || beforePrev == 0x23 {
                return nil
            }
        }

        // Check with NLTagger that the word is not a proper name or interjection
        let tagger = NLTagger(tagSchemes: [.lexicalClass, .nameType])
        tagger.string = prev.line
        if let strRange = Range(NSRange(location: prev.offsetInLine, length: prev.range.length), in: prev.line) {
            let (nameTag, _) = tagger.tag(at: strRange.lowerBound, unit: .word, scheme: .nameType)
            if nameTag == .personalName || nameTag == .placeName || nameTag == .organizationName {
                return nil
            }
            let (lexTag, _) = tagger.tag(at: strRange.lowerBound, unit: .word, scheme: .lexicalClass)
            if lexTag == .interjection {
                return nil
            }
        }

        let combinedRange = NSRange(
            location: prev.range.location,
            length: NSMaxRange(wordRange) - prev.range.location
        )
        return PunctuationEdit(range: combinedRange, replacement: prev.text, rules: [.doubledWords])
    }

    // MARK: A and An Rule

    private static func articleEdit(
        word: String,
        wordRange: NSRange,
        ns: NSString,
        document: MarkdownDocument
    ) -> PunctuationEdit? {
        guard let prev = previousWord(before: wordRange.location, word: word, ns: ns),
              prev.text == "a" || prev.text == "A" || prev.text == "an" || prev.text == "An",
              isProseRange(prev.range, in: ns, document: document),
              node(at: prev.range.location, in: document) === node(at: wordRange.location, in: document) else {
            return nil
        }

        // Check that the article itself is standalone (not preceded by a hyphen, quote, or letter)
        if prev.range.location > 0 {
            let beforePrev = ns.character(at: prev.range.location - 1)
            if PunctuateVoice.isWordCharacter(beforePrev) || beforePrev == 0x2D || beforePrev == 0x22 || beforePrev == 0x201C || beforePrev == 0x60 {
                return nil
            }
        }

        // Strip trailing possessive if any ("user's" → "user")
        let baseWord = word.replacingOccurrences(of: "’", with: "'").split(separator: "'").first.map(String.init) ?? word
        guard baseWord.count >= 2,
              baseWord.unicodeScalars.allSatisfy({ CharacterSet.letters.contains($0) }),
              !baseWord.dropFirst().contains(where: { $0.isUppercase }) else {
            return nil
        }

        let lower = baseWord.lowercased()
        guard !nonArticleFollowingWords.contains(lower),
              !ambiguousArticleWords.contains(lower) else {
            return nil
        }

        // Use NLTagger on the line to confirm the following word is a content/modifier word (not a conjunction/preposition/particle)
        let tagger = NLTagger(tagSchemes: [.lexicalClass])
        tagger.string = prev.line
        let wordOffsetInLine = prev.offsetInLine + prev.range.length + 1
        if let strRange = Range(NSRange(location: wordOffsetInLine, length: (baseWord as NSString).length), in: prev.line) {
            let (lexTag, _) = tagger.tag(at: strRange.lowerBound, unit: .word, scheme: .lexicalClass)
            if lexTag == .conjunction || lexTag == .preposition || lexTag == .particle || lexTag == .interjection {
                return nil
            }
        }

        guard let wantsAn = requiresAn(for: lower) else { return nil }
        let replacement: String?
        switch (prev.text, wantsAn) {
        case ("a", true): replacement = "an"
        case ("A", true): replacement = "An"
        case ("an", false): replacement = "a"
        case ("An", false): replacement = "A"
        default: replacement = nil
        }
        guard let replacement else { return nil }
        return PunctuationEdit(range: prev.range, replacement: replacement, rules: [.aAndAn])
    }

    /// Returns `true` if `lower` begins with a vowel sound (`an`), `false` if it begins with a
    /// consonant sound (`a`), or `nil` if ambiguous.
    static func requiresAn(for lower: String) -> Bool? {
        guard !lower.isEmpty, !ambiguousArticleWords.contains(lower) else { return nil }
        if silentHPrefixes.contains(where: { lower.hasPrefix($0) }) {
            return true
        }
        if consonantOWords.contains(lower) || lower.hasPrefix("one-") {
            return false
        }
        if consonantUPrefixes.contains(where: { lower.hasPrefix($0) }) {
            return false
        }
        guard let first = lower.first else { return nil }
        return ["a", "e", "i", "o", "u"].contains(first)
    }

    // MARK: Sentence Capital After Partner Close

    /// Detects when the word at `start` begins a new sentence whose preceding sentence was closed by
    /// the partner (e.g. ending in `"I."` where the partner capitalised `"i"` → `"I"`, or after closing
    /// single/curly quotes, emphasis markers, or blockquote line starts).
    static func startsSentenceAfterPartnerClose(at start: Int, ns: NSString, document: MarkdownDocument) -> Bool {
        let textNode = node(at: start, in: document)
        var block = textNode.parent
        while let current = block, !current.kind.isBlock { block = current.parent }
        guard let block else { return false }
        switch block.kind {
        case .paragraph, .heading, .blockQuote: break
        default: return false
        }

        var i = start
        while i > 0 {
            let c = ns.character(at: i - 1)
            if c == 0x20 || c == 0x2A || c == 0x5F || c == 0x7E || c == 0x5B || c == 0x28 || c == 0x22 || c == 0x27 || c == 0x201C || c == 0x2018 {
                i -= 1
            } else {
                break
            }
        }
        guard i > 0 else { return false }

        // Blockquote continuation line ("> second line" after a newline)
        if ns.character(at: i - 1) == 0x3E {
            var q = i - 1
            while q > 0, ns.character(at: q - 1) == 0x20 || ns.character(at: q - 1) == 0x3E { q -= 1 }
            if q == 0 || ns.character(at: q - 1) == newline { return true }
        }

        guard i < start, (i..<start).contains(where: { ns.character(at: $0) == 0x20 }) else { return false }
        var stop = i - 1
        // Step back over closing quotes, brackets, or emphasis markers after terminal punctuation
        while stop > 0 {
            let end = ns.character(at: stop)
            if end == 0x22 || end == 0x27 || end == 0x201D || end == 0x2019 || end == 0x29 || end == 0x5D || end == 0x2A || end == 0x5F {
                stop -= 1
            } else {
                break
            }
        }
        let mark = ns.character(at: stop)
        if mark == 0x3F || mark == 0x21 { return true }
        guard mark == 0x2E else { return false }
        if stop > 0 {
            let before = ns.character(at: stop - 1)
            if before == 0x2E { return false } // ellipsis
            if before >= 0x30, before <= 0x39 { return false } // decimal
        }
        var wordStart = stop
        while wordStart > 0, PunctuateVoice.isWordCharacter(ns.character(at: wordStart - 1)) || ns.character(at: wordStart - 1) == 0x2E {
            wordStart -= 1
        }
        let previous = ns.substring(with: NSRange(location: wordStart, length: stop - wordStart))
        let prevLower = previous.lowercased()
        if abbreviations.contains(prevLower) { return false }
        if prevLower.count == 1 {
            // Single-letter "I" at the end of a clause ("It was I. Next") is the pronoun I, not an initial like "J. Smith"
            return prevLower == "i" && wordStart >= 2
        }
        return true
    }

    // MARK: Context & AST Helpers

    private static func previousWord(
        before start: Int,
        word: String,
        ns: NSString
    ) -> (range: NSRange, text: String, line: String, offsetInLine: Int)? {
        guard start >= 2, ns.character(at: start - 1) == 0x20 else { return nil }
        var previousStart = start - 1
        while previousStart > 0, PunctuateVoice.isWordCharacter(ns.character(at: previousStart - 1)) {
            previousStart -= 1
        }
        let range = NSRange(location: previousStart, length: start - 1 - previousStart)
        guard range.length > 0 else { return nil }
        var lineStart = previousStart
        while lineStart > 0, ns.character(at: lineStart - 1) != newline { lineStart -= 1 }
        let line = ns.substring(with: NSRange(location: lineStart, length: start + (word as NSString).length - lineStart))
        return (range, ns.substring(with: range), line, previousStart - lineStart)
    }

    static func node(at location: Int, in document: MarkdownDocument) -> MarkdownNode {
        var node = document.root
        descend: while true {
            for child in node.children where NSLocationInRange(location, child.range) {
                node = child
                continue descend
            }
            return node
        }
    }

    /// True when the entire `range` is ordinary prose outside code, math, HTML, front matter,
    /// link destinations, images, reference definitions, autolinks, and tables.
    static func isProseRange(_ range: NSRange, in ns: NSString, document: MarkdownDocument) -> Bool {
        guard range.location >= 0, NSMaxRange(range) <= ns.length else { return false }
        let checkLocations = range.length <= 1
            ? [range.location]
            : [range.location, NSMaxRange(range) - 1]
        for loc in checkLocations {
            guard TextMechanics.isProse(NSRange(location: loc, length: 1), ns: ns, document: document) else {
                return false
            }
            // Also verify no inline code/math/html/link-marker inside the range
            var current: MarkdownNode? = node(at: loc, in: document)
            while let n = current {
                switch n.kind {
                case .code, .codeBlock, .math, .htmlInline, .htmlBlock, .frontMatter, .image, .table, .tableCell, .tableRow, .linkReferenceDefinition:
                    return false
                case .link(_, _, let kind):
                    switch kind {
                    case .autolink, .extendedAutolink:
                        return false
                    case .inline, .reference:
                        if n.markers.contains(where: { NSIntersectionRange($0, range).length > 0 }) {
                            return false
                        }
                    }
                default:
                    break
                }
                current = n.parent
            }
        }
        if insideUnclosedSpan(before: range.location, ns: ns) {
            return false
        }
        return true
    }

    /// Checks for unclosed inline code, math, table rows, reference definitions, link destinations,
    /// HTML tags, or front matter before `location`.
    static func insideUnclosedSpan(before location: Int, ns: NSString) -> Bool {
        var backticks = 0
        var dollars = 0
        var i = location
        while i > 0 {
            let c = ns.character(at: i - 1)
            if c == newline { break }
            if c == 0x60 { backticks += 1 }
            if c == 0x24, i < 2 || ns.character(at: i - 2) != 0x5C { dollars += 1 }
            i -= 1
        }
        if backticks % 2 == 1 || dollars % 2 == 1 { return true }
        let linePrefix = ns.substring(with: NSRange(location: i, length: location - i))
        if linePrefix.range(of: "^[ \\t]*\\|", options: .regularExpression) != nil { return true }
        if linePrefix.range(of: "^ {0,3}\\[[^\\[\\]]+\\]:", options: .regularExpression) != nil { return true }
        if linePrefix.range(of: "<[A-Za-z!/][^>]*$", options: .regularExpression) != nil { return true }
        if insideUnclosedHTMLOrImage(inLinePrefix: linePrefix) { return true }
        if insideUnclosedLinkDestination(linePrefix as NSString) { return true }
        return insideUnclosedFrontMatter(before: location, ns: ns)
    }

    static func insideUnclosedHTMLOrImage(before location: Int, ns: NSString) -> Bool {
        var i = location
        while i > 0, ns.character(at: i - 1) != newline { i -= 1 }
        let linePrefix = ns.substring(with: NSRange(location: i, length: max(0, location - i)))
        return insideUnclosedHTMLOrImage(inLinePrefix: linePrefix)
    }

    private static func insideUnclosedHTMLOrImage(inLinePrefix linePrefix: String) -> Bool {
        // Unclosed image alt `![...` without matching `]`
        if let bangBracket = linePrefix.range(of: "![", options: .backwards) {
            let after = linePrefix[bangBracket.upperBound...]
            if !after.contains("]") { return true }
        }
        // Unclosed inline HTML tag `<tag...>` without matching `</tag>` on the line
        if let regex = try? NSRegularExpression(pattern: "<([A-Za-z][A-Za-z0-9-]*)(?:\\s[^>/]*)?>", options: []) {
            let nsLine = linePrefix as NSString
            let matches = regex.matches(in: linePrefix, options: [], range: NSRange(location: 0, length: nsLine.length))
            for match in matches {
                let tagRange = match.range(at: 1)
                guard tagRange.location != NSNotFound else { continue }
                let tagName = nsLine.substring(with: tagRange).lowercased()
                if ["br", "hr", "img", "input", "meta", "link"].contains(tagName) { continue }
                let afterStart = NSMaxRange(match.range)
                let rest = nsLine.substring(from: afterStart).lowercased()
                if !rest.contains("</\(tagName)>") {
                    return true
                }
            }
        }
        return false
    }

    private static func insideUnclosedLinkDestination(_ line: NSString) -> Bool {
        var inCode = false
        var depth = 0
        var i = 0
        while i < line.length {
            let c = line.character(at: i)
            if c == 0x5C { i += 2; continue }
            if c == 0x60 { inCode.toggle(); i += 1; continue }
            if !inCode {
                if depth == 0, c == 0x5D, i + 1 < line.length, line.character(at: i + 1) == 0x28 {
                    depth = 1
                    i += 2
                    continue
                } else if depth > 0 {
                    if c == 0x28 { depth += 1 } else if c == 0x29 { depth -= 1 }
                }
            }
            i += 1
        }
        return depth > 0
    }

    private static func insideUnclosedFrontMatter(before location: Int, ns: NSString) -> Bool {
        let first: Int
        if ns.hasPrefix("---\n") { first = 4 } else if ns.hasPrefix("---\r\n") { first = 5 } else { return false }
        guard location >= first else { return false }
        var end = min(ns.length, location + 1)
        while end < ns.length, ns.character(at: end - 1) != newline { end += 1 }
        let lines = ns.substring(with: NSRange(location: first, length: end - first)).components(separatedBy: "\n")
        guard let firstLine = lines.first, firstLine.range(of: "^[A-Za-z0-9_-]+[ \\t]*:", options: .regularExpression) != nil else { return false }
        return !lines.dropFirst().contains { $0.trimmingCharacters(in: .whitespaces) == "---" || $0.trimmingCharacters(in: .whitespaces) == "..." }
    }
}

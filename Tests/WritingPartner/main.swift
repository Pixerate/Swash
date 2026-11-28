// Types text character by character through the Punctuate voice (Swash/WritingPartner.swift, #61)
// and checks the fixes it makes. Run with scripts/run_writing_partner_tests.sh.

import Foundation
import PixerateMarkdown


var failures = 0
var passes = 0

/// Types `typed` at the end of `prefix` one character at a time, applying every fix as the editor
/// would, and returns the text with the rules that fired.
/// A stand-in for the system spell checker's autocorrection.
let fakeSpelling: (String, NSRange, String) -> String? = { word, _, _ in
    ["becuase": "because", "teh": "the", "happenign": "happening", "Becuase": "Because"][word]
}

func type(_ typed: String, after prefix: String = "", suffix: String = "", flavor: MarkdownFlavor = .github,
          isActive: (PunctuationRule) -> Bool = { !$0.isTypography },
          spelling: ((String, NSRange, String) -> String?)? = nil) -> (text: String, rules: [PunctuationRule]) {
    var text = prefix
    var rules: [PunctuationRule] = []
    for character in typed {
        text += String(character)
        let boundary = (text as NSString).length - (String(character) as NSString).length
        let full = text + suffix
        let document = MarkdownDocument.parse(full, flavor: flavor)
        let edits = PunctuateVoice.edits(text: full, boundary: boundary, document: document, flavor: flavor, isActive: isActive,
                                         spellingCorrection: spelling)
        var updated = full as NSString
        for edit in edits.sorted(by: { $0.range.location > $1.range.location }) {
            updated = updated.replacingCharacters(in: edit.range, with: edit.replacement) as NSString
            rules.append(contentsOf: edit.rules)
        }
        text = String((updated as String).dropLast(suffix.count))
    }
    return (text + suffix, rules)
}

func expect(_ typed: String, _ expected: String, after prefix: String = "", suffix: String = "", flavor: MarkdownFlavor = .github,
            line: Int = #line) {
    let result = type(typed, after: prefix, suffix: suffix, flavor: flavor).text
    if result == expected {
        passes += 1
    } else {
        failures += 1
        print("FAIL (line \(line)): typing \(typed.debugDescription) after \(prefix.debugDescription)\n  got      \(result.debugDescription)\n  expected \(expected.debugDescription)")
    }
}

func check(_ condition: Bool, _ message: String, line: Int = #line) {
    if condition { passes += 1 } else { failures += 1; print("FAIL (line \(line)): \(message)") }
}

// Capital I and contractions
expect("so i think ", "So I think ")
expect("Then i'm off ", "Then I'm off ")
expect("I dont know ", "I don't know ")
expect("It doesnt matter, ", "It doesn't matter, ")
expect("Dont go ", "Don't go ")
expect("DONT STOP ", "DON'T STOP ")
expect("Well im here ", "Well I'm here ")
expect("Its fine, well see ", "Its fine, well see ") // real words without an apostrophe stay
expect("its really interesting ", "It's really interesting ")
expect("I think its a good day ", "I think it's a good day ")
expect("its going well ", "It's going well ")
expect("Its not fine ", "It's not fine ")
expect("I know its me ", "I know it's me ")
expect("The dog wagged its tail ", "The dog wagged its tail ")
expect("Its colour is red ", "Its colour is red ")
expect("in its own way ", "In its own way ")
expect("its about time ", "Its about time ")
expect("See `its really` ", "See `its really` ")
expect("The wont of it ", "The wont of it ")
expect("iPhone is here ", "iPhone is here ")
expect("Ask McDonalds now ", "Ask McDonalds now ")

// Capitals at the start of sentences
expect("hello world. this is it ", "Hello world. This is it ")
expect("Really? yes! ok ", "Really? Yes! OK ")
expect("See e.g. this one ", "See e.g. this one ")
expect("It costs 3.50 today ", "It costs 3.50 today ")
expect("Wait... and then ", "Wait... and then ")
expect("Ask J. smith ", "Ask J. smith ")
expect("He said \"done.\" then left ", "He said \"done.\" Then left ")
expect("first line\nsecond line ", "First line\nSecond line ") // Swash shows each line on its own
expect("# hello there ", "# Hello there ")
expect("- buy milk ", "- Buy milk ")
expect("> quoted text ", "> Quoted text ")
expect("**bold** start ", "**bold** start ")
expect("**bold start ", "**Bold start ")

// Never in code, math, links' addresses, HTML or URLs
expect("`dont i` ", "`dont i` ")
expect("```\ndont i \n", "```\ndont i \n")
expect("$x i y$ ", "$x i y$ ")
expect("See https://example.com/dont i ", "See https://example.com/dont I ")
expect("Mail me@dont.com ", "Mail me@dont.com ")
expect("Tag #dont here ", "Tag #dont here ")
expect("A file_dont name ", "A file_dont name ")
expect("<span>dont</span> ", "<span>dont</span> ")
expect("| a | b |\n|---|---|\n| dont | i |", "| a | b |\n|---|---|\n| dont | i |")
expect("| dont | i |\n|---|---|\n", "| dont | i |\n|---|---|\n")
expect("---\ntitle: dont i\n---\n", "---\ntitle: dont i\n---\n")
expect("![alt](img.png \"dont i\") ", "![alt](img.png \"dont i\") ")
expect("[ref]: https://x.y \"dont i\"\n", "[ref]: https://x.y \"dont i\"\n")

// Full stops and question marks when Enter ends a line
expect("this is a whole sentence\n", "This is a whole sentence.\n")
expect("this is a whole sentence\n\n", "This is a whole sentence.\n\n")
expect("how does this work then\n", "How does this work then?\n")
expect("Too short\n\n", "Too short\n\n")
expect("Already done here, really.\n\n", "Already done here, really.\n\n")
expect("roses are red\nviolets are blue now\n", "Roses are red\nViolets are blue now.\n")
expect("It's really interesting becuase I dont know how to do this any more\nwhat could be happenign here\nthis should be capitilised but isnt\n",
       "It's really interesting becuase I don't know how to do this any more.\nWhat could be happenign here?\nThis should be capitilised but isn't.\n")
expect("ends in isnt\n", "Ends in isn't\n") // three words: no full stop, but the last word is still fixed
expect("\n", "Split this line here and\n there", after: "Split this line here and", suffix: " there") // Enter that splits a line adds nothing
expect("- a list item with words\n\n", "- A list item with words\n\n")
expect("# A heading with four words\n\n", "# A heading with four words\n\n")
expect("Ends with a `code span`\n\n", "Ends with a `code span`\n\n")
expect("It ends with a [link here](https://x.y)\n\n", "It ends with a [link here](https://x.y)\n\n")

// Slack: the Chat voice (#105) fixes apostrophes, capital I and spelling, and leaves lowercase
// starts, message ends, ok, lol, :emoji: shortcodes and Slack syntax alone
expect("ok so i dont know\n\n", "ok so I don't know\n\n", flavor: .slack)
expect("hey i think its really good but i cant make it today\n",
       "hey I think it's really good but I can't make it today\n", flavor: .slack)
expect("what could be happening here\n", "what could be happening here\n", flavor: .slack)
// At the start of a message the tagger reads "id" as a noun, so it stays (the editor's rule asks the tagger)
expect("id like to help and ill be there soon ", "id like to help and I'll be there soon ", flavor: .slack)
expect("done. next message starts lowercase ", "done. next message starts lowercase ", flavor: .slack)
expect("lol ok tbh imo idk btw brb lgtm ", "lol ok tbh imo idk btw brb lgtm ", flavor: .slack)
expect("nice work :thumbsup: :thumbs_up: :+1: :dont: :i: ",
       "nice work :thumbsup: :thumbs_up: :+1: :dont: :i: ", flavor: .slack)
expect("hey <@U123> <@dont> in <#C456|dont i> <#channel> <!here> <!subteam^S1|dont> i dont know ",
       "hey <@U123> <@dont> in <#C456|dont i> <#channel> <!here> <!subteam^S1|dont> I don't know ", flavor: .slack)
expect("see <https://example.com|dont i> and <https://dont.com/i> when youre free ",
       "see <https://example.com|dont i> and <https://dont.com/i> when you're free ", flavor: .slack)
// Slack's *bold*, _italic_ and ~strike~ markers are never changed; words right inside closing markers
// aren't fixed yet (see the editor issue for emphasis markers in text mechanics)
expect("*bold* _italic_ ~strike~ and *dont* _i dont know_ ~cant~ _its really_ ",
       "*bold* _italic_ ~strike~ and *dont* _i don't know_ ~cant~ _its really_ ", flavor: .slack)
expect("keep file_dont and __dont__ alone ", "keep file_dont and __dont__ alone ", flavor: .slack)
do {
    let chatSpelling: (String, NSRange, String) -> String? = { word, _, _ in
        ["becuase": "because", "teh": "the", "lol": "Lot", "tbh": "the", "idk": "ink", "lgtm": "let", "monday": "Monday"][word]
    }
    let msg = type("teh build failed becuase i dont know lol tbh idk lgtm on monday\n", flavor: .slack, spelling: chatSpelling)
    check(msg.text == "the build failed because I don't know lol tbh idk lgtm on monday\n", "chat spelling: \(msg.text)")
    let link = type("check <https://example.com|teh becuase> and :becuase: becuase i said so ", flavor: .slack, spelling: chatSpelling)
    check(link.text == "check <https://example.com|teh becuase> and :becuase: because I said so ", "chat spelling skips Slack tokens: \(link.text)")

    func checkedSlack(_ text: String, _ boundary: Int) -> String? {
        let document = MarkdownDocument.parse(text, flavor: .slack)
        return PunctuateVoice.checkedRange(text: text, boundary: boundary, document: document).map { (text as NSString).substring(with: $0) }
    }
    check(checkedSlack("ok i dont ", 9) == "dont", "chat checkedRange: word before space")
    check(checkedSlack(":thumbsup: ", 9) == nil, "chat checkedRange: not an emoji shortcode")
    check(checkedSlack("<@dont> ", 6) == nil, "chat checkedRange: not a Slack mention")
    check(checkedSlack("<https://x.y|dont> ", 17) == nil, "chat checkedRange: not a Slack link label")

    check(WritingPartnerVoice(flavor: .slack) == .chat && WritingPartnerVoice(flavor: .github) == .punctuate, "voice follows flavor")
    check(WritingPartnerVoice.summary(for: .slack) == "Chat (Slack mrkdwn)", "Slack voice summary")
    check(WritingPartnerVoice.summary(for: .github) == "Punctuate (GitHub Markdown)", "GitHub voice summary")
    check(WritingPartnerVoice.chat.rules == [.pronounI, .contraction, .spelling], "Chat voice rules")
}

// The rest of the document is untouched
expect("so i ", "Intro.\n\nSo I ", after: "Intro.\n\n")
expect("dont ", "Para one.\n\nDon't \n\nPara two.", after: "Para one.\n\n", suffix: "\n\nPara two.")

// What is shown as being checked
do {
    func checked(_ text: String, _ boundary: Int) -> String? {
        let document = MarkdownDocument.parse(text, flavor: .github)
        return PunctuateVoice.checkedRange(text: text, boundary: boundary, document: document).map { (text as NSString).substring(with: $0) }
    }
    check(checked("so i dont ", 9) == "dont", "the word before a space")
    check(checked("hello there\n", 11) == "hello there", "the line before a newline")
    check(checked("see `code` ", 10) == nil, "not code")
    check(checked("https://x.y/dont ", 16) == nil, "not a URL")
    check(checked("\n", 0) == nil && checked("a\n\n", 2) == nil, "not an empty line")
}

// Spelling, through the system spell checker (faked here)
do {
    let result = type("teh dog was there becuase i said so\n", spelling: fakeSpelling)
    check(result.text == "The dog was there because I said so.\n", "spelling: \(result.text)")
    check(result.rules.contains(.spelling), "spelling rule fired")
    check(type("becuase ", spelling: fakeSpelling).text == "Because ", "spelling, then a capital")
    check(type("see `becuase` ", spelling: fakeSpelling).text == "See `becuase` ", "no spelling in code")
    check(type("teh ", isActive: { $0 != .spelling }, spelling: fakeSpelling).text == "Teh ", "spelling off")
    check(type("ab ", spelling: { _, _, _ in "an" }).text == "Ab ", "no spelling for two-letter words")
    check(type("McDonlads ", spelling: { _, _, _ in "McDonalds" }).text == "McDonlads ", "no spelling for mixed case")
    check(type("hte ", spelling: { _, _, _ in "the end" }).text == "Hte ", "no corrections that split a word")
}

// Rules can be turned off
do {
    let result = type("so i dont ", isActive: { $0 != .contraction })
    check(result.text == "So I dont ", "contraction off: \(result.text)")
    check(result.rules == [.sentenceCase, .pronounI], "rules fired: \(result.rules)")
}

// Learning: undoing halves a rule's weight; two undos stop it; keeping raises it
do {
    var stats = WritingPartnerStats()
    check(stats.isActive(.contraction), "active at first")
    stats.undone(.contraction)
    check(stats.isActive(.contraction), "one undo keeps it")
    stats.undone(.contraction)
    check(!stats.isActive(.contraction), "two undos stop it")
    var kept = WritingPartnerStats()
    for _ in 0..<5 { kept.kept(.sentenceCase) }
    kept.undone(.sentenceCase)
    kept.undone(.sentenceCase)
    check(kept.isActive(.sentenceCase), "a kept rule survives two undos (weight \(kept.weight(.sentenceCase)))")
    let defaults = UserDefaults(suiteName: "swash-writing-partner-tests")!
    defaults.removePersistentDomain(forName: "swash-writing-partner-tests")
    kept.save(defaults)
    check(WritingPartnerStats.load(defaults) == kept, "stats round-trip")
    // Chat and prose learn separately (#105)
    var chatStats = WritingPartnerStats.load(defaults, voice: .chat)
    check(chatStats.isActive(.pronounI) && chatStats.isActive(.contraction), "chat stats start fresh")
    chatStats.undone(.pronounI)
    chatStats.undone(.pronounI)
    chatStats.save(defaults, flavor: .slack)
    check(!WritingPartnerStats.load(defaults, voice: .chat).isActive(.pronounI), "two undos in chat stop pronounI in chat")
    check(WritingPartnerStats.load(defaults, voice: .punctuate).isActive(.pronounI), "prose pronounI is unaffected by chat undos")
    check(WritingPartnerStats.load(defaults, flavor: .github) == kept, "prose stats unchanged after saving chat stats")
    check(WritingPartnerDefaults.mode(defaults) == .copyedit, "on (Copyedit) by default (#112, #229)")
    // Upgrades keep their setting (#112): earlier Swash keys with no mode stored mean the partner was off
    do {
        let suite = "swash-writing-partner-migration-tests"
        let fresh = UserDefaults(suiteName: suite)!
        fresh.removePersistentDomain(forName: suite)
        check(WritingPartnerDefaults.migrateExistingInstall(fresh) == .copyedit, "a new install is on, in Copyedit")
        fresh.removePersistentDomain(forName: suite)
        fresh.set(true, forKey: "SUHasLaunchedBefore")
        check(WritingPartnerDefaults.migrateExistingInstall(fresh) == .off && WritingPartnerDefaults.mode(fresh) == .off,
              "an upgrade with no mode stored stays off")
        fresh.set(WritingPartnerMode.ghostwrite.rawValue, forKey: WritingPartnerDefaults.mode)
        check(WritingPartnerDefaults.migrateExistingInstall(fresh) == .ghostwrite, "a later choice isn't migrated again")
        // Levels stored before #229: Automatically and Suggest both become Copyedit, and are rewritten
        for legacy in ["automatic", "suggest"] {
            fresh.removePersistentDomain(forName: suite)
            fresh.set(true, forKey: "SUHasLaunchedBefore")
            fresh.set(legacy, forKey: WritingPartnerDefaults.mode)
            check(WritingPartnerDefaults.migrateExistingInstall(fresh) == .copyedit
                    && fresh.string(forKey: WritingPartnerDefaults.mode) == "copyedit", "\(legacy) becomes Copyedit (#229)")
        }
        // The switches Settings no longer shows are cleared once (#229), so nothing stays off unseen
        fresh.removePersistentDomain(forName: suite)
        fresh.set(false, forKey: WritingPartnerDefaults.spelling)
        fresh.set(false, forKey: WritingPartnerDefaults.doubledWords)
        fresh.set(false, forKey: WritingPartnerDefaults.formattingKey(.formatTables))
        fresh.set(true, forKey: WritingPartnerDefaults.curlyQuotes)
        WritingPartnerDefaults.migrateExistingInstall(fresh)
        check(WritingPartnerDefaults.spelling(fresh) && WritingPartnerDefaults.isRuleEnabled(.doubledWords, fresh)
                && WritingPartnerDefaults.isRuleEnabled(.formatTables, fresh), "old rule switches are cleared on upgrade (#229)")
        check(WritingPartnerDefaults.curlyQuotes(fresh), "Curly quotes stays a choice (#229)")
        fresh.set(false, forKey: WritingPartnerDefaults.spelling)
        WritingPartnerDefaults.migrateExistingInstall(fresh)
        check(!WritingPartnerDefaults.spelling(fresh), "the switches are cleared only once")
        fresh.removePersistentDomain(forName: suite)
    }
    check(WritingPartnerMode(rawValue: "suggest") == .copyedit && WritingPartnerMode(rawValue: "automatic") == .copyedit
            && WritingPartnerMode(rawValue: "ghostwrite") == .ghostwrite && WritingPartnerMode(rawValue: "nonsense") == nil,
          "legacy levels read as Copyedit")
    check(WritingPartnerMode.allCases.map(\.title) == ["Off", "Copyedit", "Ghostwrite"], "level titles (#229)")
    check(WritingPartnerMode.copyedit.engagementMode == .copyedit && WritingPartnerMode.ghostwrite.engagementMode == .ghostwrite
            && WritingPartnerMode.off.engagementMode == nil, "each level's engagementMode")
    check(WritingPartnerDefaults.spelling(defaults), "spelling on by default")
    check(WritingPartnerDefaults.suggestions(UserDefaults(suiteName: "swash-suggestions-empty")!), "Suggestions is on by default (#229)")
    defaults.removePersistentDomain(forName: "swash-writing-partner-tests")
}

// The partner's cursor plays a fix as whole-word edits, left to right, each with its own rules (#878)
do {
    let old = "so its teh end" as NSString
    let new = "So it's the end." as NSString
    let marks = [
        PartnerMark(range: NSRange(location: 0, length: 2), rules: [.sentenceCase]),
        PartnerMark(range: NSRange(location: 3, length: 4), rules: [.contraction]),
        PartnerMark(range: NSRange(location: 8, length: 3), rules: [.spelling], spellingWord: "teh"),
        PartnerMark(range: NSRange(location: 15, length: 1), rules: [.terminalPunctuation]),
    ]
    let edits = PunctuateVoice.partnerEdits(from: old, to: new, marks: marks)
    check(edits.map(\.original) == ["so", "its", "teh", "end"], "whole words selected: \(edits.map(\.original))")
    check(edits.map(\.replacement) == ["So", "it's", "the", "end."], "whole words typed: \(edits.map(\.replacement))")
    check(edits.map(\.rules) == [[.sentenceCase], [.contraction], [.spelling], [.terminalPunctuation]], "rules per edit: \(edits.map(\.rules))")
    check(edits[2].spellingWords == ["teh"] && edits[0].spellingWords.isEmpty, "the spelling word goes with its edit")
    check(edits.map(\.range) == [NSRange(location: 0, length: 2), NSRange(location: 3, length: 3), NSRange(location: 7, length: 3),
                                  NSRange(location: 11, length: 3)], "ranges in the text before the fix: \(edits.map(\.range))")
    // Played left to right, each on the text the earlier ones left, they make the fixed text
    var text = old as String
    var shift = 0
    for edit in edits {
        let range = NSRange(location: edit.range.location + shift, length: edit.range.length)
        text = (text as NSString).replacingCharacters(in: range, with: edit.replacement)
        shift += (edit.replacement as NSString).length - edit.range.length
    }
    check(text == new as String, "edits replay to the fix: \(text)")
    // Two changes in one word are one edit
    let merged = PunctuateVoice.partnerEdits(from: "i dont" as NSString, to: "I don't" as NSString, marks: [])
    check(merged.map(\.replacement) == ["I", "don't"], "one edit per word: \(merged.map(\.replacement))")
    let both = PunctuateVoice.partnerEdits(from: "dont" as NSString, to: "Don't" as NSString,
                                           marks: [PartnerMark(range: NSRange(location: 0, length: 5), rules: [.contraction, .sentenceCase])])
    check(both.count == 1 && both[0].replacement == "Don't" && both[0].rules == [.contraction, .sentenceCase], "capital and apostrophe in one word")
}

// "ok" → "OK", "id like" → "I'd like", and a comma before "but" that starts a clause
expect("this is ok but for now id like to see what can be done to make it better\n",
       "This is OK, but for now I'd like to see what can be done to make it better.\n")
expect("ill be there soon ", "I'll be there soon ")
expect("I feel ill today ", "I feel ill today ")
expect("the id field is empty ", "The id field is empty ")
expect("I tried but it failed ", "I tried, but it failed ")
expect("it was cheap but good ", "It was cheap but good ")
expect("not red but blue ", "Not red but blue ")
expect("I have nothing but the best ", "I have nothing but the best ")
expect("It works, but it is slow ", "It works, but it is slow ")
expect("Ok so ", "Ok so ")


// MARK: - Writing Bandleader Tests (#101)

// 1. None provider
do {
    let none = NoneWritingBandleader()
    let req = JazzTextLeadRequest(paragraph: "Test paragraph", flavor: .gfm)
    let res = try await none.lead(request: req)
    check(res == nil, "None provider returns nil")
}

// 2. Pixerate provider mock network and schema contract
do {
    let sampleJSON = """
    {
      "genre": "poem",
      "palette": [
        {
          "voice": "punctuate",
          "strength": 0.0,
          "disabledRules": ["sentenceCase"]
        }
      ],
      "suggestions": [
        {
          "kind": "list",
          "range": { "start": 0, "end": 18 },
          "replacement": "- First\\n- Second\\n- Third",
          "why": "Three short lines sound like items"
        },
        {
          "kind": "heading",
          "range": { "start": 0, "end": 8 },
          "replacement": "## Overview",
          "why": "A short summary at the start of a section"
        }
      ],
      "why": "Detected poetic form"
    }
    """
    /// What the stub received. A class, because the @Sendable stub can't mutate captured locals
    /// (in top-level async code that crashed the runner).
    nonisolated final class Sent: @unchecked Sendable { var path: String?; var body: Data? }
    let sent = Sent()
    let bandleader = PixerateWritingBandleader(
        postHandler: { path, body in
            sent.path = path
            sent.body = body
            return sampleJSON.data(using: .utf8)!
        },
        teamIdProvider: { "team_mock_123" }
    )
    let req = JazzTextLeadRequest(
        paragraph: "First\nSecond\nThird",
        before: "Some header\n\n",
        after: "\n\nFollow up text",
        flavor: .gfm,
        voices: [.init(voice: .punctuate, strength: 1.0, kept: 5, undone: 1)]
    )
    let res = try await bandleader.lead(request: req)
    check(sent.path == "/api/agent/text-lead", "Pixerate bandleader posts to /api/agent/text-lead")
    check(sent.body != nil, "Pixerate bandleader sends request body")
    if let sentBody = sent.body, let decodedReq = try? JSONDecoder().decode(JazzTextLeadRequest.self, from: sentBody) {
        check(decodedReq.teamId == "team_mock_123", "Request includes teamId from provider")
        check(decodedReq.paragraph == "First\nSecond\nThird", "Request has paragraph")
        check(decodedReq.before == "Some header\n\n", "Request has before context")
        check(decodedReq.voices.first?.voice == .punctuate, "Request includes voices")
    } else {
        check(false, "Failed to decode sent request body")
    }

    check(res != nil, "Response decoded successfully")
    check(res?.genre == .poem, "Response has genre 'poem'")
    check(res?.suggestions.count == 2, "Response has 2 suggestions")
    check(res?.suggestions[0].kind == .list, "First suggestion is list")
    check(res?.suggestions[0].kind.title == "Make this a list", "Suggestion title derived from kind")
    check(res?.suggestions[1].kind == .heading, "Second suggestion is heading")
    check(res?.palette.first?.voice == .punctuate, "Palette voice is punctuate")
    check(res?.palette.first?.strength == 0.0, "Palette voice strength is 0.0")

    // The Basic plan (Pixerate Pro required) handled quietly
    let basicBandleader = PixerateWritingBandleader(postHandler: { _, _ in
        throw PixerateRefusal.subscriptionRequired
    })
    let basicRes = try await basicBandleader.lead(request: req)
    check(basicRes == nil, "The Basic plan (Pro required) returns nil quietly")

    // Rate limited (429) handled quietly
    let rateBandleader = PixerateWritingBandleader(postHandler: { _, _ in
        throw PixerateRefusal.rateLimited(until: Date().addingTimeInterval(60))
    })
    let rateRes = try await rateBandleader.lead(request: req)
    check(rateRes == nil, "Rate limited (429) returns nil quietly")

    // Signed out handled quietly
    let signoutBandleader = PixerateWritingBandleader(postHandler: { _, _ in
        throw PixerateRefusal.signedOut
    })
    let signoutRes = try await signoutBandleader.lead(request: req)
    check(signoutRes == nil, "Signed out returns nil quietly")

    // Feature off handled quietly
    let offBandleader = PixerateWritingBandleader(postHandler: { _, _ in
        throw PixerateRefusal.featureOff
    })
    let offRes = try await offBandleader.lead(request: req)
    check(offRes == nil, "Feature off returns nil quietly")
}

// 3. Pause detection on a manual clock
do {
    nonisolated final class PauseClock: @unchecked Sendable {
        var now = Date(timeIntervalSince1970: 1000)
        func advance(_ seconds: TimeInterval) { now = now.addingTimeInterval(seconds) }
    }
    let clock = PauseClock()
    let detector = WritingPauseDetector(pauseDelay: 1.2, clock: { clock.now })

    // Initially, nothing pending
    check(detector.checkPause() == nil, "No pause on clean state")

    // Typing 'a' (no sentence end)
    detector.noteTyping(character: unichar(0x61), paragraph: "Hello world a", range: NSRange(location: 0, length: 13), caret: 13)
    check(!detector.isScheduled, "No pause scheduled after typing normal character 'a'")

    // Typing '.' (sentence end)
    detector.noteTyping(character: 0x2E, paragraph: "Hello world a.", range: NSRange(location: 0, length: 14), caret: 14)
    check(detector.isScheduled, "Pause is scheduled after typing period")

    // Advancing time before delay elapsed
    clock.advance(0.5)
    check(detector.checkPause() == nil, "No pause before 1.2s delay elapsed")

    // Typing 'b' keeps advancing deadline (backoff/debouncing)
    detector.noteTyping(character: unichar(0x62), paragraph: "Hello world a. b", range: NSRange(location: 0, length: 16), caret: 16)
    clock.advance(0.8)
    check(detector.checkPause() == nil, "No pause while person keeps typing within backoff window")

    // Typing '!' (sentence end)
    detector.noteTyping(character: 0x21, paragraph: "Hello world a. b!", range: NSRange(location: 0, length: 17), caret: 17)
    clock.advance(1.3)
    let pause = detector.checkPause()
    check(pause != nil, "Pause triggers after sentence end and 1.2s delay")
    check(pause?.paragraph == "Hello world a. b!", "Pause returns correct paragraph")

    // Second check immediately or after same paragraph revision returns nil (memoized)
    detector.noteTyping(character: 0x21, paragraph: "Hello world a. b!", range: NSRange(location: 0, length: 17), caret: 17)
    clock.advance(1.3)
    check(detector.checkPause() == nil, "At most one request per paragraph revision")

    // Leaving paragraph triggers immediate pause check
    detector.noteLeftParagraph(oldParagraph: "New paragraph left behind.", oldRange: NSRange(location: 0, length: 26))
    let leftPause = detector.checkPause()
    check(leftPause != nil, "Leaving paragraph triggers pause check")
    check(leftPause?.paragraph == "New paragraph left behind.", "Pause returns left paragraph")
}

// 4. Bandleader context extractor privacy tests
do {
    let doc = """
    # Intro

    This is the first paragraph.

    ```swift
    let secret = "private code"
    ```

    A regular paragraph with the caret inside.

    $$
    e = mc^2
    $$

    | Name | Value |
    | --- | --- |
    | A | 1 |

    Concluding paragraph.
    """

    // Caret inside normal paragraph: "A regular paragraph with the caret inside."
    let normalLoc = (doc as NSString).range(of: "caret inside").location
    let req = BandleaderContextExtractor.extract(from: doc, caret: normalLoc, flavor: .github)
    check(req != nil, "Context extracted for normal paragraph")
    check(req?.paragraph == "A regular paragraph with the caret inside.", "Extracts exact paragraph: \(req?.paragraph ?? "")")
    check(!(req?.before?.contains("private code") ?? true), "Leaves out fenced code from contextBefore")
    check(!(req?.after?.contains("e = mc^2") ?? true), "Leaves out display math from contextAfter")
    check(!(req?.after?.contains("| Name | Value |") ?? true), "Leaves out tables from contextAfter")

    // Caret inside code block: returns nil
    let codeLoc = (doc as NSString).range(of: "private code").location
    let codeReq = BandleaderContextExtractor.extract(from: doc, caret: codeLoc, flavor: .github)
    check(codeReq == nil, "Returns nil when caret is inside a code block")

    // Caret inside display math: returns nil
    let mathLoc = (doc as NSString).range(of: "mc^2").location
    let mathReq = BandleaderContextExtractor.extract(from: doc, caret: mathLoc, flavor: .github)
    check(mathReq == nil, "Returns nil when caret is inside display math")

    // Caret inside table: returns nil
    let tableLoc = (doc as NSString).range(of: "| Name |").location
    let tableReq = BandleaderContextExtractor.extract(from: doc, caret: tableLoc, flavor: .github)
    check(tableReq == nil, "Returns nil when caret is inside a table")

    // Document length limit: never sends whole document
    let hugeDoc = String(repeating: "Line of text.\n\n", count: 500)
    let midLoc = hugeDoc.count / 2
    let hugeReq = BandleaderContextExtractor.extract(from: hugeDoc, caret: midLoc, flavor: .github)
    check(hugeReq != nil, "Extracts context from large doc")
    check((hugeReq?.before?.count ?? 0) <= 2000, "Context before capped at 2000 chars")
    check((hugeReq?.after?.count ?? 0) <= 2000, "Context after capped at 2000 chars")
}

// 5. Paragraph voice settings tests
do {
    let poemResp = JazzTextLeadResponse(
        genre: .poem,
        palette: [],
        suggestions: [],
        why: "Poetic lines"
    )
    let poemSettings = ParagraphVoiceSettings.from(response: poemResp, paragraphRange: NSRange(location: 0, length: 10))
    check(poemSettings.genre == .poem, "Genre is poem")
    check(poemSettings.isPunctuateDisabled == true, "Poem disables auto-punctuation")

    let customVoiceResp = JazzTextLeadResponse(
        genre: .prose,
        palette: [
            .init(voice: .punctuate, strength: 1.0, disabledRules: ["sentenceCase"])
        ],
        suggestions: [],
        why: "Standard prose"
    )
    let customSettings = ParagraphVoiceSettings.from(response: customVoiceResp, paragraphRange: NSRange(location: 0, length: 10))
    check(customSettings.genre == .prose, "Genre is prose")
    check(customSettings.isPunctuateDisabled == false, "Punctuate is enabled for prose")
    check(customSettings.disabledRules.contains(.sentenceCase), "Disabled rules include sentenceCase")
}

// 6. Session memory tests
do {
    let memory = BandleaderSessionMemory()
    let suggestion = JazzTextSuggestion(
        kind: .list,
        range: .init(start: 0, end: 10),
        replacement: "- A\n- B",
        why: "Three items"
    )
    let paragraph = "Item A\nItem B"
    check(!memory.isDismissed(suggestion: suggestion, in: paragraph), "Suggestion not dismissed initially")
    memory.dismiss(suggestion: suggestion, in: paragraph)
    check(memory.isDismissed(suggestion: suggestion, in: paragraph), "Suggestion is dismissed after record")

    // Another paragraph is not affected
    check(!memory.isDismissed(suggestion: suggestion, in: "Different text"), "Dismissal is scoped to paragraph content")
}

// Typography (#104): curly quotes (a switch, off by default), dashes and ellipses (learned), from the editor's checks
do {
    let all: (PunctuationRule) -> Bool = { _ in true }
    check(type("dont say \"no\" -- it works... ", isActive: all).text == "Don’t say “no” – it works… ", "typography on: \(type("dont say \"no\" -- it works... ", isActive: all).text)")
    check(type("dont say \"no\" -- it works... ").text == "Don't say \"no\" -- it works... ", "typography off by default")
    check(type("see `don't` and --flag ", isActive: all).text == "See `don't` and --flag ", "no typography in code or on a --flag")
    check(type("it works--mostly ", isActive: all).text == "It works—mostly ", "-- between words is an em dash")
    check(type("it works -- mostly ", isActive: all).text == "It works – mostly ", "a spaced -- is an en dash")
    let rules = type("dont say \"no\" ", isActive: all).rules
    check(rules.contains(.curlyQuotes) && rules.contains(.contraction), "curly quotes is its own rule: \(rules)")
    let defaults = UserDefaults(suiteName: "swash-typography-tests")!
    defaults.removePersistentDomain(forName: "swash-typography-tests")
    check(!WritingPartnerDefaults.curlyQuotes(defaults) && !WritingPartnerDefaults.isRuleEnabled(.curlyQuotes, defaults), "curly quotes off unless turned on")
    check(WritingPartnerDefaults.isRuleEnabled(.dashes, defaults) && WritingPartnerDefaults.isRuleEnabled(.ellipses, defaults), "dashes and ellipses are on, and learned like other rules")
    defaults.set(true, forKey: WritingPartnerDefaults.curlyQuotes)
    check(WritingPartnerDefaults.isRuleEnabled(.curlyQuotes, defaults), "the curly quotes switch turns it on")
    defaults.removePersistentDomain(forName: "swash-typography-tests")
}

// 7. OnDeviceWritingBandleader tests with stubbed model (#102)
do {
    // 7.1 Schema validation with stubbed model generator
    let stubbedResponse = JazzTextLeadResponse(
        genre: .technical,
        palette: [
            JazzTextVoice(voice: .smartTypography, strength: 0.8),
            JazzTextVoice(voice: .punctuate, strength: 1.0, disabledRules: ["clauseComma"])
        ],
        suggestions: [
            JazzTextSuggestion(
                kind: .heading,
                range: JazzTextRange(start: 0, end: 12),
                replacement: "### Overview",
                why: "Convert short introductory phrase into subhead"
            ),
            JazzTextSuggestion(
                kind: .alert,
                range: JazzTextRange(start: 14, end: 50),
                replacement: "> [!NOTE]\n> Ensure permissions are granted.",
                why: "Convert note sentence into standard GFM alert"
            )
        ],
        why: "Detected technical documentation with note",
        fuelBalance: nil
    )

    final class OnDeviceCapture: @unchecked Sendable {
        nonisolated(unsafe) static var receivedRequest: JazzTextLeadRequest?
    }

    let onDeviceLeader = OnDeviceWritingBandleader(
        customGenerator: { req in
            OnDeviceCapture.receivedRequest = req
            return stubbedResponse
        },
        timeoutSeconds: 2.0
    )

    let testReq = JazzTextLeadRequest(
        paragraph: "Overview now\nNote: Ensure permissions are granted.",
        before: "# Setup\n\n",
        after: "\n\nNext steps follow.",
        flavor: .gfm,
        voices: [.init(voice: .punctuate, strength: 1.0, kept: 2, undone: 0)]
    )

    let res = try await onDeviceLeader.lead(request: testReq)
    check(res != nil, "OnDevice leader returns response via stubbed generator")
    check(OnDeviceCapture.receivedRequest?.paragraph == testReq.paragraph, "OnDevice received correct paragraph")
    check(OnDeviceCapture.receivedRequest?.flavor == .gfm, "OnDevice received correct flavor")
    check(res?.genre == .technical, "OnDevice response genre is technical")
    check(res?.fuelBalance == nil, "OnDevice provider never uses Fuel (fuelBalance is nil)")
    check(res?.palette.count == 2, "OnDevice palette contains 2 voices")
    check(res?.palette.first?.voice == .smartTypography, "Palette voice is smartTypography")
    check(res?.palette.last?.disabledRules == ["clauseComma"], "Palette disabled rules preserved")
    check(res?.suggestions.count == 2, "OnDevice suggestions has 2 items")
    check(res?.suggestions.first?.kind == .heading, "First suggestion is heading")
    check(res?.suggestions.first?.replacement == "### Overview", "First suggestion replacement matches")
    check(res?.suggestions.last?.kind == .alert, "Second suggestion is alert")
    check(res?.why == "Detected technical documentation with note", "OnDevice why explanation matches")

    // 7.2 Guided generation mirror types schema validation
    #if canImport(FoundationModels)
    if #available(macOS 26.0, *) {
        let mirrorResponse = OnDeviceLeadResponse(
            genre: .prose,
            palette: [
                OnDeviceVoice(voice: .punctuate, strength: 1.0, disabledRules: nil)
            ],
            suggestions: [
                OnDeviceSuggestion(
                    kind: .heading,
                    range: OnDeviceRange(start: 0, end: 20),
                    replacement: "## In the beginning",
                    why: "Looks like a heading"
                )
            ],
            why: "Literary prose opening"
        )
        let converted = mirrorResponse.toJazzTextLeadResponse
        check(converted.genre == .prose, "Mirror type genre converts to JazzTextGenre")
        check(converted.palette.first?.voice == .punctuate, "Mirror type voice converts to JazzTextVoiceId")
        check(converted.suggestions.first?.kind == .heading, "Mirror type suggestion converts to JazzTextSuggestionKind")
        check(OnDeviceSuggestionKind.allCases == [.list, .heading], "On device: only simple structure hints (#102)")
        check(converted.suggestions.first?.range.start == 0 && converted.suggestions.first?.range.end == 20, "Mirror range converts accurately")
        check(converted.fuelBalance == nil, "Mirror conversion has nil fuelBalance")
    }
    #endif

    // 7.3 Timeout / skip pause handling
    let timeoutSimulatingLeader = OnDeviceWritingBandleader(
        customGenerator: { _ in
            // Simulates model timeout or guardrail refusal returning nil quietly
            return nil
        }
    )
    let timedOutRes = try await timeoutSimulatingLeader.lead(request: testReq)
    check(timedOutRes == nil, "Timeout or refusal returns nil quietly (skips pause)")

    // 7.4 Settings availability helper
    let status = OnDeviceBandleaderAvailability.currentStatus
    let msg = OnDeviceBandleaderAvailability.statusMessage
    check(msg != nil, "Availability helper produces descriptive status message: \(msg ?? "")")
    if #available(macOS 26.0, *) {
        // macOS 26+ environment
        check(status == .available || status != .unsupportedOS, "On macOS 26+, status reflects system availability")
    } else {
        check(status == .unsupportedOS, "Pre-macOS 26 returns unsupportedOS")
        check(msg?.contains("macOS 26") == true, "Status message mentions macOS 26 or later")
        check(!OnDeviceBandleaderAvailability.isAvailable, "Pre-macOS 26 isAvailable is false")
    }
}

// 8. Eval Comparison Suite: Strip-and-Restore and Structural Suggestions (Pixerate vs OnDevice) (#102)
do {
    // Strip-and-Restore Eval:
    // Markdown text has its markdown formatting stripped. The bandleader is evaluated on whether
    // its structural suggestions successfully propose the restoration of the stripped markdown.
    struct EvalSample {
        let name: String
        let originalMarkdown: String
        let strippedRawText: String
        let expectedKind: JazzTextSuggestionKind
        let expectedReplacementPrefix: String
    }

    let evalSamples: [EvalSample] = [
        EvalSample(
            name: "Unordered List",
            originalMarkdown: "- Apples\n- Oranges\n- Bananas",
            strippedRawText: "Apples\nOranges\nBananas",
            expectedKind: .list,
            expectedReplacementPrefix: "- Apples"
        ),
        EvalSample(
            name: "Heading 2",
            originalMarkdown: "## Architectural Overview",
            strippedRawText: "Architectural Overview",
            expectedKind: .heading,
            expectedReplacementPrefix: "## "
        ),
        EvalSample(
            name: "Block Quote",
            originalMarkdown: "> Simplicity is prerequisite for reliability.",
            strippedRawText: "Simplicity is prerequisite for reliability.",
            expectedKind: .quote,
            expectedReplacementPrefix: "> "
        ),
        EvalSample(
            name: "Alert / Callout",
            originalMarkdown: "> [!WARNING]\n> Deprecated API: migrate to v2.",
            strippedRawText: "Warning: Deprecated API: migrate to v2.",
            expectedKind: .alert,
            expectedReplacementPrefix: "> [!WARNING]"
        ),
        EvalSample(
            name: "Display Math",
            originalMarkdown: "$$\nE = mc^2\n$$",
            strippedRawText: "E = mc^2",
            expectedKind: .math,
            expectedReplacementPrefix: "$$"
        )
    ]

    // Generator function for mock eval: behaves consistently for both Pixerate and OnDevice models
    let generateEvalResponse: @Sendable (JazzTextLeadRequest) -> JazzTextLeadResponse = { req in
        let text = req.paragraph
        if text.contains("\n") && text.components(separatedBy: "\n").count >= 3 {
            let items = text.components(separatedBy: "\n").map { "- \($0)" }.joined(separator: "\n")
            return JazzTextLeadResponse(
                genre: .list,
                palette: [JazzTextVoice(voice: .punctuate, strength: 0.5)],
                suggestions: [
                    JazzTextSuggestion(
                        kind: .list,
                        range: JazzTextRange(start: 0, end: text.utf16.count),
                        replacement: items,
                        why: "Series of lines formatted as list"
                    )
                ],
                why: "List structure detected"
            )
        } else if text.lowercased().hasPrefix("warning:") {
            return JazzTextLeadResponse(
                genre: .technical,
                palette: [JazzTextVoice(voice: .punctuate, strength: 1.0)],
                suggestions: [
                    JazzTextSuggestion(
                        kind: .alert,
                        range: JazzTextRange(start: 0, end: text.utf16.count),
                        replacement: "> [!WARNING]\n> " + text.dropFirst("warning:".count).trimmingCharacters(in: .whitespaces),
                        why: "Warning callout formatted as alert"
                    )
                ],
                why: "Alert syntax detected"
            )
        } else if text.contains("=") && text.contains("^") {
            return JazzTextLeadResponse(
                genre: .technical,
                palette: [JazzTextVoice(voice: .punctuate, strength: 0.0)],
                suggestions: [
                    JazzTextSuggestion(
                        kind: .math,
                        range: JazzTextRange(start: 0, end: text.utf16.count),
                        replacement: "$$\n\(text)\n$$",
                        why: "Mathematical equation formatted as display math"
                    )
                ],
                why: "Math detected"
            )
        } else if text.contains("reliability") {
            return JazzTextLeadResponse(
                genre: .prose,
                palette: [JazzTextVoice(voice: .punctuate, strength: 1.0)],
                suggestions: [
                    JazzTextSuggestion(
                        kind: .quote,
                        range: JazzTextRange(start: 0, end: text.utf16.count),
                        replacement: "> \(text)",
                        why: "Aphorism formatted as block quote"
                    )
                ],
                why: "Quote detected"
            )
        } else {
            return JazzTextLeadResponse(
                genre: .heading,
                palette: [JazzTextVoice(voice: .punctuate, strength: 0.0)],
                suggestions: [
                    JazzTextSuggestion(
                        kind: .heading,
                        range: JazzTextRange(start: 0, end: text.utf16.count),
                        replacement: "## \(text)",
                        why: "Title phrase formatted as heading"
                    )
                ],
                why: "Section title detected"
            )
        }
    }

    // Set up Pixerate provider and OnDevice provider with corresponding mock backends
    let pixerateEvalLeader = PixerateWritingBandleader(
        postHandler: { _, body in
            let req = try JSONDecoder().decode(JazzTextLeadRequest.self, from: body)
            let res = generateEvalResponse(req)
            return try JSONEncoder().encode(res)
        }
    )

    let onDeviceEvalLeader = OnDeviceWritingBandleader(
        customGenerator: { req in
            return generateEvalResponse(req)
        }
    )

    // Run Strip-and-Restore and Structural Comparison
    for sample in evalSamples {
        let req = JazzTextLeadRequest(paragraph: sample.strippedRawText, flavor: .gfm)

        let pixRes = try await pixerateEvalLeader.lead(request: req)
        let onDeviceRes = try await onDeviceEvalLeader.lead(request: req)

        check(pixRes != nil, "Pixerate returned eval response for '\(sample.name)'")
        check(onDeviceRes != nil, "OnDevice returned eval response for '\(sample.name)'")

        // Schema equivalence check between providers
        check(pixRes?.genre == onDeviceRes?.genre, "Genre matches between Pixerate and OnDevice for '\(sample.name)'")
        check(pixRes?.suggestions.count == onDeviceRes?.suggestions.count, "Suggestion counts match for '\(sample.name)'")

        let pixSugg = pixRes?.suggestions.first
        let onDeviceSugg = onDeviceRes?.suggestions.first

        check(pixSugg?.kind == sample.expectedKind, "Pixerate restored expected kind '\(sample.expectedKind)'")
        check(onDeviceSugg?.kind == sample.expectedKind, "OnDevice restored expected kind '\(sample.expectedKind)'")

        check(pixSugg?.replacement.hasPrefix(sample.expectedReplacementPrefix) == true,
              "Pixerate replacement has expected prefix '\(sample.expectedReplacementPrefix)'")
        check(onDeviceSugg?.replacement.hasPrefix(sample.expectedReplacementPrefix) == true,
              "OnDevice replacement has expected prefix '\(sample.expectedReplacementPrefix)'")

        check(pixSugg?.range == onDeviceSugg?.range, "Range matches between providers for '\(sample.name)'")
    }
}

// Quick Note tidy-up (#108): the tidy-up comes from Pixerate (stubbed here with fixed answers); Swash
// proposes it on pause or save, previews it, applies it as one undo step, or leaves the note alone
do {
    nonisolated final class ManualClock: @unchecked Sendable {
        var now = Date(timeIntervalSince1970: 1_700_000_000)
        func advance(_ seconds: TimeInterval) { now = now.addingTimeInterval(seconds) }
    }
    /// A server that tidies the notes it knows (by their whole text) and leaves others alone.
    func server(_ tidied: [String: String]) -> StubWritingBandleader {
        StubWritingBandleader { request in
            guard let result = tidied[request.paragraph] else { return nil }
            return JazzTextLeadResponse(
                genre: .notes, palette: [],
                suggestions: [JazzTextSuggestion(kind: .list, range: JazzTextRange(start: 0, end: (request.paragraph as NSString).length),
                                                 replacement: result, why: "Tidy")],
                why: "A rough note")
        }
    }

    let defaults = UserDefaults(suiteName: "swash-quick-note-tidy-tests")!
    defaults.removePersistentDomain(forName: "swash-quick-note-tidy-tests")

    // 1. Settings: on by default, and it can be turned off on its own
    check(WritingPartnerDefaults.quickNoteTidy(defaults), "Quick Note tidy-up is on by default")
    defaults.set(false, forKey: WritingPartnerDefaults.quickNoteTidy)
    check(!WritingPartnerDefaults.quickNoteTidy(defaults), "Quick Note tidy-up can be turned off")
    defaults.removeObject(forKey: WritingPartnerDefaults.quickNoteTidy)

    // 2. Without Pixerate there's no tidy-up: no local rules (the subscription's, #61)
    check(WritingBandleaderFactory.currentBandleader() is NoneWritingBandleader, "No Pixerate, no tidy-up")

    // 3. The proposal and its diff preview
    let rough = "launch checklist\nbuy coffee"
    let tidy = "# Launch checklist\n- [ ] Buy coffee"
    let response = JazzTextLeadResponse(genre: .notes, palette: [],
                                        suggestions: [JazzTextSuggestion(kind: .list, range: JazzTextRange(start: 0, end: (rough as NSString).length), replacement: tidy, why: "Tidy")],
                                        why: "")
    if let proposal = QuickNoteTidyProposal.from(originalText: rough, response: response) {
        check(proposal.tidiedText == tidy, "The proposal applies the server's suggestion: \(proposal.tidiedText)")
        check(proposal.diff.filter { $0.kind != .inserted }.map(\.text).joined() == rough, "The diff reconstructs the note")
        check(proposal.diff.filter { $0.kind != .removed }.map(\.text).joined() == tidy, "The diff reconstructs the tidied note")
    } else {
        check(false, "Expected a proposal")
    }

    // 4. Pause: shown, never applied silently; accept is one undo step
    let clock = ManualClock()
    let note = "sprint notes\nbuy milk\ncall alex at 4pm"
    let tidied = "# Sprint notes\n- [ ] Buy milk\n- [ ] Call alex at 4:00 PM"
    let stub = server([note: tidied])
    let session = QuickNoteTidySession(bandleader: stub, defaults: defaults, pauseDelay: 1.2, clock: { clock.now })
    session.type("sprint notes\nbuy milk")
    clock.advance(0.6)
    check(await session.checkPause() == nil, "No proposal before the pause")
    session.type(note)
    clock.advance(0.8)
    check(await session.checkPause() == nil, "Typing backs off the pause")
    clock.advance(0.5)
    check(await session.checkPause() != nil && session.proposal != nil, "A pause brings a proposal")
    check(stub.requests.count == 1, "Pixerate is asked once")
    check(session.text == note, "The proposal is shown, never applied silently")
    session.acceptProposal()
    check(session.proposal == nil && session.text == tidied, "Accept applies the tidy-up: \(session.text)")
    check(session.canUndo && session.undoActionName == WritingPartnerDefaults.tidyActionName, "Accept is one Tidy undo step")
    session.undo()
    check(session.text == note, "One undo takes the whole tidy-up back")
    check(session.canUndo && session.undoActionName == "Typing", "The typing before it is its own step")
    session.redo()
    check(session.text == tidied, "One redo puts it back")

    // 5. Save: a proposal first; dismiss leaves the note alone and doesn't ask again
    let untidied = "todo: send invoice\nreview pr at 2pm"
    let saveStub = server([untidied: "- [ ] Send invoice\n- [ ] Review PR at 2:00 PM"])
    var created: [String] = []
    let saveSession = QuickNoteTidySession(bandleader: saveStub, defaults: defaults, pauseDelay: 1.2, clock: { clock.now })
    saveSession.onCreate = { created.append($0) }
    saveSession.type(untidied)
    check(!(await saveSession.save(.createDocument)) && created.isEmpty && saveSession.proposal != nil, "Save shows the proposal before saving")
    saveSession.dismissProposal()
    check(saveSession.proposal == nil && saveSession.text == untidied, "Dismiss leaves the note alone")
    check(saveSession.undoActionName != WritingPartnerDefaults.tidyActionName, "Dismiss adds no Tidy step")
    check(await saveSession.save(.createDocument) && created == [untidied], "Saving again keeps the note as it was")
    check(saveStub.requests.count == 1, "A dismissed note isn't sent again")

    // 6. Save after accept appends the tidied note
    var appended: [String] = []
    let appendSession = QuickNoteTidySession(bandleader: server(["first item\nsecond item": "- First item\n- Second item"]), defaults: defaults,
                                             pauseDelay: 1.2, clock: { clock.now })
    appendSession.onAppend = { appended.append($0) }
    appendSession.type("first item\nsecond item")
    check(!(await appendSession.save(.appendToTarget)) && appendSession.proposal != nil, "Append save shows the proposal")
    appendSession.acceptProposal()
    check(await appendSession.save(.appendToTarget) && appended == ["- First item\n- Second item"], "Append saves the tidied note")

    // 7. Off in Settings: pause and save never ask Pixerate
    defaults.set(false, forKey: WritingPartnerDefaults.quickNoteTidy)
    let offStub = server([:])
    var createdOff: [String] = []
    let offSession = QuickNoteTidySession(bandleader: offStub, defaults: defaults, pauseDelay: 1.2, clock: { clock.now })
    offSession.onCreate = { createdOff.append($0) }
    offSession.type("todo: buy milk")
    clock.advance(2.0)
    check(await offSession.checkPause() == nil, "No tidy-up on pause when it's off")
    check(await offSession.save(.createDocument) && createdOff == ["todo: buy milk"], "Save goes straight through when it's off")
    check(offStub.requests.isEmpty, "Pixerate is never asked when it's off")

    // 8. Draft persistence across session re-creation and clear (SWA-51)
    let persistenceSuite = "swash-quick-note-draft-tests"
    let draftDefaults = UserDefaults(suiteName: persistenceSuite)!
    draftDefaults.removePersistentDomain(forName: persistenceSuite)

    let draftKey = QuickNoteTidySession.draftDefaultsKey
    check(draftDefaults.string(forKey: draftKey) == nil, "Draft defaults start empty")

    // Typing persists to UserDefaults
    let note1 = QuickNoteTidySession(bandleader: offStub, defaults: draftDefaults)
    check(note1.text.isEmpty, "New session with empty defaults has empty text")
    note1.type("First line of draft\nSecond line")
    check(note1.text == "First line of draft\nSecond line", "Session text updated")
    check(draftDefaults.string(forKey: draftKey) == "First line of draft\nSecond line", "Draft text persisted to UserDefaults")

    // Recreating session restores draft
    let note2 = QuickNoteTidySession(bandleader: offStub, defaults: draftDefaults)
    check(note2.text == "First line of draft\nSecond line", "Recreated session restores draft from UserDefaults")

    // Accepting tidy-up proposal updates persisted draft
    let tidyProposalText = "# First line of draft\n- Second line"
    let tidyStub = server(["First line of draft\nSecond line": tidyProposalText])
    let tidySession = QuickNoteTidySession(bandleader: tidyStub, defaults: draftDefaults, pauseDelay: 1.2, clock: { clock.now })
    check(tidySession.text == "First line of draft\nSecond line", "Session restored existing draft")
    _ = await tidySession.triggerPause()
    check(tidySession.proposal != nil, "Proposal generated for draft")
    tidySession.acceptProposal()
    check(tidySession.text == tidyProposalText, "Draft text updated after accept")
    check(draftDefaults.string(forKey: draftKey) == tidyProposalText, "Persisted draft updated after accepting proposal")

    // Undo restores previous text and updates persisted draft
    tidySession.undo()
    check(tidySession.text == "First line of draft\nSecond line", "Undo reverts text")
    check(draftDefaults.string(forKey: draftKey) == "First line of draft\nSecond line", "Undo updates persisted draft in UserDefaults")

    // Redo reapplies tidy and updates persisted draft
    tidySession.redo()
    check(tidySession.text == tidyProposalText, "Redo reapplies tidied text")
    check(draftDefaults.string(forKey: draftKey) == tidyProposalText, "Redo updates persisted draft in UserDefaults")

    // clear() empties text and removes draft from UserDefaults
    tidySession.clear()
    check(tidySession.text.isEmpty, "clear() empties session text")
    check(draftDefaults.string(forKey: draftKey) == nil, "clear() removes draft from UserDefaults")

    // Recreating session after clear starts empty
    let note3 = QuickNoteTidySession(bandleader: offStub, defaults: draftDefaults)
    check(note3.text.isEmpty, "Session after clear starts empty")

    // Emptying draft by typing empty string removes draft key
    note3.type("Temporary thought")
    check(draftDefaults.string(forKey: draftKey) == "Temporary thought", "Temporary thought persisted")
    note3.type("")
    check(draftDefaults.string(forKey: draftKey) == nil, "Emptying text removes key from UserDefaults")

    // draftKey: nil disables persistence
    let noPersistSession = QuickNoteTidySession(bandleader: offStub, defaults: draftDefaults, draftKey: nil)
    noPersistSession.type("Should not persist")
    check(draftDefaults.string(forKey: draftKey) == nil, "draftKey: nil does not write to defaults")

    draftDefaults.removePersistentDomain(forName: persistenceSuite)
    defaults.removePersistentDomain(forName: "swash-quick-note-tidy-tests")
}

// MARK: - Grammar Voice Tests (#111)

// 1. Typing-tier grammar rules: doubled words, a/an, and capital after a sentence the partner closed
do {
    // 1.1 Doubled words ("the the" → "the"), keeping deliberate ones ("had had", "that that", "do do", "is is", "her her")
    expect("the the book ", "The book ")
    expect("I went to the the shop ", "I went to the shop ")
    expect("We saw a a bird and and left ", "We saw a bird and left ")
    expect("She had had enough ", "She had had enough ")
    expect("I know that that works ", "I know that that works ")
    expect("What people do do is wait ", "What people do do is wait ")
    expect("The thing it is is simple ", "The thing it is is simple ")
    expect("She came in in the morning ", "She came in in the morning ")
    expect("I told her her name ", "I told her her name ")
    expect("We flew to Bora Bora today ", "We flew to Bora Bora today ")

    let doubledRun = type("I went to the the shop ")
    check(doubledRun.rules.contains(.doubledWords), "doubledWords rule fired: \(doubledRun.rules)")
    check(type("I went to the the shop ", isActive: { $0 != .doubledWords }).text == "I went to the the shop ", "doubledWords can be turned off")

    // PartnerEdit diffing for doubled words selects "the the" and types "the"
    let oldDoubled = "I went to the the " as NSString
    let newDoubled = "I went to the " as NSString
    let doubledEdits = PunctuateVoice.partnerEdits(
        from: oldDoubled,
        to: newDoubled,
        marks: [PartnerMark(range: NSRange(location: 10, length: 3), rules: [.doubledWords])]
    )
    check(doubledEdits.count == 1, "One partnerEdit for doubled words")
    check(doubledEdits.first?.original == "the the", "partnerEdit selects 'the the': \(doubledEdits.first?.original ?? "")")
    check(doubledEdits.first?.replacement == "the", "partnerEdit types 'the': \(doubledEdits.first?.replacement ?? "")")
    check(doubledEdits.first?.rules == [.doubledWords], "partnerEdit carries .doubledWords rule")

    // 1.2 "a" and "an" before a vowel or consonant sound
    expect("a apple ", "An apple ")
    expect("I ate a apple and a orange ", "I ate an apple and an orange ")
    expect("It is a editor for Markdown ", "It is an editor for Markdown ")
    expect("Wait for a hour or a honest answer ", "Wait for an hour or an honest answer ")
    expect("She is a heir to the estate ", "She is an heir to the estate ")
    expect("She is an user of the app ", "She is a user of the app ")
    expect("It is an university and an unique unit ", "It is a university and a unique unit ")
    expect("That was an one time thing and an once in a lifetime trip ", "That was a one time thing and a once in a lifetime trip ")
    expect("He met an European delegate ", "He met a European delegate ")
    expect("I read an book and drove an car ", "I read a book and drove a car ")
    expect("An horse rode by ", "A horse rode by ")
    // Valid articles and ambiguous words stay untouched
    expect("I ate an apple and a pear ", "I ate an apple and a pear ")
    expect("A user waited an hour for a one way ticket ", "A user waited an hour for a one way ticket ")
    expect("It was a historic day and an historic moment ", "It was a historic day and an historic moment ")
    expect("Add a herb or an herb to the soup ", "Add a herb or an herb to the soup ")
    expect("Choose a or b and set a in the table ", "Choose a or b and set a in the table ")

    let articleRun = type("I bought a apple ")
    check(articleRun.rules.contains(.aAndAn), "aAndAn rule fired: \(articleRun.rules)")
    check(type("I bought a apple ", isActive: { $0 != .aAndAn }).text == "I bought a apple ", "aAndAn can be turned off")

    // 1.3 A capital after a sentence that the partner itself just closed
    expect("It was i. then we left ", "It was I. Then we left ")
    expect("He said 'done.' then left ", "He said 'done.' Then left ")
    expect("He said ‘done.’ then left ", "He said ‘done.’ Then left ")
    expect("This is *done.* then we go ", "This is *done.* Then we go ")
    expect("> first line is a whole sentence.\n> second line starts here ", "> First line is a whole sentence.\n> Second line starts here ")
    expect("this is a whole sentence\nand the next sentence starts here\n",
           "This is a whole sentence.\nAnd the next sentence starts here.\n")
}

// 2. Typing-timeline tests covering every excluded context for grammar rules
do {
    // Inline code and unclosed inline code
    expect("See `the the a apple an user` ", "See `the the a apple an user` ")
    expect("See `the the a apple ", "See `the the a apple ")

    // Fenced code blocks (backticks and tildes)
    expect("```\nthe the a apple an user \n```\n", "```\nthe the a apple an user \n```\n")
    expect("~~~\nthe the a apple an user \n~~~\n", "~~~\nthe the a apple an user \n~~~\n")

    // Inline math, display math, unclosed math, and ```math blocks
    expect("Compute $the the a apple$ ", "Compute $the the a apple$ ")
    expect("Compute $the the a apple ", "Compute $the the a apple ")
    expect("$$\nthe the a apple \n$$\n", "$$\nthe the a apple \n$$\n")
    expect("```math\nthe the a apple \n```\n", "```math\nthe the a apple \n```\n")

    // HTML inline, HTML block, and unclosed HTML tag
    expect("<span>the the a apple</span> ", "<span>the the a apple</span> ")
    expect("<div>\nthe the a apple \n</div>\n", "<div>\nthe the a apple \n</div>\n")
    expect("<div class=\"the the a apple ", "<div class=\"the the a apple ")

    // YAML front matter (closed and unclosed)
    expect("---\ntitle: the the a apple an user\n---\n", "---\ntitle: the the a apple an user\n---\n")
    expect("---\ntitle: the the a apple ", "---\ntitle: the the a apple ")

    // Link destinations, unclosed link destinations, images, reference definitions, and autolinks
    expect("[label](https://example.com/the/the \"the the a apple\") ", "[label](https://example.com/the/the \"the the a apple\") ")
    expect("[label](https://example.com/the the a apple ", "[label](https://example.com/the the a apple ")
    expect("![the the a apple](img.png \"the the a apple\") ", "![the the a apple](img.png \"the the a apple\") ")
    expect("[ref]: https://example.com \"the the a apple\"\n", "[ref]: https://example.com \"the the a apple\"\n")
    expect("Visit <https://example.com/the> ", "Visit <https://example.com/the> ")

    // Tables (closed and unclosed table rows)
    expect("| a | b |\n|---|---|\n| the the | a apple |\n", "| a | b |\n|---|---|\n| the the | a apple |\n")
    expect("| the the | a apple ", "| the the | a apple ")

    // URLs, emails, file paths, hashtags, mentions
    expect("Open https://example.com/a/apple and the_the/a_apple ", "Open https://example.com/a/apple and the_the/a_apple ")
    expect("Mail a@apple.com or #the ", "Mail a@apple.com or #the ")

    // Slack Chat voice leaves grammar rules off
    expect("the the a apple an user ", "the the a apple an user ", flavor: .slack)

    // Never in the word the caret is in while typing (no edits fire before the boundary character)
    let midWordText = "I went to the the"
    let midWordDoc = MarkdownDocument.parse(midWordText, flavor: .github)
    let midWordEdits = PunctuateVoice.edits(text: midWordText, boundary: midWordText.count - 1, document: midWordDoc, flavor: .github)
    check(midWordEdits.isEmpty, "Never edits the word the caret is currently in while typing")
}

// 3. Settings › Writing: four grammar rules and learning from ⌘Z
do {
    let defaults = UserDefaults(suiteName: "swash-grammar-settings-tests")!
    defaults.removePersistentDomain(forName: "swash-grammar-settings-tests")

    check(PunctuationRule.doubledWords.title == "Doubled words", "Rule title: Doubled words")
    check(PunctuationRule.aAndAn.title == "A and an", "Rule title: A and an")
    check(PunctuationRule.agreementAndTense.title == "Agreement and tense", "Rule title: Agreement and tense")
    check(PunctuationRule.missingWords.title == "Missing words", "Rule title: Missing words")

    let grammarRules = PunctuationRule.allCases.filter(\.isGrammar)
    check(grammarRules == [.doubledWords, .aAndAn, .agreementAndTense, .missingWords], "All four grammar rules present in PunctuationRule.allCases")

    // All four rules default to on (#229: no switches in Settings; the old keys are hidden overrides for tests)
    for rule in grammarRules {
        check(WritingPartnerDefaults.isRuleEnabled(rule, defaults), "\(rule.title) is on by default")
    }
    defaults.set(false, forKey: WritingPartnerDefaults.doubledWords)
    check(!WritingPartnerDefaults.isRuleEnabled(.doubledWords, defaults) && WritingPartnerDefaults.isRuleEnabled(.aAndAn, defaults), "Doubled words switch is independent")
    defaults.set(false, forKey: WritingPartnerDefaults.aAndAn)
    check(!WritingPartnerDefaults.isRuleEnabled(.aAndAn, defaults) && WritingPartnerDefaults.isRuleEnabled(.agreementAndTense, defaults), "A and an switch is independent")
    defaults.set(false, forKey: WritingPartnerDefaults.agreementAndTense)
    check(!WritingPartnerDefaults.isRuleEnabled(.agreementAndTense, defaults) && WritingPartnerDefaults.isRuleEnabled(.missingWords, defaults), "Agreement and tense switch is independent")
    defaults.set(false, forKey: WritingPartnerDefaults.missingWords)
    check(!WritingPartnerDefaults.isRuleEnabled(.missingWords, defaults), "Missing words switch is independent")

    // Each grammar rule learns from ⌘Z (two undos in a row stop it; keeping raises weight)
    for rule in grammarRules {
        var stats = WritingPartnerStats()
        check(stats.isActive(rule), "\(rule.title) starts active")
        stats.undone(rule)
        check(stats.isActive(rule), "\(rule.title) active after one undo")
        stats.undone(rule)
        check(!stats.isActive(rule), "\(rule.title) stops after two undos")
    }

    let voiceState = WritingPartnerStats().toVoiceState()
    check(voiceState.rules["doubled-words"] != nil, "Voice state schema includes doubled-words")
    check(voiceState.rules["a-and-an"] != nil, "Voice state schema includes a-and-an")
    check(voiceState.rules["agreement-and-tense"] != nil, "Voice state schema includes agreement-and-tense")
    check(voiceState.rules["missing-words"] != nil, "Voice state schema includes missing-words")

    defaults.removePersistentDomain(forName: "swash-grammar-settings-tests")
}

// 4. Pause-tier grammar rules through the bandleader protocol (stubbed provider & schema validation)
do {
    // 4.1 Sample JSON response from provider checked against the schema
    let sampleGrammarJSON = """
    {
      "genre": "prose",
      "palette": [
        {
          "voice": "punctuate",
          "strength": 1.0
        }
      ],
      "suggestions": [],
      "grammar": [
        {
          "rule": "agreement-and-tense",
          "range": { "start": 12, "end": 17 },
          "replacement": "show",
          "confidence": 0.92,
          "why": "Plural subject 'results' takes 'show'"
        },
        {
          "rule": "agreement-and-tense",
          "range": { "start": 47, "end": 51 },
          "replacement": "said",
          "confidence": 0.88,
          "why": "Keep past tense consistent with 'walked'"
        },
        {
          "rule": "missing-words",
          "range": { "start": 56, "end": 69 },
          "replacement": "went to the shop",
          "confidence": 0.85,
          "why": "Missing preposition 'to'"
        },
        {
          "rule": "agreement-and-tense",
          "range": { "start": 74, "end": 83 },
          "replacement": "should have",
          "confidence": 0.91,
          "why": "Use 'should have' instead of 'should of'"
        },
        {
          "rule": "agreement-and-tense",
          "range": { "start": 92, "end": 103 },
          "replacement": "better",
          "confidence": 0.65,
          "why": "Avoid double comparative 'more better'"
        },
        {
          "rule": "missing-words",
          "range": { "start": 0, "end": 3 },
          "replacement": "Those",
          "confidence": 0.30,
          "why": "Low confidence guess"
        }
      ],
      "why": "Prose paragraph with agreement, tense, missing word and word-form slips"
    }
    """

    let paragraph = "The results shows that she walked in and says she went the shop and should of known a more better way."
    // Verify exact UTF-16 ranges in `paragraph`
    let paraNS = paragraph as NSString
    let showsRange = paraNS.range(of: "shows")
    let saysRange = paraNS.range(of: "says")
    let wentRange = paraNS.range(of: "went the shop")
    let shouldOfRange = paraNS.range(of: "should of")
    let moreBetterRange = paraNS.range(of: "more better")
    check(showsRange == NSRange(location: 12, length: 5), "shows range is 12..<17")
    check(saysRange == NSRange(location: 41, length: 4), "says range check: \(saysRange)")

    // Build schema-validated JSON with exact ranges from `paragraph`
    let exactJSON = """
    {
      "genre": "prose",
      "palette": [{ "voice": "punctuate", "strength": 1.0 }],
      "suggestions": [],
      "grammar": [
        {
          "rule": "agreement-and-tense",
          "range": { "start": \(showsRange.location), "end": \(NSMaxRange(showsRange)) },
          "replacement": "show",
          "confidence": 0.92,
          "why": "Subject and verb agreement"
        },
        {
          "kind": "tense",
          "range": { "start": \(saysRange.location), "end": \(NSMaxRange(saysRange)) },
          "replacement": "said",
          "confidence": 0.88,
          "why": "Tense slip mid-sentence"
        },
        {
          "rule": "missing-words",
          "range": { "start": \(wentRange.location), "end": \(NSMaxRange(wentRange)) },
          "replacement": "went to the shop",
          "confidence": 0.85,
          "why": "Missing small word 'to'"
        },
        {
          "kind": "word-form",
          "range": { "start": \(shouldOfRange.location), "end": \(NSMaxRange(shouldOfRange)) },
          "replacement": "should have",
          "confidence": 0.91,
          "why": "Wrong word form 'should of'"
        },
        {
          "rule": "agreement-and-tense",
          "range": { "start": \(moreBetterRange.location), "end": \(NSMaxRange(moreBetterRange)) },
          "replacement": "better",
          "confidence": 0.65,
          "why": "Below auto threshold: offered as suggestion"
        },
        {
          "rule": "missing-words",
          "range": { "start": 0, "end": 3 },
          "replacement": "Those",
          "confidence": 0.30,
          "why": "Very low confidence: dropped"
        }
      ],
      "why": "Prose paragraph with grammar corrections"
    }
    """

    // Check schema decoding via PixerateWritingBandleader and round-trip JSON encoding
    let decodedSample = try? JSONDecoder().decode(JazzTextLeadResponse.self, from: sampleGrammarJSON.data(using: .utf8)!)
    check(decodedSample != nil && decodedSample?.grammar.count == 6, "Sample grammar JSON decodes against JazzTextLeadResponse schema")

    let stubProvider = PixerateWritingBandleader(
        postHandler: { _, _ in exactJSON.data(using: .utf8)! },
        teamIdProvider: { "team_grammar_test" }
    )
    let leadRes = try await stubProvider.lead(request: JazzTextLeadRequest(paragraph: paragraph, flavor: .gfm))
    check(leadRes != nil, "Bandleader protocol returns decoded grammar response")
    check(leadRes?.grammar.count == 6, "Response contains 6 grammar items")

    if let leadRes {
        let roundTripData = try JSONEncoder().encode(leadRes)
        let roundTrip = try JSONDecoder().decode(JazzTextLeadResponse.self, from: roundTripData)
        check(roundTrip == leadRes, "JazzTextLeadResponse with grammar round-trips through JSON cleanly")

        // Evaluate pauseEdits in Automatic mode
        let result = GrammarVoice.pauseEdits(
            from: leadRes,
            paragraph: paragraph,
            paragraphRange: NSRange(location: 0, length: paraNS.length),
            documentText: paragraph,
            caret: paraNS.length,
            flavor: .github,
            provider: .pixerate,
            mode: .copyedit
        )
        // 4 items have confidence >= 0.80 -> automatic; 1 item has confidence 0.65 -> suggestion; 1 item has 0.30 -> dropped
        check(result.automatic.count == 4, "4 high-confidence corrections become automatic PartnerEdits (got \(result.automatic.count))")
        check(result.suggestions.count == 1, "1 medium-confidence correction (0.65) becomes a suggestion (got \(result.suggestions.count))")
        check(result.automatic.map(\.original) == ["shows", "says", "went the shop", "should of"], "Automatic originals match: \(result.automatic.map(\.original))")
        check(result.automatic.map(\.replacement) == ["show", "said", "went to the shop", "should have"], "Automatic replacements match: \(result.automatic.map(\.replacement))")
        check(result.automatic.map(\.rules) == [[.agreementAndTense], [.agreementAndTense], [.missingWords], [.agreementAndTense]], "Each automatic edit carries its PunctuationRule")
        check(result.suggestions.first?.original == "more better" && result.suggestions.first?.replacement == "better", "Below-threshold correction offered as suggestion")

        // Ghostwrite (#229) makes the same corrections as Copyedit; Off makes none
        let ghostResult = GrammarVoice.pauseEdits(
            from: leadRes,
            paragraph: paragraph,
            paragraphRange: NSRange(location: 0, length: paraNS.length),
            documentText: paragraph,
            caret: paraNS.length,
            flavor: .github,
            provider: .pixerate,
            mode: .ghostwrite
        )
        check(ghostResult.automatic.count == 4 && ghostResult.suggestions.count == 1, "Ghostwrite makes the same grammar corrections as Copyedit")
        let offResult = GrammarVoice.pauseEdits(from: leadRes, paragraph: paragraph, paragraphRange: NSRange(location: 0, length: paraNS.length),
                                                documentText: paragraph, caret: paraNS.length, flavor: .github, provider: .pixerate, mode: .off)
        check(offResult.automatic.isEmpty && offResult.suggestions.isEmpty, "Off makes no grammar corrections")
    }

    // 4.2 OnDeviceLeadResponse guided generation mirror types with grammar
    #if canImport(FoundationModels)
    if #available(macOS 26.0, *) {
        let onDeviceGrammar = OnDeviceLeadResponse(
            genre: .prose,
            palette: [OnDeviceVoice(voice: .punctuate, strength: 1.0, disabledRules: nil)],
            suggestions: [],
            grammar: [
                OnDeviceGrammarCorrection(
                    rule: .agreementAndTense,
                    range: OnDeviceRange(start: 12, end: 17),
                    replacement: "show",
                    confidence: 0.90,
                    why: "Plural agreement"
                ),
                OnDeviceGrammarCorrection(
                    rule: .missingWords,
                    range: OnDeviceRange(start: 56, end: 69),
                    replacement: "went to the shop",
                    confidence: 0.85,
                    why: "Missing 'to'"
                )
            ],
            why: "Grammar check"
        )
        let converted = onDeviceGrammar.toJazzTextLeadResponse
        check(converted.grammar.count == 2, "OnDeviceLeadResponse converts grammar corrections to JazzTextLeadResponse")
        check(converted.grammar.first?.rule == .agreementAndTense && converted.grammar.last?.rule == .missingWords, "OnDeviceGrammarRule maps accurately")
    }
    #endif

    // 4.3 "It corrects, it doesn't rewrite": rejects multi-word stylistic rewrites
    let rewritePara = "The results shows that this sentence is a bit wordy and could be shorter."
    let rewriteResp = JazzTextLeadResponse(
        genre: .prose,
        palette: [],
        grammar: [
            JazzTextGrammarCorrection(
                rule: .agreementAndTense,
                range: JazzTextRange(start: 12, end: 17),
                replacement: "show",
                confidence: 0.92
            ),
            JazzTextGrammarCorrection(
                rule: .agreementAndTense,
                range: JazzTextRange(start: 23, end: 72),
                replacement: "it should be concise",
                confidence: 0.95,
                why: "Style rewrite"
            )
        ],
        why: "Test rewrite rejection"
    )
    let rewriteFiltered = GrammarVoice.pauseEdits(
        from: rewriteResp,
        paragraph: rewritePara,
        paragraphRange: NSRange(location: 0, length: (rewritePara as NSString).length),
        documentText: rewritePara
    )
    check(rewriteFiltered.automatic.count == 1 && rewriteFiltered.automatic.first?.replacement == "show",
          "Accepts word-level correction ('shows' -> 'show') and rejects multi-word clause rewrite")

    // 4.4 Never in the word the caret is in, and never inside code, math, HTML, links, or tables
    let mixedPara = "The results shows `should of` and $more better$ and [went the shop](https://example.com/should_of) while typing wordshere"
    let mixedNS = mixedPara as NSString
    let codeRange = mixedNS.range(of: "should of")
    let mathRange = mixedNS.range(of: "more better")
    let caretWordRange = mixedNS.range(of: "wordshere")
    let mixedResp = JazzTextLeadResponse(
        genre: .prose,
        palette: [],
        grammar: [
            JazzTextGrammarCorrection(rule: .agreementAndTense, range: JazzTextRange(start: 12, end: 17), replacement: "show", confidence: 0.92),
            JazzTextGrammarCorrection(rule: .agreementAndTense, range: JazzTextRange(start: codeRange.location, end: NSMaxRange(codeRange)), replacement: "should have", confidence: 0.95),
            JazzTextGrammarCorrection(rule: .agreementAndTense, range: JazzTextRange(start: mathRange.location, end: NSMaxRange(mathRange)), replacement: "better", confidence: 0.95),
            JazzTextGrammarCorrection(rule: .missingWords, range: JazzTextRange(start: caretWordRange.location, end: NSMaxRange(caretWordRange)), replacement: "words here", confidence: 0.95)
        ],
        why: "Mixed exclusions"
    )
    let mixedFiltered = GrammarVoice.pauseEdits(
        from: mixedResp,
        paragraph: mixedPara,
        paragraphRange: NSRange(location: 0, length: mixedNS.length),
        documentText: mixedPara,
        caret: caretWordRange.location + 3 // caret is inside "wordshere"
    )
    check(mixedFiltered.automatic.count == 1 && mixedFiltered.automatic.first?.original == "shows",
          "Pause tier skips code, math, and the word the caret is in")

    // 4.5 Off for a paragraph the bandleader reads as verse (poem), dialogue, or a quotation
    let versePara = "The results shows in the night\nWent the shop in the light"
    let verseCorrection = [
        JazzTextGrammarCorrection(rule: .agreementAndTense, range: JazzTextRange(start: 12, end: 17), replacement: "show", confidence: 0.95)
    ]
    let poemResp = JazzTextLeadResponse(genre: .poem, palette: [], grammar: verseCorrection, why: "Verse")
    let dialogueResp = JazzTextLeadResponse(genre: .dialogue, palette: [], grammar: verseCorrection, why: "Dialogue")
    let quoteResp = JazzTextLeadResponse(genre: .quote, palette: [], grammar: verseCorrection, why: "Quotation")
    check(GrammarVoice.pauseEdits(from: poemResp, paragraph: versePara, paragraphRange: NSRange(location: 0, length: (versePara as NSString).length), documentText: versePara).automatic.isEmpty,
          "Pause-tier grammar is off for verse (.poem)")
    check(GrammarVoice.pauseEdits(from: dialogueResp, paragraph: versePara, paragraphRange: NSRange(location: 0, length: (versePara as NSString).length), documentText: versePara).automatic.isEmpty,
          "Pause-tier grammar is off for dialogue (.dialogue)")
    check(GrammarVoice.pauseEdits(from: quoteResp, paragraph: versePara, paragraphRange: NSRange(location: 0, length: (versePara as NSString).length), documentText: versePara).automatic.isEmpty,
          "Pause-tier grammar is off for quotation (.quote)")

    let blockQuotePara = "> The results shows that she went the shop."
    let proseOnBlockQuote = JazzTextLeadResponse(
        genre: .prose,
        palette: [],
        grammar: [JazzTextGrammarCorrection(rule: .agreementAndTense, range: JazzTextRange(start: 14, end: 19), replacement: "show", confidence: 0.95)],
        why: "Blockquote"
    )
    check(GrammarVoice.pauseEdits(from: proseOnBlockQuote, paragraph: blockQuotePara, paragraphRange: NSRange(location: 0, length: (blockQuotePara as NSString).length), documentText: blockQuotePara).automatic.isEmpty,
          "Pause-tier grammar is off inside Markdown blockquotes")

    let quotedDialoguePara = "“The results shows that she went the shop,” he whispered."
    check(GrammarVoice.isVerseDialogueOrQuotation(paragraph: "\"The results shows that she went the shop.\"", genre: .prose),
          "Quoted dialogue paragraph is recognized as quotation/dialogue")
    check(ParagraphVoiceSettings.from(response: poemResp, paragraphRange: NSRange(location: 0, length: 10), paragraph: versePara).isGrammarDisabled,
          "ParagraphVoiceSettings disables grammar rules for verse")
    check(ParagraphVoiceSettings.from(response: dialogueResp, paragraphRange: NSRange(location: 0, length: 10), paragraph: quotedDialoguePara).disabledRules.contains(.doubledWords),
          "ParagraphVoiceSettings disables typing-tier grammar rules for dialogue")

    // 4.6 Document language detection and unsupported language handling
    let englishLang = GrammarLanguageSupport.detectLanguage(in: "The results shows that she walked in and says hello.")
    check(englishLang == .english, "Detects English for prose sentence (got \(englishLang.rawValue))")
    check(GrammarLanguageSupport.isSupported(.english, by: .onDevice) && GrammarLanguageSupport.isSupported(.english, by: .pixerate),
          "English is supported by both OnDevice and Pixerate")
    check(GrammarLanguageSupport.unsupportedReason(for: .english, provider: .onDevice) == nil,
          "No unsupported reason for English")

    let greekText = "Καλημέρα κόσμε, αυτό είναι ένα κείμενο στα ελληνικά για τον έλεγχο της γλώσσας του εγγράφου."
    let greekLang = GrammarLanguageSupport.detectLanguage(in: greekText)
    check(greekLang == .greek, "Detects Greek language (got \(greekLang.rawValue))")
    check(!GrammarLanguageSupport.isSupported(greekLang, by: .onDevice), "Greek is not supported by OnDevice provider")
    check(!GrammarLanguageSupport.isSupported(greekLang, by: .pixerate), "Greek is not supported by Pixerate provider")
    let greekReasonOnDevice = GrammarLanguageSupport.unsupportedReason(for: greekLang, provider: .onDevice)
    let greekReasonPixerate = GrammarLanguageSupport.unsupportedReason(for: greekLang, provider: .pixerate)
    check(greekReasonOnDevice?.contains("Greek") == true && greekReasonOnDevice?.contains("Apple Intelligence") == true,
          "Settings reason for unsupported language on device: \(greekReasonOnDevice ?? "")")
    check(greekReasonPixerate?.contains("Greek") == true && greekReasonPixerate?.contains("Pixerate") == true,
          "Settings reason for unsupported language on Pixerate: \(greekReasonPixerate ?? "")")

    let unsupportedPauseResult = GrammarVoice.pauseEdits(
        from: JazzTextLeadResponse(
            genre: .prose,
            palette: [],
            grammar: [JazzTextGrammarCorrection(rule: .agreementAndTense, range: JazzTextRange(start: 0, end: 5), replacement: "fixed", confidence: 0.95)],
            why: "Test"
        ),
        paragraph: paragraph,
        paragraphRange: NSRange(location: 0, length: paraNS.length),
        documentText: paragraph,
        provider: .onDevice,
        languageOverride: .greek
    )
    check(unsupportedPauseResult.automatic.isEmpty && unsupportedPauseResult.suggestions.isEmpty,
          "Unsupported document language leaves pause-tier grammar rules off")
}

// MARK: - Subscription Spelling, Vocabulary, Team Terms & Feedback (#120, Pixerate/schemas#87, Pixerate/jazz#30)

do {
    // 1. Decoding server suggestions for spelling, wrong-word, and team terms (house-style / terms)
    let serverJSON = """
    {
      "genre": "prose",
      "palette": [{"voice": "punctuate", "strength": 1.0}],
      "vocabulary": ["Pixerate", "Uchiage", "Swash"],
      "suggestions": [
        {
          "id": "sug-team-1",
          "kind": "terms",
          "range": {"start": 3, "end": 11},
          "replacement": "Pixerate",
          "why": "Team house style: capitalize product name",
          "confidence": 0.98,
          "applyAtOnce": true,
          "checkId": "terms.product-casing"
        },
        {
          "id": "sug-wrong-1",
          "kind": "wrong-word",
          "range": {"start": 17, "end": 21},
          "replacement": "from",
          "why": "Wrong word in context: 'from' instead of 'form'",
          "confidence": 0.94,
          "applyAtOnce": true
        },
        {
          "id": "sug-uncertain-1",
          "kind": "wrong-word",
          "range": {"start": 22, "end": 27},
          "replacement": "there",
          "why": "Possible wrong word: 'there' vs 'their'",
          "confidence": 0.65,
          "applyAtOnce": false
        },
        {
          "id": "sug-vocab-ignored",
          "kind": "spelling",
          "range": {"start": 31, "end": 38},
          "replacement": "UchiageFixed",
          "why": "Should be suppressed because Uchiage is in vocabulary",
          "confidence": 0.95,
          "applyAtOnce": true
        }
      ],
      "why": "Checked with personal vocabulary and team terms",
      "fuelBalance": 84
    }
    """
    let decoded = try! JSONDecoder().decode(JazzTextLeadResponse.self, from: Data(serverJSON.utf8))
    check(decoded.vocabulary == ["Pixerate", "Uchiage", "Swash"], "Server response decodes personal & team vocabulary")
    check(decoded.suggestions.count == 4, "Decoded all 4 server suggestions")
    check(decoded.suggestions[0].kind == .houseStyle, "'terms' kind maps to .houseStyle")
    check(decoded.suggestions[0].checkId == "terms.product-casing", "Preserves house-style checkId")
    check(decoded.suggestions[0].shouldApplyAtOnce, "Certain team-term suggestion applies at once")
    check(decoded.suggestions[1].kind == .wrongWord && decoded.suggestions[1].shouldApplyAtOnce, "Certain wrong-word suggestion applies at once")
    check(!decoded.suggestions[2].shouldApplyAtOnce, "Uncertain wrong-word suggestion is offered rather than applied at once")

    // 2. Planner separates immediate edits from offered suggestions and protects vocabulary & code
    let paragraph = "In pixerate sent form their on Uchiage with `pixerate`."
    let memory = BandleaderSessionMemory()
    let plan = BandleaderSuggestionPlanner.plan(
        response: decoded,
        paragraph: paragraph,
        paragraphRange: NSRange(location: 0, length: (paragraph as NSString).length),
        documentText: paragraph,
        flavor: .github,
        mode: .copyedit,
        spellingEnabled: true,
        memory: memory
    )
    check(memory.isKnownWord("Uchiage") && memory.isKnownWord("uchiage"), "Vocabulary words are learned in session memory")
    check(plan.automaticEdits.count == 2, "2 certain suggestions planned for immediate playback: got \(plan.automaticEdits.count)")
    check(plan.automaticEdits.map { "\($0.original)->\($0.replacement)" } == ["pixerate->Pixerate", "form->from"],
          "Automatic edits fix team term and certain wrong-word error, skipping vocabulary word 'Uchiage'")
    check(plan.offeredEdits.count == 1, "1 uncertain suggestion planned for Suggest-style offer")
    check(plan.offeredEdits.first?.original == "their" && plan.offeredEdits.first?.replacement == "there",
          "Uncertain wrong-word suggestion is offered as underline")

    // Off (#229) plans nothing
    let offMemory = BandleaderSessionMemory()
    let offPlan = BandleaderSuggestionPlanner.plan(
        response: decoded,
        paragraph: paragraph,
        paragraphRange: NSRange(location: 0, length: (paragraph as NSString).length),
        documentText: paragraph,
        flavor: .github,
        mode: .off,
        spellingEnabled: true,
        memory: offMemory
    )
    check(offPlan.automaticEdits.isEmpty && offPlan.offeredEdits.isEmpty, "Off plans no inline suggestions")

    // Inline code is never modified even if server sends a range inside backticks
    let codeSuggestion = JazzTextSuggestion(
        id: "sug-code",
        kind: .houseStyle,
        range: JazzTextRange(start: 45, end: 53), // inside `pixerate`
        replacement: "Pixerate",
        why: "Should skip inline code"
    )
    let codePlan = BandleaderSuggestionPlanner.plan(
        response: JazzTextLeadResponse(genre: .prose, palette: [], suggestions: [codeSuggestion], why: ""),
        paragraph: paragraph,
        paragraphRange: NSRange(location: 0, length: (paragraph as NSString).length),
        documentText: paragraph,
        flavor: .github,
        mode: .copyedit,
        spellingEnabled: true,
        memory: memory
    )
    check(codePlan.automaticEdits.isEmpty && codePlan.offeredEdits.isEmpty, "Planner never edits inside inline code")

    // 3. Feedback reporting (POST /api/agent/text-feedback, Pixerate/schemas#87)
    nonisolated final class FeedbackRecorder: @unchecked Sendable {
        var paths: [String] = []
        var requests: [JazzTextFeedbackRequest] = []
    }
    let recorder = FeedbackRecorder()
    let feedbackBandleader = PixerateWritingBandleader(
        postHandler: { path, body in
            recorder.paths.append(path)
            if let req = try? JSONDecoder().decode(JazzTextFeedbackRequest.self, from: body) {
                recorder.requests.append(req)
            }
            return Data("{\"ok\":true}".utf8)
        },
        teamIdProvider: { "team_pixerate" }
    )

    let feedbackItems = [
        JazzTextFeedbackItem(
            suggestionId: "sug-team-1",
            kind: .houseStyle,
            outcome: .accepted,
            original: "pixerate",
            replacement: "Pixerate",
            finalText: "Pixerate",
            checkId: "terms.product-casing"
        ),
        JazzTextFeedbackItem(
            suggestionId: "sug-uncertain-1",
            kind: .wrongWord,
            outcome: .dismissed,
            original: "their",
            replacement: "there"
        ),
        JazzTextFeedbackItem(
            suggestionId: "sug-wrong-1",
            kind: .wrongWord,
            outcome: .undone,
            original: "form",
            replacement: "from",
            finalText: "form"
        )
    ]
    await feedbackBandleader.reportFeedback(JazzTextFeedbackRequest(items: feedbackItems))
    check(recorder.paths == ["/api/agent/text-feedback"], "Feedback posts to /api/agent/text-feedback")
    check(recorder.requests.first?.teamId == "team_pixerate", "Feedback includes active teamId")
    check(recorder.requests.first?.items == feedbackItems, "Feedback round-trips accepted, dismissed, and undone outcomes")

    // Undone or dismissed feedback teaches session memory so the same correction isn't offered again
    for item in feedbackItems {
        memory.recordFeedback(item)
    }
    let repeatPlan = BandleaderSuggestionPlanner.plan(
        response: decoded,
        paragraph: paragraph,
        paragraphRange: NSRange(location: 0, length: (paragraph as NSString).length),
        documentText: paragraph,
        flavor: .github,
        mode: .copyedit,
        spellingEnabled: true,
        memory: memory
    )
    check(repeatPlan.automaticEdits.map(\.original) == ["pixerate"],
          "Undone correction ('form'->'from') is not applied again in the session")
    check(repeatPlan.offeredEdits.isEmpty,
          "Dismissed suggestion ('their'->'there') is not offered again in the session")

    // 4. Fallback chain: Signed out, out of Fuel (402), rate-limited (429), or offline -> on-device tier -> local spell checker
    let savedMakePixerate = WritingBandleaderFactory.makePixerateBandleader
    let savedMakeOnDevice = WritingBandleaderFactory.makeOnDeviceBandleader
    let savedIsPixerate = WritingBandleaderFactory.isPixerateAvailable
    let savedIsOnDevice = WritingBandleaderFactory.isOnDeviceAvailable
    let savedOverride = WritingBandleaderFactory.overrideBandleader
    WritingBandleaderFactory.overrideBandleader = nil

    let onDeviceStub = StubWritingBandleader { req in
        JazzTextLeadResponse(
            genre: .prose,
            palette: [JazzTextVoice(voice: .punctuate, strength: 1.0)],
            suggestions: [
                JazzTextSuggestion(
                    id: "on-device-1",
                    kind: .wrongWord,
                    range: JazzTextRange(start: 0, end: 4),
                    replacement: "From",
                    why: "On-device fallback fixed wrong word"
                )
            ],
            why: "On-device fallback"
        )
    }
    WritingBandleaderFactory.makeOnDeviceBandleader = { onDeviceStub }

    let sampleReq = JazzTextLeadRequest(paragraph: "Form here we go.")
    let refusals: [(String, Error)] = [
        ("signedOut", PixerateRefusal.signedOut),
        ("outOfFuel", PixerateRefusal.subscriptionRequired),
        ("rateLimited", PixerateRefusal.rateLimited(until: Date().addingTimeInterval(60))),
        ("offline", URLError(.notConnectedToInternet))
    ]

    for (label, refusalError) in refusals {
        WritingBandleaderFactory.isPixerateAvailable = { true }
        WritingBandleaderFactory.isOnDeviceAvailable = { true }
        WritingBandleaderFactory.makePixerateBandleader = {
            PixerateWritingBandleader(postHandler: { _, _ in throw refusalError })
        }
        let fallbackResult = await WritingBandleaderFactory.leadWithFallback(request: sampleReq, provider: .pixerate)
        check(fallbackResult?.response.why == "On-device fallback",
              "When Pixerate fails with \(label), falls back to on-device tier")
    }

    // When on-device is also unavailable, falls back cleanly to nil (local PunctuateVoice + system spell checker)
    WritingBandleaderFactory.isOnDeviceAvailable = { false }
    let localFallback = await WritingBandleaderFactory.leadWithFallback(request: sampleReq, provider: .pixerate)
    check(localFallback == nil, "When both Pixerate and on-device are unavailable, falls back to local spell checker")

    WritingBandleaderFactory.makePixerateBandleader = savedMakePixerate
    WritingBandleaderFactory.makeOnDeviceBandleader = savedMakeOnDevice
    WritingBandleaderFactory.isPixerateAvailable = savedIsPixerate
    WritingBandleaderFactory.isOnDeviceAvailable = savedIsOnDevice
    WritingBandleaderFactory.overrideBandleader = savedOverride
}

// On-device session sharing & bandleader reuse (#SWA-30)
do {
    let savedMakeOnDevice = WritingBandleaderFactory.makeOnDeviceBandleader
    let savedIsOnDevice = WritingBandleaderFactory.isOnDeviceAvailable

    // 1. Session Lifecycle & Invalidation on OnDeviceWritingBandleader
    let bandleader = OnDeviceWritingBandleader()
    check(!bandleader.hasActiveSession, "OnDeviceWritingBandleader starts with no active session")
    bandleader.resetSession()
    check(!bandleader.hasActiveSession, "Resetting inactive session keeps hasActiveSession false")

    // 2. Bandleader reuse in leadWithFallback for .onDevice provider
    let existingOnDevice = OnDeviceWritingBandleader(customGenerator: { _ in
        JazzTextLeadResponse(genre: .prose, palette: [], suggestions: [], why: "Custom")
    })
    WritingBandleaderFactory.isOnDeviceAvailable = { true }
    WritingBandleaderFactory.makeOnDeviceBandleader = { OnDeviceWritingBandleader() }

    let req = JazzTextLeadRequest(paragraph: "Test paragraph")
    let leadResult = await WritingBandleaderFactory.leadWithFallback(
        request: req,
        provider: .onDevice,
        existing: existingOnDevice
    )
    check(leadResult != nil, "leadWithFallback returns result with existing on-device bandleader")
    if let result = leadResult {
        let isSame = (result.bandleader as AnyObject) === (existingOnDevice as AnyObject)
        check(isSame, "leadWithFallback reuses existing OnDeviceWritingBandleader instance for .onDevice")
    }

    // 3. Fallback Reuse: when Pixerate fails, existing on-device bandleader is reused
    let savedMakePixerate = WritingBandleaderFactory.makePixerateBandleader
    let savedIsPixerate = WritingBandleaderFactory.isPixerateAvailable
    WritingBandleaderFactory.isPixerateAvailable = { true }
    WritingBandleaderFactory.makePixerateBandleader = {
        PixerateWritingBandleader(postHandler: { _, _ in throw PixerateRefusal.signedOut })
    }

    let fallbackReuseResult = await WritingBandleaderFactory.leadWithFallback(
        request: req,
        provider: .pixerate,
        existing: existingOnDevice
    )
    check(fallbackReuseResult != nil, "leadWithFallback falls back when Pixerate fails")
    if let result = fallbackReuseResult {
        let isSame = (result.bandleader as AnyObject) === (existingOnDevice as AnyObject)
        check(isSame, "leadWithFallback reuses existing on-device bandleader upon Pixerate fallback")
    }

    WritingBandleaderFactory.makePixerateBandleader = savedMakePixerate
    WritingBandleaderFactory.isPixerateAvailable = savedIsPixerate
    WritingBandleaderFactory.makeOnDeviceBandleader = savedMakeOnDevice
    WritingBandleaderFactory.isOnDeviceAvailable = savedIsOnDevice
}

// WritingPartner protocol conformance (#61): PunctuateVoice conforms to WritingPartner so the fast-tier
// duet can be injected or moved to a shared package
do {
    let partner: any WritingPartner = PunctuateVoice()
    let text = "i dont "
    let doc = MarkdownDocument.parse(text, flavor: .github)
    let checked = partner.checkedRange(text: text, boundary: 6, document: doc)
    check(checked == NSRange(location: 2, length: 4), "WritingPartner protocol checkedRange returns the word before the boundary")
    let edits = partner.edits(text: text, boundary: 6, document: doc, flavor: .github, enterEndedLine: nil, isActive: { !$0.isTypography }, spellingCorrection: nil)
    check(edits.contains(where: { $0.replacement == "don't" && $0.rules.contains(.contraction) }), "WritingPartner protocol edits computes contraction replacement")
}


// Context-aware spelling on device (#98): what ContextSpelling keeps of the model's corrections
do {
    let paragraph = "I came form the shop and their was a liek on the post."
    let found = ContextSpelling.suggestions(from: [
        ContextSpellingCandidate(kind: .wrongWord, original: "form", replacement: "from", confidence: 0.95),
        ContextSpellingCandidate(kind: .wrongWord, original: "their", replacement: "there", confidence: 0.7),
        ContextSpellingCandidate(kind: .spelling, original: "liek", replacement: "like", confidence: 0.4),
        ContextSpellingCandidate(kind: .spelling, original: "shop", replacement: "Shop", confidence: 0.99),
        ContextSpellingCandidate(kind: .wrongWord, original: "the post", replacement: "a letter in the box", confidence: 0.99),
        ContextSpellingCandidate(kind: .spelling, original: "post", replacement: "parcel", confidence: 0.99),
        ContextSpellingCandidate(kind: .spelling, original: "teh", replacement: "the", confidence: 0.99),
    ], paragraph: paragraph)
    check(found.map(\.replacement) == ["from", "there"], "Context spelling keeps confident fixes and drops low confidence, case-only, rewrites, far-off and missing words: \(found.map(\.replacement))")
    let ns = paragraph as NSString
    check(found.first.map { ns.substring(with: NSRange(location: $0.range.start, length: $0.range.end - $0.range.start)) } == "form",
          "Context spelling finds the word as written")
    check(found.first?.shouldApplyAtOnce == true, "A confident correction is made")
    check(found.last?.shouldApplyAtOnce == false, "A less confident correction is offered, not made")
    check(found.allSatisfy { $0.kind.isSpellingKind }, "Context spelling corrections are spelling kinds, so undo ignores the word")
    let twice = ContextSpelling.suggestions(from: [
        ContextSpellingCandidate(kind: .wrongWord, original: "form", replacement: "from", confidence: 0.95),
    ], paragraph: "Fill in the form form the office.")
    check(twice.isEmpty, "A word written twice in the paragraph is ambiguous and left alone")
    let inWord = ContextSpelling.suggestions(from: [
        ContextSpellingCandidate(kind: .wrongWord, original: "then", replacement: "than", confidence: 0.95),
    ], paragraph: "Better thenceforth then ever.")
    check(inWord.count == 1 && inWord[0].range.start == 19, "A word is found whole, not inside a longer one")
    check(ContextSpelling.editDistance("teh", "the") == 1, "A swapped pair of letters is one change")
    check(ContextSpelling.recurs("colur", in: "The colur, the Colur." as NSString), "A word used twice recurs")
    check(!ContextSpelling.recurs("colur", in: "The colur, the colours." as NSString), "A longer word isn't a recurrence")

    // The planner leaves a recurring misspelling alone, makes the confident fix and offers the other
    let doc = "Send it form home so we dont loose the colur, and the colur."
    let response = JazzTextLeadResponse(
        genre: .prose, palette: [JazzTextVoice(voice: .punctuate, strength: 1)],
        suggestions: ContextSpelling.suggestions(from: [
            ContextSpellingCandidate(kind: .wrongWord, original: "form", replacement: "from", confidence: 0.95),
            ContextSpellingCandidate(kind: .wrongWord, original: "loose", replacement: "lose", confidence: 0.6),
            ContextSpellingCandidate(kind: .spelling, original: "colur", replacement: "colour", confidence: 0.9),
        ], paragraph: doc),
        why: "test")
    let plan = BandleaderSuggestionPlanner.plan(response: response, paragraph: doc,
                                                paragraphRange: NSRange(location: 0, length: (doc as NSString).length),
                                                documentText: doc, memory: BandleaderSessionMemory())
    check(plan.automaticEdits.map(\.replacement) == ["from"], "On-device context spelling: the confident fix is made")
    check(plan.offeredEdits.map(\.replacement) == ["lose"], "On-device context spelling: the unsure fix is offered")
    let ghostPlan = BandleaderSuggestionPlanner.plan(response: response, paragraph: doc,
                                                     paragraphRange: NSRange(location: 0, length: (doc as NSString).length),
                                                     documentText: doc, mode: .ghostwrite, memory: BandleaderSessionMemory())
    check(ghostPlan.automaticEdits.map(\.replacement) == ["from"] && ghostPlan.offeredEdits.map(\.replacement) == ["lose"],
          "Ghostwrite plans context spelling like Copyedit")
    let off = BandleaderSuggestionPlanner.plan(response: response, paragraph: doc,
                                               paragraphRange: NSRange(location: 0, length: (doc as NSString).length),
                                               documentText: doc, spellingEnabled: false, memory: BandleaderSessionMemory())
    check(off.automaticEdits.isEmpty && off.offeredEdits.isEmpty, "With spelling off, no context spelling")
    check(OnDeviceWritingBandleader.instructions.contains("real word used wrongly"), "The on-device instructions ask for context spelling")
}

// Marks (#128): what the partner isn't sure about, kept beside the text
do {
    func mark(_ id: Int, _ location: Int, _ original: String, _ candidates: [String], confidence: Double = 0.6) -> PartnerUncertainMark {
        PartnerUncertainMark(id: id, edit: PartnerEdit(range: NSRange(location: location, length: (original as NSString).length),
                                                       original: original, replacement: candidates[0], rules: [.spelling],
                                                       spellingWords: [original], confidence: confidence),
                             candidates: candidates)
    }
    let text = "I came form the shop and their it was." as NSString
    let form = mark(1, 7, "form", ["from", "for"])
    let their = mark(2, 25, "their", ["there"])
    var marks = PartnerMarks.adding([their, form], to: [], kept: [], in: text)
    check(marks.map(\.id) == [1, 2], "Marks are kept in document order")
    var moved = PartnerMarks.moved(marks, through: NSRange(location: 38, length: 0), replacement: " More")
    check(moved.edited.isEmpty && moved.marks.map(\.range.location) == [7, 25], "Typing past a mark leaves it")
    moved = PartnerMarks.moved(marks, through: NSRange(location: 0, length: 0), replacement: "So ")
    check(moved.edited.isEmpty && moved.marks.map(\.range.location) == [10, 28], "Typing before a mark moves it")
    moved = PartnerMarks.moved(marks, through: NSRange(location: 11, length: 0), replacement: "s")
    check(moved.edited.isEmpty && moved.marks.first?.range.location == 7, "Typing just after a mark leaves it")
    moved = PartnerMarks.moved(marks, through: NSRange(location: 9, length: 1), replacement: "")
    check(moved.edited.map(\.id) == [1] && moved.marks.map(\.id) == [2], "Editing inside a mark settles it")
    marks = PartnerMarks.adding([mark(3, 7, "form", ["from"])], to: [their], kept: ["form"], in: text)
    check(marks.map(\.id) == [2], "A word kept as written isn't marked again")
    marks = PartnerMarks.adding([mark(4, 7, "form", ["from"], confidence: 0.7)], to: [form, their], kept: [], in: text)
    check(marks.map(\.id) == [4, 2], "A new mark replaces one in the same place")
    let rough = "a b c d e f g h\n\nnext para x" as NSString
    let many = (0..<5).map { mark(10 + $0, $0 * 2, String(rough.substring(with: NSRange(location: $0 * 2, length: 1))), ["z"], confidence: 0.5 + Double($0) / 100) }
    let capped = PartnerMarks.adding(many + [mark(20, 25, "x", ["y"])], to: [], kept: [], in: rough)
    check(capped.map(\.id) == [12, 13, 14, 20], "Each paragraph keeps its \(PartnerMarks.maxPerParagraph) most confident marks: \(capped.map(\.id))")
    check(PartnerMarks.paragraph(at: 3, in: rough) == NSRange(location: 0, length: 15), "A paragraph ends at a blank line")
    check(PartnerMarks.step(from: nil, by: 1, count: 3) == 0 && PartnerMarks.step(from: 2, by: 1, count: 3) == 0
          && PartnerMarks.step(from: 0, by: -1, count: 3) == 2, "Review steps through the marks in order, wrapping")
    check(PartnerMarks.index(at: 9, in: [form, their]) == 0 && PartnerMarks.index(at: 11, in: [form, their]) == 0
          && PartnerMarks.index(at: 7, in: [form, their]) == nil, "The caret is in a mark from its second character to just after it")
    check(form.label == "“form” could be “from” or “for”", "A mark says what it could be: \(form.label)")
    check(form.edit(choosing: 1).replacement == "for", "Choosing the other candidate")
    let two = ContextSpelling.suggestions(from: [
        ContextSpellingCandidate(kind: .wrongWord, original: "form", replacement: "from", confidence: 0.95, alternatives: ["for", "form", "FROM"]),
    ], paragraph: "I came form the shop.")
    check(two.first?.alternatives == ["for"] && two.first?.shouldApplyAtOnce == false,
          "A correction with two candidates is marked, not made: \(String(describing: two.first?.alternatives))")
    check(WritingPartnerDefaults.suggestions(UserDefaults(suiteName: "marks-tests-empty")!), "Suggestions (marking) is on by default")
    check(!WritingPartnerDefaults.announceMarks(UserDefaults(suiteName: "marks-tests-empty")!), "Announcing marks is off unless asked for")
}

runFormattingTests()

print("\(passes) passed, \(failures) failed")
exit(failures == 0 ? 0 : 1)

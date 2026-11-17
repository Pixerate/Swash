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
    check(WritingPartnerDefaults.mode(defaults) == .off, "off by default")
    defaults.set(WritingPartnerMode.suggest.rawValue, forKey: WritingPartnerDefaults.mode)
    check(WritingPartnerDefaults.mode(defaults) == .suggest && WritingPartnerMode.suggest.title == "Suggest", "suggest mode round-trip")
    check(WritingPartnerMode.allCases.map(\.title) == ["Off", "Suggest", "Automatically"], "mode titles")
    check(WritingPartnerDefaults.spelling(defaults), "spelling on by default")
    defaults.set(false, forKey: WritingPartnerDefaults.spelling)
    check(!WritingPartnerDefaults.spelling(defaults), "an explicit choice wins")
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
    defaults.removePersistentDomain(forName: "swash-quick-note-tidy-tests")
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

print("\(passes) passed, \(failures) failed")
exit(failures == 0 ? 0 : 1)

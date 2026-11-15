// Types text character by character through the Punctuate voice (Swash/WritingPartner.swift, #61)
// and checks the fixes it makes. Run with scripts/run_writing_partner_tests.sh.

import Foundation
import PixerateMarkdown

print("Starting writing partner tests...")

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

// Slack: the chat voice keeps capitals and full stops out of it
expect("ok so i dont know\n\n", "ok so I don't know\n\n", flavor: .slack)

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

print("Punctuate tests finished. Moving to bandleader tests...")

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
    final class Sent: @unchecked Sendable { var path: String?; var body: Data? }
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
print("Testing Pause detection...")
do {
    var currentTime = Date(timeIntervalSince1970: 1000)
    let detector = WritingPauseDetector(pauseDelay: 1.2, clock: { currentTime })

    // Initially, nothing pending
    check(detector.checkPause() == nil, "No pause on clean state")

    // Typing 'a' (no sentence end)
    detector.noteTyping(character: unichar(0x61), paragraph: "Hello world a", range: NSRange(location: 0, length: 13), caret: 13)
    check(!detector.isScheduled, "No pause scheduled after typing normal character 'a'")

    // Typing '.' (sentence end)
    detector.noteTyping(character: 0x2E, paragraph: "Hello world a.", range: NSRange(location: 0, length: 14), caret: 14)
    check(detector.isScheduled, "Pause is scheduled after typing period")

    // Advancing time before delay elapsed
    currentTime = currentTime.addingTimeInterval(0.5)
    check(detector.checkPause() == nil, "No pause before 1.2s delay elapsed")

    // Typing 'b' keeps advancing deadline (backoff/debouncing)
    detector.noteTyping(character: unichar(0x62), paragraph: "Hello world a. b", range: NSRange(location: 0, length: 16), caret: 16)
    currentTime = currentTime.addingTimeInterval(0.8)
    check(detector.checkPause() == nil, "No pause while person keeps typing within backoff window")

    // Typing '!' (sentence end)
    detector.noteTyping(character: 0x21, paragraph: "Hello world a. b!", range: NSRange(location: 0, length: 17), caret: 17)
    currentTime = currentTime.addingTimeInterval(1.3)
    let pause = detector.checkPause()
    check(pause != nil, "Pause triggers after sentence end and 1.2s delay")
    check(pause?.paragraph == "Hello world a. b!", "Pause returns correct paragraph")

    // Second check immediately or after same paragraph revision returns nil (memoized)
    detector.noteTyping(character: 0x21, paragraph: "Hello world a. b!", range: NSRange(location: 0, length: 17), caret: 17)
    currentTime = currentTime.addingTimeInterval(1.3)
    check(detector.checkPause() == nil, "At most one request per paragraph revision")

    // Leaving paragraph triggers immediate pause check
    detector.noteLeftParagraph(oldParagraph: "New paragraph left behind.", oldRange: NSRange(location: 0, length: 26))
    let leftPause = detector.checkPause()
    check(leftPause != nil, "Leaving paragraph triggers pause check")
    check(leftPause?.paragraph == "New paragraph left behind.", "Pause returns left paragraph")
}

// 4. Bandleader context extractor privacy tests
print("Testing Context extractor...")
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
print("Testing Paragraph voice settings...")
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
print("Testing Session memory...")
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
// Typography (#104): curly quotes, dashes and ellipses, from the editor's checks, only when turned on
do {
    let all: (PunctuationRule) -> Bool = { _ in true }
    check(type("dont say \"no\" -- it works... ", isActive: all).text == "Don’t say “no” – it works… ", "typography on: \(type("dont say \"no\" -- it works... ", isActive: all).text)")
    check(type("dont say \"no\" -- it works... ").text == "Don't say \"no\" -- it works... ", "typography off by default")
    check(type("see `don't` and --flag ", isActive: all).text == "See `don't` and --flag ", "no typography in code or on a --flag")
    let rules = type("dont say \"no\" ", isActive: all).rules
    check(rules.contains(.curlyQuotes) && rules.contains(.contraction), "curly quotes is its own rule: \(rules)")
    let defaults = UserDefaults(suiteName: "swash-typography-tests")!
    defaults.removePersistentDomain(forName: "swash-typography-tests")
    check(!WritingPartnerDefaults.curlyQuotes(defaults) && !WritingPartnerDefaults.dashes(defaults) && !WritingPartnerDefaults.ellipses(defaults), "typography off unless turned on")
    defaults.set(true, forKey: WritingPartnerDefaults.dashes)
    check(WritingPartnerDefaults.isRuleEnabled(.dashes, defaults) && !WritingPartnerDefaults.isRuleEnabled(.ellipses, defaults), "each switch on its own")
    defaults.removePersistentDomain(forName: "swash-typography-tests")
}

print("\(passes) passed, \(failures) failed")
exit(failures == 0 ? 0 : 1)

// The Formatting voice (Swash/FormattingVoice.swift, #113): each rule, the places it never goes,
// typing timelines that never touch the block the caret is in, and a tidy pass over the CommonMark
// and GFM spec examples that must leave every rendering as it was.

import Foundation
import PixerateMarkdown

/// `text` after one tidy pass with the caret at `caret` (nil: no caret, tidy everything).
func tidied(_ text: String, caret: Int? = nil, flavor: MarkdownFlavor = .github,
            isActive: (PunctuationRule) -> Bool = { _ in true }, verify: Bool = true) -> (text: String, rules: [PunctuationRule]) {
    let document = MarkdownDocument.parse(text, flavor: flavor)
    let edits = FormattingVoice.edits(text: text, document: document, flavor: flavor, caret: caret, isActive: isActive, verify: verify)
    return (FormattingVoice.apply(edits, to: text), edits.flatMap(\.rules))
}

func expectTidy(_ input: String, _ expected: String, caret: Int? = nil, flavor: MarkdownFlavor = .github,
                rule: PunctuationRule? = nil, line: Int = #line) {
    let isActive: (PunctuationRule) -> Bool = { rule == nil || $0 == rule }
    let result = tidied(input, caret: caret, flavor: flavor, isActive: isActive)
    // A second pass finishes anything the first left for later, as the next caret move would
    let again = tidied(result.text, caret: caret, flavor: flavor, isActive: isActive).text
    if again == expected {
        passes += 1
    } else {
        failures += 1
        print("FAIL (line \(line)): tidying \(input.debugDescription)\n  got      \(again.debugDescription)\n  expected \(expected.debugDescription)")
    }
}

/// Types `typed` one character at a time with the caret at the end, tidying after every character
/// as the partner would, and checks no tidy ever reaches the block being typed. Then leaves the
/// last block (two Enters) and tidies once more.
func typeWithFormatting(_ typed: String, flavor: MarkdownFlavor = .github, line: Int = #line) -> String {
    var text = ""
    for character in typed {
        text += String(character)
        let ns = text as NSString
        let document = MarkdownDocument.parse(text, flavor: flavor)
        let edits = FormattingVoice.edits(text: text, document: document, flavor: flavor, caret: ns.length)
        // The last block is being typed while the caret is in it or on the line just after it
        if let caretBlock = document.root.children.last.map({ FormattingVoice.lineSpan(of: $0.range, in: ns) }),
           FormattingVoice.lineSpan(of: NSRange(location: ns.length, length: 0), in: ns).location <= NSMaxRange(caretBlock) + 1,
           edits.contains(where: { NSMaxRange($0.range) > caretBlock.location }) {
            failures += 1
            print("FAIL (line \(line)): a tidy reached the block being typed in \(text.debugDescription): \(edits)")
            return text
        }
        text = FormattingVoice.apply(edits, to: text)
    }
    text += "\n\n"
    let document = MarkdownDocument.parse(text, flavor: flavor)
    let edits = FormattingVoice.edits(text: text, document: document, flavor: flavor, caret: (text as NSString).length)
    return FormattingVoice.apply(edits, to: text)
}

func runFormattingTests() {
    // MARK: Lists
    expectTidy("1. one\n3. two\n2. three\n", "1. one\n2. two\n3. three\n", rule: .formatLists)
    expectTidy("4. one\n9. two\n", "4. one\n5. two\n", rule: .formatLists)
    expectTidy("1. one\n1. two\n1. three\n", "1. one\n1. two\n1. three\n", rule: .formatLists) // deliberate
    expectTidy("- one\n* two\n* three\n", "- one\n- two\n- three\n", rule: .formatLists)
    expectTidy("- one\n\n* two\n", "- one\n\n* two\n", rule: .formatLists) // a blank line makes them two lists
    expectTidy("- one\n - two\n", "- one\n- two\n", rule: .formatLists)
    expectTidy("- one\n  - nested\n- two\n", "- one\n  - nested\n- two\n", rule: .formatLists)

    // MARK: Headings
    expectTidy("#Heading\n", "# Heading\n", rule: .formatHeadings)
    expectTidy("##Heading\n", "## Heading\n", rule: .formatHeadings)
    expectTidy("#hashtag\n", "#hashtag\n", rule: .formatHeadings)
    expectTidy("#  Title ##\n", "# Title\n", rule: .formatHeadings)
    expectTidy("## Title.\n", "## Title\n", rule: .formatHeadings)
    expectTidy("## Title etc.\n", "## Title etc.\n", rule: .formatHeadings)
    expectTidy("## Wait...\n", "## Wait...\n", rule: .formatHeadings)
    expectTidy("# C#\n", "# C#\n", rule: .formatHeadings)

    // MARK: Spacing
    expectTidy("One\n\n\n\nTwo\n", "One\n\nTwo\n", rule: .formatSpacing)
    expectTidy("One\n  \n\t\nTwo\n", "One\n\nTwo\n", rule: .formatSpacing)
    expectTidy("# Title\nText\n", "# Title\n\nText\n", rule: .formatSpacing)
    expectTidy("Text\n# Title\n", "Text\n\n# Title\n", rule: .formatSpacing)
    expectTidy("Text\n```\ncode\n```\nMore\n", "Text\n\n```\ncode\n```\n\nMore\n", rule: .formatSpacing)
    expectTidy("hello  world\n", "hello world\n", rule: .formatSpacing)
    expectTidy("a **b**   c\n", "a **b** c\n", rule: .formatSpacing)
    expectTidy("trailing \n", "trailing\n", rule: .formatSpacing)
    expectTidy("line one  \nline two\n", "line one  \nline two\n", rule: .formatSpacing) // hard break
    expectTidy("line one \nline two\n", "line one\nline two\n", rule: .formatSpacing)
    expectTidy("say ** hello ** now\n", "say **hello** now\n", rule: .formatSpans)
    expectTidy("say **hello ** now\n", "say **hello** now\n", rule: .formatSpans)
    expectTidy("~~ gone ~~\n", "~~gone~~\n", rule: .formatSpans)
    expectTidy("2 ** 3 ** 4\n", "2 ** 3 ** 4\n", rule: .formatSpans) // no letters: not emphasis
    expectTidy("``\nfoo \n``\n", "``\nfoo \n``\n", rule: .formatSpacing) // a space inside a code span stays
    expectTidy("*_foo_*\n", "*_foo_*\n", rule: .formatEmphasis) // would become **foo**
    expectTidy("`a  b`\n", "`a  b`\n", rule: .formatSpacing)
    expectTidy("    indented  code\n", "    indented  code\n", rule: .formatSpacing)
    expectTidy("<div>\n\n\n\n</div>\n", "<div>\n\n\n\n</div>\n", rule: .formatSpacing)

    // MARK: Span wrapping
    expectTidy("Say `hell`o now\n", "Say `hello` now\n", rule: .formatSpans)
    expectTidy("Say **hell**o now\n", "Say **hello** now\n", rule: .formatSpans)
    expectTidy("Say <em>hell</em>o now\n", "Say <em>hello</em> now\n", rule: .formatSpans)
    expectTidy("Say h`ello` now\n", "Say `hello` now\n", rule: .formatSpans)
    expectTidy("Say h**ello** now\n", "Say **hello** now\n", rule: .formatSpans)
    expectTidy("The `foo`'s value\n", "The `foo`'s value\n", rule: .formatSpans)
    expectTidy("Two `int`s here\n", "Two `int`s here\n", rule: .formatSpans)
    expectTidy("A `foo`-bar here\n", "A `foo`-bar here\n", rule: .formatSpans)
    expectTidy("un*frigging*believable\n", "un*frigging*believable\n", rule: .formatSpans)

    // MARK: Emphasis
    expectTidy("*one* and _two_\n", "*one* and *two*\n", rule: .formatEmphasis)
    expectTidy("_one_ and _two_ and *three*\n", "_one_ and _two_ and _three_\n", rule: .formatEmphasis)
    expectTidy("_one_ _two_ un*believ*able\n", "_one_ _two_ un*believ*able\n", rule: .formatEmphasis) // "_" can't go inside a word
    expectTidy("**strong** and __strong__ *em*\n", "**strong** and __strong__ *em*\n", rule: .formatEmphasis)

    // MARK: Tasks
    expectTidy("- [] buy milk\n- [X] eggs\n", "- [ ] buy milk\n- [x] eggs\n", rule: .formatTasks)
    expectTidy("* [ ] one\n* [x] two\n", "- [ ] one\n- [x] two\n", rule: .formatTasks)
    expectTidy("- [link] text\n", "- [link] text\n", rule: .formatTasks)

    // MARK: Tables
    expectTidy("| a | bbb |\n|---|:-:|\n| cccc | d |\n", "| a    | bbb |\n| ---- | :-: |\n| cccc |  d  |\n", rule: .formatTables)
    expectTidy("a | b\n--|--:\nlong | 1\n", "| a    |   b |\n| ---- | --: |\n| long |   1 |\n", rule: .formatTables)
    expectTidy("| a | b |\n|---|---|\n| x \\| y | z |\n", "| a      | b   |\n| ------ | --- |\n| x \\| y | z   |\n", rule: .formatTables)
    expectTidy("| a | b |\n|---|---|\n| one |\n", "| a   | b   |\n| --- | --- |\n| one |     |\n", rule: .formatTables)

    // MARK: Links
    expectTidy("https://example.com/page\n", "<https://example.com/page>\n", rule: .formatLinks)
    expectTidy("See https://example.com/page\n", "See https://example.com/page\n", rule: .formatLinks)
    expectTidy("https://example.com.\n", "https://example.com.\n", rule: .formatLinks)
    expectTidy("- https://example.com\n", "- <https://example.com>\n", rule: .formatLinks)
    expectTidy("https://example.com\n", "<https://example.com>\n", flavor: .commonMark, rule: .formatLinks)

    // MARK: Never inside code, math, HTML or front matter
    expectTidy("```\n1. one\n3. two\n#Heading\nhello  world\n```\n", "```\n1. one\n3. two\n#Heading\nhello  world\n```\n")
    expectTidy("$$\na  b\n$$\n", "$$\na  b\n$$\n")
    expectTidy("<pre>\nhello  world\n\n\n</pre>\n", "<pre>\nhello  world\n\n\n</pre>\n")
    expectTidy("---\ntitle:  x\n---\n", "---\ntitle:  x\n---\n")
    expectTidy("Inline $a  b$ math\n", "Inline $a  b$ math\n")
    expectTidy("Say `hell`o\n", "Say `hell`o\n", flavor: .slack)

    // MARK: Never the block the caret is in
    let caretText = "1. one\n3. two"
    expectTidy(caretText, caretText, caret: (caretText as NSString).length)
    let oneEnter = "1. one\n3. two\n"
    expectTidy(oneEnter, oneEnter, caret: (oneEnter as NSString).length) // one Enter: the list may go on
    let left = "1. one\n3. two\n\nNext"
    expectTidy(left, "1. one\n2. two\n\nNext", caret: (left as NSString).length)
    let table = "| a | bbb |\n|---|---|\n| c | d |"
    expectTidy(table, table, caret: 3)
    let gap = "# Title\nText"
    expectTidy(gap, gap, caret: (gap as NSString).length) // the gap is next to the caret's block

    // MARK: Switches
    check(tidied("hello  world\n", isActive: { $0 != .formatSpacing }).text == "hello  world\n", "A rule that's off makes no fix")
    check(tidied("1. a\n3. b\n").rules == [.formatLists], "A fix carries its rule, so ⌘Z counts against it")
    check(FormattingVoice.rules.allSatisfy(\.isFormatting) && !PunctuationRule.pronounI.isFormatting, "Formatting rules are marked")
    check(!WritingPartnerStats().toVoiceState().rules.keys.contains { $0.hasPrefix("format-") }, "Formatting rules stay out of the bandleader's voice state")
    let suite = UserDefaults(suiteName: "formatting-tests")!
    suite.removePersistentDomain(forName: "formatting-tests")
    check(WritingPartnerDefaults.isRuleEnabled(.formatTables, suite), "Formatting rules are on by default")
    suite.set(false, forKey: WritingPartnerDefaults.formattingKey(.formatTables))
    check(!WritingPartnerDefaults.isRuleEnabled(.formatTables, suite), "Each formatting rule has its own switch")
    check(!WritingPartnerDefaults.formattingInSource(suite), "Formatting is off in Source view by default")

    // MARK: Typing timelines
    let timelines: [(typed: String, expected: String)] = [
        ("1. one\n2. two\n4. three\n\nAfter", "1. one\n2. two\n3. three\n\nAfter\n\n"),
        ("#Heading\n\nText follows", "# Heading\n\nText follows\n\n"),
        ("# Title\nText follows\n\nEnd", "# Title\n\nText follows\n\nEnd\n\n"),
        ("hello  world\n\nnext", "hello world\n\nnext\n\n"),
        ("| a | b |\n|-|-|\n| long cell | x |\n\nAfter", "| a         | b   |\n| --------- | --- |\n| long cell | x   |\n\nAfter\n\n"),
        ("- [] milk\n- [X] eggs\n\nDone", "- [ ] milk\n- [x] eggs\n\nDone\n\n"),
        ("Use `hell`o here\n\nNext", "Use `hello` here\n\nNext\n\n"),
        ("```\nhello  world\n```\n\nNext", "```\nhello  world\n```\n\nNext\n\n"),
    ]
    for timeline in timelines {
        let result = typeWithFormatting(timeline.typed)
        check(result == timeline.expected, "typing \(timeline.typed.debugDescription) gave \(result.debugDescription), expected \(timeline.expected.debugDescription)")
    }

    // MARK: The spec examples render the same after a tidy pass
    if let fixtures = ProcessInfo.processInfo.environment["SPEC_FIXTURES"] {
        for (file, flavor) in [("commonmark-0.31.2.json", MarkdownFlavor.commonMark), ("gfm-extensions.json", MarkdownFlavor.github)] {
            guard let data = FileManager.default.contents(atPath: fixtures + "/" + file),
                  let examples = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
                failures += 1
                print("FAIL: couldn't read \(file)")
                continue
            }
            var changed: [Int] = []
            for example in examples {
                guard let markdown = example["markdown"] as? String else { continue }
                // Only the fixes that must keep the rendering: the rest change it on purpose
                // without the voice's own rendering check, so this checks the rules themselves
                let result = tidied(markdown, flavor: flavor, isActive: { ![.formatHeadings, .formatTasks, .formatLists, .formatSpans, .formatLinks].contains($0) },
                                    verify: false).text
                if FormattingVoice.render(result, flavor: flavor) != FormattingVoice.render(markdown, flavor: flavor) {
                    changed.append(example["example"] as? Int ?? -1)
                }
            }
            check(changed.isEmpty, "\(file): a tidy pass changed the rendering of examples \(changed)")
            passes += 1
        }
    } else {
        print("SKIP: SPEC_FIXTURES not set, spec rendering check not run")
    }
}

// Context-aware spelling eval (#98): the strip-and-restore corpus (#106) with wrong words and
// misspellings the system spell checker leaves alone injected into its prose, each paragraph
// played through the on-device bandleader (Apple's Foundation Models, macOS 26 with Apple
// Intelligence) and Swash's planner as the editor would. Scores what it put right, what it missed,
// what it changed that it shouldn't have, and what it only offered.
//
// Run with scripts/run_context_spelling_eval.sh. On a Mac without the on-device model it says so
// and exits without a score.

import Foundation
import PixerateMarkdown

/// Real words that are commonly used in place of each other, and misspellings whose fix depends on
/// the sentence. Each pair is (what's right, what's typed).
let wrongWords: [(right: String, typed: String)] = [
    ("from", "form"), ("there", "their"), ("their", "there"), ("lose", "loose"), ("than", "then"),
    ("then", "than"), ("its", "it's"), ("your", "you're"), ("affect", "effect"), ("quiet", "quite"),
    ("where", "were"), ("whether", "weather"), ("accept", "except"), ("advice", "advise"),
]

struct SplitMix64: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}

struct Injected { var range: NSRange; var right: String; var typed: String }

/// Swaps up to one right word per paragraph for its wrong twin, in prose only.
func inject(_ text: String, flavor: MarkdownFlavor, rng: inout SplitMix64) -> (text: String, injected: [Injected]) {
    let document = MarkdownDocument.parse(text, flavor: flavor)
    var ns = text as NSString
    var injected: [Injected] = []
    var paragraphs: [MarkdownNode] = []
    var stack = [document.root]
    while let node = stack.popLast() {
        if case .paragraph = node.kind { paragraphs.append(node) }
        stack.append(contentsOf: node.children)
    }
    for paragraph in paragraphs.sorted(by: { $0.range.location > $1.range.location }) {
        let candidates = wrongWords.flatMap { pair in
            ContextSpelling.wholeWordRanges(of: pair.right, in: ns.substring(with: paragraph.range) as NSString).map { (pair, $0) }
        }
        guard !candidates.isEmpty, Int.random(in: 0..<3, using: &rng) > 0 else { continue }
        let (pair, local) = candidates[Int.random(in: 0..<candidates.count, using: &rng)]
        let range = NSRange(location: paragraph.range.location + local.location, length: local.length)
        guard GrammarVoice.isProseRange(range, in: ns, document: document) else { continue }
        ns = ns.replacingCharacters(in: range, with: pair.typed) as NSString
        let delta = (pair.typed as NSString).length - range.length
        injected = injected.map { var i = $0; if i.range.location > range.location { i.range.location += delta }; return i }
        injected.append(Injected(range: NSRange(location: range.location, length: (pair.typed as NSString).length), right: pair.right, typed: pair.typed))
    }
    return (ns as String, injected)
}

@MainActor
func run() async -> Int32 {
    let args = CommandLine.arguments
    guard let corpusIndex = args.firstIndex(of: "--corpus"), corpusIndex + 1 < args.count else {
        print("usage: runner --corpus <dir> [--seed N]")
        return 2
    }
    let corpus = URL(fileURLWithPath: args[corpusIndex + 1])
    let seed = args.firstIndex(of: "--seed").flatMap { UInt64(args[$0 + 1]) } ?? 98
    guard OnDeviceBandleaderAvailability.isAvailable else {
        print("SKIP: the on-device model isn't available on this Mac: \(OnDeviceBandleaderAvailability.statusMessage ?? "unknown") No score.")
        return 0
    }
    let bandleader = OnDeviceWritingBandleader(timeoutSeconds: 20)
    var rng = SplitMix64(state: seed)
    var restored = 0, missed = 0, wrong = 0, offered = 0, total = 0
    let files = (try? FileManager.default.contentsOfDirectory(at: corpus, includingPropertiesForKeys: nil)) ?? []
    for file in files.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) where file.pathExtension == "md" {
        let flavor: MarkdownFlavor = file.lastPathComponent.hasSuffix(".slack.md") ? .slack : .github
        guard flavor != .slack, let original = try? String(contentsOf: file, encoding: .utf8) else { continue }
        let (text, injected) = inject(original, flavor: flavor, rng: &rng)
        total += injected.count
        var working = text
        // Each paragraph as the person would leave it, last first so earlier offsets hold
        let document = MarkdownDocument.parse(working, flavor: flavor)
        var paragraphs: [NSRange] = []
        var stack = [document.root]
        while let node = stack.popLast() {
            if case .paragraph = node.kind { paragraphs.append(node.range) }
            stack.append(contentsOf: node.children)
        }
        var offeredHere: [PartnerEdit] = []
        for range in paragraphs.sorted(by: { $0.location > $1.location }) {
            guard let context = BandleaderContextExtractor.extract(from: working, caret: NSMaxRange(range), flavor: flavor) else { continue }
            let request = JazzTextLeadRequest(paragraph: context.paragraph, before: context.before, after: context.after, flavor: flavor.jazzTextFlavor)
            guard let response = try? await bandleader.lead(request: request) else { continue }
            let plan = BandleaderSuggestionPlanner.plan(response: response, paragraph: context.paragraph, paragraphRange: context.range,
                                                        documentText: working, flavor: flavor, memory: BandleaderSessionMemory())
            offeredHere += plan.offeredEdits.filter { $0.bandleaderSuggestionKind?.isSpellingKind == true }
            var ns = working as NSString
            for edit in plan.automaticEdits.filter({ $0.bandleaderSuggestionKind?.isSpellingKind == true }).sorted(by: { $0.range.location > $1.range.location }) {
                ns = ns.replacingCharacters(in: edit.range, with: edit.replacement) as NSString
            }
            working = ns as String
        }
        // Score by word: compare the result with the original, word by word
        let want = original.split(whereSeparator: { $0.isWhitespace })
        let got = working.split(whereSeparator: { $0.isWhitespace })
        let typed = text.split(whereSeparator: { $0.isWhitespace })
        if want.count == got.count, want.count == typed.count {
            for index in want.indices {
                let wasInjected = typed[index] != want[index]
                if wasInjected { got[index] == want[index] ? (restored += 1) : (missed += 1) }
                else if got[index] != want[index] { wrong += 1 }
            }
        } else {
            print("NOTE: \(file.lastPathComponent): a fix changed the word count; counted as wrong")
            wrong += 1
        }
        offered += offeredHere.count
        print("\(file.lastPathComponent): injected \(injected.count)")
    }
    let precision = restored + wrong == 0 ? 1 : Double(restored) / Double(restored + wrong)
    let recall = total == 0 ? 1 : Double(restored) / Double(total)
    print(String(format: "Context spelling: injected %d, restored %d, missed %d, wrong changes %d, offered %d, precision %.3f, recall %.3f",
                 total, restored, missed, wrong, offered, precision, recall))
    return 0
}

let status = await run()
exit(status)

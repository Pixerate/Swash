//
//  WritingPartnerTests.swift
//  SwashiOSTests
//
//  The writing partner on iPhone and iPad (#109): typing a sentence in the real Edit Text editor,
//  undoing a fix, pausing for one document, the pause tier falling back to the on-device partner
//  when Pixerate can't be reached, and the NaturalLanguage word classes some rules need.
//

import NaturalLanguage
import SwiftUI
import UIKit
import XCTest
import PixerateMarkdown
@testable import Swash

@MainActor
final class WritingPartnerTests: XCTestCase {
    private var harnesses: [EditorHarness] = []
    private var savedDefaults: [String: Any?] = [:]
    private let keys = [WritingPartnerDefaults.mode, WritingPartnerDefaults.spelling, WritingPartnerDefaults.stats,
                        WritingPartnerDefaults.introShown, WritingPartnerDefaults.undoReminderShown]

    override func setUp() async throws {
        try await super.setUp()
        let defaults = UserDefaults.standard
        for key in keys { savedDefaults[key] = defaults.object(forKey: key) }
        defaults.set(WritingPartnerMode.automatic.rawValue, forKey: WritingPartnerDefaults.mode)
        // What the system spell checker corrects depends on the device (GOTCHAS #78)
        defaults.set(false, forKey: WritingPartnerDefaults.spelling)
        defaults.removeObject(forKey: WritingPartnerDefaults.stats)
        WritingPartnerDefaults.setIntroShown(true, defaults)
        WritingPartnerDefaults.setUndoReminderShown(true, defaults)
    }

    override func tearDown() async throws {
        for harness in harnesses { harness.tearDown() }
        harnesses.removeAll()
        let defaults = UserDefaults.standard
        for (key, value) in savedDefaults {
            if let value { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) }
        }
        try await super.tearDown()
    }

    private func editor(_ markdown: String = "", file: StaticString = #filePath, line: UInt = #line) throws -> EditorHarness {
        let harness = try EditorHarness(markdown, file: file, line: line)
        harnesses.append(harness)
        return harness
    }

    /// Runs the loop until the partner has played every fix, then a turn more for the restyle.
    private func waitForPartner(_ harness: EditorHarness, limit: TimeInterval = 10) {
        let deadline = Date().addingTimeInterval(limit)
        harness.pump(0.05)
        while Date() < deadline, !harness.coordinator.writingPartner.isIdle { harness.pump(0.02) }
        harness.pump(0.1)
    }

    private func type(_ text: String, in harness: EditorHarness) {
        for character in text { harness.type(String(character)) }
    }

    // MARK: Typing

    func testFixesASentenceAsItIsTyped() throws {
        let harness = try editor()
        harness.textView.becomeFirstResponder()
        type("so i dont know ", in: harness)
        waitForPartner(harness)
        XCTAssertEqual(harness.text, "So I don't know ")
        // The caret stays where the person was typing
        XCTAssertEqual(harness.coordinator.rawRange(forStorage: harness.textView.selectedRange, in: harness.textView).location,
                       (harness.text as NSString).length)
    }

    func testLeavesTheTextAloneWhenOff() throws {
        UserDefaults.standard.set(WritingPartnerMode.off.rawValue, forKey: WritingPartnerDefaults.mode)
        let harness = try editor()
        type("so i dont know ", in: harness)
        waitForPartner(harness)
        XCTAssertEqual(harness.text, "so i dont know ")
    }

    func testTakesOverTheKeyboardsAutocorrectWhileOn() throws {
        let harness = try editor()
        type("so ", in: harness)
        waitForPartner(harness)
        XCTAssertEqual(harness.textView.autocorrectionType, .no)
        XCTAssertEqual(harness.textView.inlinePredictionType, .no)
    }

    // MARK: Undo

    func testUndoTakesBackOneFixAndCountsAgainstItsRule() throws {
        let harness = try editor()
        harness.textView.becomeFirstResponder()
        type("so i dont know ", in: harness)
        waitForPartner(harness)
        XCTAssertEqual(harness.text, "So I don't know ")
        let undoManager = try XCTUnwrap(harness.textView.undoManager)
        XCTAssertTrue(undoManager.canUndo)
        undoManager.undo()
        harness.pump(0.2)
        // Each word the partner changed is its own undo step: the newest goes
        XCTAssertEqual(harness.text, "So I dont know ")
        // The caret goes back to where the person was typing, not onto the restored word
        XCTAssertEqual(harness.coordinator.rawRange(forStorage: harness.textView.selectedRange, in: harness.textView).location,
                       (harness.text as NSString).length)
        let stats = WritingPartnerStats.load(voice: .punctuate)
        XCTAssertFalse(stats.rules.isEmpty, "undoing a fix should be recorded against its rule")
    }

    // MARK: Pause

    func testPausingTheDocumentStopsFixes() throws {
        let harness = try editor()
        harness.controller.setPartnerPaused(true)
        XCTAssertTrue(harness.coordinator.writingPartner.isPaused)
        type("so i dont know ", in: harness)
        waitForPartner(harness)
        XCTAssertEqual(harness.text, "so i dont know ")
    }

    // MARK: Fallback

    func testThePauseTierFallsBackToTheDeviceAndBack() async throws {
        let saved = (WritingBandleaderFactory.makePixerateBandleader, WritingBandleaderFactory.isOnDeviceAvailable,
                     WritingBandleaderFactory.makeOnDeviceBandleader)
        defer {
            WritingBandleaderFactory.makePixerateBandleader = saved.0
            WritingBandleaderFactory.isOnDeviceAvailable = saved.1
            WritingBandleaderFactory.makeOnDeviceBandleader = saved.2
        }
        let pixerate = StubBandleader(provider: .pixerate, fails: true)
        WritingBandleaderFactory.makePixerateBandleader = { pixerate }
        WritingBandleaderFactory.isOnDeviceAvailable = { true }
        WritingBandleaderFactory.makeOnDeviceBandleader = { StubBandleader(provider: .onDevice, fails: false) }
        let request = JazzTextLeadRequest(paragraph: "So I dont know")

        // The connection drops: the on-device partner takes the pause, with no error
        let offlineResult = await WritingBandleaderFactory.leadWithFallback(request: request, provider: .pixerate)
        let offline = try XCTUnwrap(offlineResult)
        XCTAssertEqual(offline.bandleader.provider, .onDevice)

        // It comes back: the next pause goes to Pixerate again, though the on-device one is active
        pixerate.fails = false
        let onlineResult = await WritingBandleaderFactory.leadWithFallback(request: request, provider: .pixerate,
                                                                           existing: offline.bandleader)
        let online = try XCTUnwrap(onlineResult)
        XCTAssertEqual(online.bandleader.provider, .pixerate)
    }

    func testPauseRequestsTimeOutQuickly() {
        // A dropped connection must reach the fallback in seconds, not URLSession's minute
        XCTAssertLessThanOrEqual(PixerateWritingBandleader.leadTimeout, 10)
    }

    // MARK: Spelling

    func testSpellingOnlyTakesCloseGuesses() {
        XCTAssertEqual(IOSWritingPartnerHost.editDistance("teh", "the"), 2)
        XCTAssertEqual(IOSWritingPartnerHost.editDistance("recieve", "receive"), 2)
        XCTAssertEqual(IOSWritingPartnerHost.editDistance("swash", "swash"), 0)
        // A name the dictionary doesn't know is far from any guess: left alone
        XCTAssertGreaterThan(IOSWritingPartnerHost.editDistance("swash", "smashed"), 2)
    }

    // MARK: Word classes

    /// `its` → `it's`, `id` → `I'd`, `ill` → `I'll` and the comma before a clause-starting "but"
    /// need NLTagger's lexical classes. The iOS Simulator gives none (Pixerate/editor#893), so those
    /// fixes are skipped there by design; on a device this fails loudly if they would be.
    func testTheTaggerGivesWordClasses() throws {
        let tagger = NLTagger(tagSchemes: [.lexicalClass])
        let text = "I think its raining but we went out"
        tagger.string = text
        var classes = 0
        tagger.enumerateTags(in: text.startIndex..<text.endIndex, unit: .word, scheme: .lexicalClass,
                             options: [.omitWhitespace, .omitPunctuation]) { tag, _ in
            if tag != nil { classes += 1 }
            return true
        }
        #if targetEnvironment(simulator)
        if classes == 0 {
            throw XCTSkip("NLTagger gives no word classes on the iOS Simulator: its/it's, I'd, I'll and the comma before 'but' are skipped here")
        }
        #endif
        XCTAssertGreaterThan(classes, 0, "NLTagger gave no word classes, so the partner would never fix its/it's, id/I'd or ill/I'll")
    }
}

/// A pause-tier bandleader that answers with nothing to change, or fails like a dropped connection.
private final class StubBandleader: WritingBandleader, @unchecked Sendable {
    let provider: WritingPartnerProvider
    var fails: Bool

    init(provider: WritingPartnerProvider, fails: Bool) {
        self.provider = provider
        self.fails = fails
    }

    func lead(request: JazzTextLeadRequest) async throws -> JazzTextLeadResponse? {
        if fails { throw URLError(.timedOut) }
        return JazzTextLeadResponse(genre: .prose, palette: [], why: "Stub")
    }
}

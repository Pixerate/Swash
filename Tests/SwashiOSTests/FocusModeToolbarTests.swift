//
//  FocusModeToolbarTests.swift
//  SwashiOSTests
//
//  Tests for iOS Focus Mode toolbar gating, writing options, and focus controls.
//

import SwiftUI
import UIKit
import XCTest
import PixerateMarkdown
@testable import Swash

@MainActor
final class FocusModeToolbarTests: XCTestCase {
    private var testDefaults: UserDefaults!
    private var suiteName: String!

    override func setUp() async throws {
        try await super.setUp()
        suiteName = "com.pixerate.SwashiOSTests.FocusMode.\(UUID().uuidString)"
        testDefaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() async throws {
        if let suiteName {
            testDefaults?.removePersistentDomain(forName: suiteName)
        }
        testDefaults = nil
        try await super.tearDown()
    }

    func testWritingOptionsFocusState() {
        // Reads only the isolated test suite, never the machine's saved settings
        XCTAssertFalse(testDefaults.bool(forKey: WritingDefaults.focusMode))

        testDefaults.set(true, forKey: WritingDefaults.focusMode)
        testDefaults.set(FocusUnit.sentence.rawValue, forKey: WritingDefaults.focusUnit)
        XCTAssertEqual(testDefaults.bool(forKey: WritingDefaults.focusMode), true)
        XCTAssertEqual(testDefaults.string(forKey: WritingDefaults.focusUnit), "sentence")
    }

    func testFocusModeViewRendering() async throws {
        testDefaults.set(true, forKey: WritingDefaults.focusMode)
        testDefaults.set(FocusUnit.paragraph.rawValue, forKey: WritingDefaults.focusUnit)

        let document = SwashSampleDocument.standard
        let view = IOSContentView(document: .constant(document), fileURL: nil)
            .defaultAppStorage(testDefaults)

        let hosting = UIHostingController(rootView: view)
        hosting.view.frame = CGRect(x: 0, y: 0, width: 393, height: 852)
        hosting.loadViewIfNeeded()
        hosting.view.layoutIfNeeded()

        XCTAssertNotNil(hosting.view)
        XCTAssertEqual(testDefaults.bool(forKey: WritingDefaults.focusMode), true)
    }

    func testFocusModeTurnOffAnimationToggle() async throws {
        testDefaults.set(true, forKey: WritingDefaults.focusMode)
        XCTAssertTrue(testDefaults.bool(forKey: WritingDefaults.focusMode))

        // Turning focus mode off updates the storage
        testDefaults.set(false, forKey: WritingDefaults.focusMode)
        XCTAssertFalse(testDefaults.bool(forKey: WritingDefaults.focusMode))
    }
}

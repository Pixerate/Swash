//
//  main.swift
//  Tests/NewDocumentSeed
//
//  Tests that NewDocumentSeed delivers initial text exclusively to the window
//  and document instance created for it, preventing concurrent ⌘N or restored
//  windows from intercepting seeded text.
//

import AppKit
import OSLog
@testable import PixerateMarkdown

var failures = 0
func check(_ name: String, _ condition: Bool, _ message: String = "") {
    print("\(condition ? "PASS" : "FAIL") \(name)\(condition ? "" : " — \(message)")")
    if !condition { failures += 1 }
}

final class MockDocument: NSDocument {}

@MainActor
func createMockWindowAndDocument() -> (NSWindow, NSDocument) {
    let doc = MockDocument()
    let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 200, height: 200),
        styleMask: [.titled, .closable],
        backing: .buffered,
        defer: false
    )
    let wc = NSWindowController(window: window)
    doc.addWindowController(wc)
    return (window, doc)
}

@MainActor
func runTests() {
    print("=== Testing NewDocumentSeed Window & Document Binding ===")

    // Test 0: Reproduction check of the legacy race condition
    // Under the legacy model, a global FIFO queue allowed an unrelated window to claim another window's seed
    do {
        var legacyQueue: [String] = []
        func legacyCreateDocument(with text: String) { legacyQueue.append(text) }
        func legacyTake() -> String? { legacyQueue.isEmpty ? nil : legacyQueue.removeFirst() }

        legacyCreateDocument(with: "# Target Note")
        let stolenByUnrelatedWindow = legacyTake()
        let targetWindowClaim = legacyTake()
        check("Legacy FIFO queue demonstrates bug where unrelated window steals seed", stolenByUnrelatedWindow == "# Target Note")
        check("Legacy FIFO queue leaves target window empty", targetWindowClaim == nil)
    }

    // Test 1: Window-specific claiming prevents other windows from intercepting
    do {
        NewDocumentSeed.clearForTesting()
        let (windowA, docA) = createMockWindowAndDocument()
        let (windowB, _) = createMockWindowAndDocument()

        NewDocumentSeed.registerForTesting(text: "# Note A", document: docA, window: windowA)

        // Window B (e.g. concurrent ⌘N or restored untitled window) tries to claim
        let claimedByB = NewDocumentSeed.take(for: windowB)
        check("Window B cannot claim Window A's seed", claimedByB == nil, "got: \(String(describing: claimedByB))")

        // Window A claims its seed
        let claimedByA = NewDocumentSeed.take(for: windowA)
        check("Window A claims its own seed", claimedByA == "# Note A", "got: \(String(describing: claimedByA))")

        // Window A claims again (should be nil since consumed)
        let secondClaimA = NewDocumentSeed.take(for: windowA)
        check("Window A seed is consumed on take", secondClaimA == nil, "got: \(String(describing: secondClaimA))")
    }

    // Test 2: Fallback to document object identity when window wasn't known at registration
    do {
        NewDocumentSeed.clearForTesting()
        let (windowA, docA) = createMockWindowAndDocument()
        let (windowB, _) = createMockWindowAndDocument()

        // Registered only by document (e.g. window was created after openUntitledDocumentAndDisplay returned)
        NewDocumentSeed.registerForTesting(text: "Document-only seed", document: docA, window: nil as NSWindow?)

        // Window B (unrelated document) tries to claim
        let claimedByB = NewDocumentSeed.take(for: windowB)
        check("Window B with different document gets nil", claimedByB == nil)

        // Window A (associated with docA) claims
        let claimedByA = NewDocumentSeed.take(for: windowA)
        check("Window A claims seed keyed by its document", claimedByA == "Document-only seed")

        // Consumed check
        let secondClaimA = NewDocumentSeed.take(for: windowA)
        check("Document-only seed is consumed on take", secondClaimA == nil)
    }

    // Test 3: Multiple concurrent seeded documents
    do {
        NewDocumentSeed.clearForTesting()
        let (window1, doc1) = createMockWindowAndDocument()
        let (window2, doc2) = createMockWindowAndDocument()
        let (windowPlain, _) = createMockWindowAndDocument()

        NewDocumentSeed.registerForTesting(text: "Seed 1", document: doc1, window: window1)
        NewDocumentSeed.registerForTesting(text: "Seed 2", document: doc2, window: window2)

        // Plain window gets nothing
        check("Plain window gets nil", NewDocumentSeed.take(for: windowPlain) == nil)

        // Window 2 claims first
        check("Window 2 claims Seed 2", NewDocumentSeed.take(for: window2) == "Seed 2")

        // Plain window still gets nothing
        check("Plain window still gets nil", NewDocumentSeed.take(for: windowPlain) == nil)

        // Window 1 claims
        check("Window 1 claims Seed 1", NewDocumentSeed.take(for: window1) == "Seed 1")

        // Both are now empty
        check("Window 1 empty after take", NewDocumentSeed.take(for: window1) == nil)
        check("Window 2 empty after take", NewDocumentSeed.take(for: window2) == nil)
    }

    print("=== Finished NewDocumentSeed Tests ===")
}

MainActor.assumeIsolated {
    runTests()
    if failures > 0 {
        print("\n\(failures) test(s) failed.")
        exit(1)
    } else {
        print("\nAll NewDocumentSeed tests passed successfully.")
    }
}

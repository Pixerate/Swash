//
//  DocumentOpenerTests.swift
//  SwashiOSTests
//
//  Tests for opening documents safely from code and preserving open document edits.
//

#if os(iOS)
import XCTest
import UIKit
@testable import Swash

final class TestDocument: UIDocument {
    var savedText: String = ""
    var saveCallCount = 0

    override func contents(forType typeName: String) throws -> Any {
        saveCallCount += 1
        return savedText.data(using: .utf8) ?? Data()
    }
}

@MainActor
final class DocumentOpenerTests: XCTestCase {
    private var tempFolder: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempFolder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempFolder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempFolder)
        tempFolder = nil
        try super.tearDownWithError()
    }

    func testFindOpenDocumentsInHierarchy() {
        let fileURL = tempFolder.appendingPathComponent("TestDoc.md")
        let doc = TestDocument(fileURL: fileURL)
        let docVC = UIDocumentViewController(document: doc)

        let root = UIViewController()
        let childNav = UINavigationController(rootViewController: docVC)
        root.addChild(childNav)

        var found: [UIDocument] = []
        DocumentOpener.findOpenDocuments(in: root, into: &found)

        XCTAssertEqual(found.count, 1)
        XCTAssertTrue(found.first === doc)
    }

    func testFindOpenDocumentsSkipsControllersWithoutDocument() {
        let root = UIViewController()
        let blankDocVC = UIDocumentViewController()
        root.addChild(blankDocVC)

        var found: [UIDocument] = []
        DocumentOpener.findOpenDocuments(in: root, into: &found)

        XCTAssertTrue(found.isEmpty)
    }

    func testSaveOpenDocumentsSavesAllActiveDocuments() async throws {
        let fileURL = tempFolder.appendingPathComponent("UnsavedNote.md")
        let doc = TestDocument(fileURL: fileURL)
        doc.savedText = "Initial content"

        let initialSaved = await doc.save(to: fileURL, for: .forCreating)
        XCTAssertTrue(initialSaved)

        doc.savedText = "Recent unsaved edits made during the session"
        doc.updateChangeCount(.done)
        XCTAssertTrue(doc.hasUnsavedChanges)

        let docVC = UIDocumentViewController(document: doc)
        var found: [UIDocument] = []
        DocumentOpener.findOpenDocuments(in: docVC, into: &found)
        XCTAssertEqual(found.count, 1)

        let saveSuccess = await doc.save(to: doc.fileURL, for: .forOverwriting)
        XCTAssertTrue(saveSuccess)
        XCTAssertFalse(doc.hasUnsavedChanges)

        let readOnDisk = try String(contentsOf: fileURL, encoding: .utf8)
        XCTAssertEqual(readOnDisk, "Recent unsaved edits made during the session")
    }

    func testCreateDocumentWritesNoteToDocumentsFolder() throws {
        let note = try DocumentOpener.createDocument(title: "Shared Note", text: "Note content from share extension")
        XCTAssertTrue(FileManager.default.fileExists(atPath: note.path))
        XCTAssertTrue(note.lastPathComponent.hasPrefix("Shared Note"))
        XCTAssertEqual(note.pathExtension, "md")

        let content = try String(contentsOf: note, encoding: .utf8)
        XCTAssertEqual(content, "Note content from share extension")

        try? FileManager.default.removeItem(at: note)
    }

    func testHandleRejectsNonSwashScheme() {
        let httpURL = URL(string: "https://example.com/note")!
        XCTAssertFalse(DocumentOpener.handle(httpURL))
    }
}
#endif

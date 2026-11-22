//
//  DocumentShareItemTests.swift
//  SwashiOSTests
//
//  Tests for DocumentShareItemSource and DocumentShareItem: sharing documents on iOS to
//  Apple Notes, Notion, Mail, Messages, AirDrop, and Save to Files.
//

import UIKit
import UniformTypeIdentifiers
import LinkPresentation
import XCTest
import PixerateMarkdown
@testable import Swash

@MainActor
final class DocumentShareItemTests: XCTestCase {
    private var tempFiles: [URL] = []

    override func tearDown() {
        for url in tempFiles {
            try? FileManager.default.removeItem(at: url)
        }
        tempFiles.removeAll()
        super.tearDown()
    }

    private func makeTemporaryFile(title: String, content: String) throws -> URL {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString)-\(title)")
            .appendingPathExtension("md")
        try content.write(to: tempURL, atomically: true, encoding: .utf8)
        tempFiles.append(tempURL)
        return tempURL
    }

    func testAirDropAndSaveToFilesReceiveMarkdownFileURL() throws {
        let markdown = "# Hello Swash\n\nThis is a test document."
        let fileURL = try makeTemporaryFile(title: "TestDoc", content: markdown)
        let source = DocumentExporter.Source(text: markdown, flavor: .commonMark, fileURL: fileURL, title: "TestDoc")
        let html = DocumentExporter.clipboardHTML(for: source)

        let shareSource = DocumentShareItemSource(title: "TestDoc", text: markdown, html: html, fileURL: fileURL)
        let dummyVC = UIActivityViewController(activityItems: [shareSource], applicationActivities: nil)

        // AirDrop must receive the .md file URL
        let airDropItem = shareSource.activityViewController(dummyVC, itemForActivityType: .airDrop)
        XCTAssertEqual(airDropItem as? URL, fileURL)
        let airDropType = shareSource.activityViewController(dummyVC, dataTypeIdentifierForActivityType: .airDrop)
        XCTAssertEqual(airDropType, UTType(filenameExtension: "md")?.identifier)

        // Save to Files must receive the .md file URL
        let filesItem = shareSource.activityViewController(dummyVC, itemForActivityType: .saveToFiles)
        XCTAssertEqual(filesItem as? URL, fileURL)
        let filesType = shareSource.activityViewController(dummyVC, dataTypeIdentifierForActivityType: .saveToFiles)
        XCTAssertEqual(filesType, UTType(filenameExtension: "md")?.identifier)
    }

    func testAppleNotesReceivesFormattedRichText() throws {
        let markdown = "# Meeting Notes\n\nAction items:\n- **First** item\n- *Second* item"
        let fileURL = try makeTemporaryFile(title: "NotesDoc", content: markdown)
        let source = DocumentExporter.Source(text: markdown, flavor: .commonMark, fileURL: fileURL, title: "NotesDoc")
        let html = DocumentExporter.clipboardHTML(for: source)

        let shareSource = DocumentShareItemSource(title: "NotesDoc", text: markdown, html: html, fileURL: fileURL)
        let dummyVC = UIActivityViewController(activityItems: [shareSource], applicationActivities: nil)

        let notesActivity = UIActivity.ActivityType("com.apple.mobilenotes.SharingExtension")
        let notesItem = shareSource.activityViewController(dummyVC, itemForActivityType: notesActivity)

        let attributed = try XCTUnwrap(notesItem as? NSAttributedString, "Notes receives an attributed string from HTML")
        XCTAssertTrue(attributed.string.contains("Meeting Notes"))
        XCTAssertTrue(attributed.string.contains("First item"))
        XCTAssertFalse(attributed.string.contains("**First**"), "Markdown markers are rendered, not literal text")

        let notesType = shareSource.activityViewController(dummyVC, dataTypeIdentifierForActivityType: notesActivity)
        XCTAssertEqual(notesType, UTType.html.identifier)
    }

    func testMailAndMessagesReceivePlainTextWithSubject() throws {
        let markdown = "Quick update on the project status."
        let shareSource = DocumentShareItemSource(title: "Status Update", text: markdown, html: "<p>\(markdown)</p>", fileURL: nil)
        let dummyVC = UIActivityViewController(activityItems: [shareSource], applicationActivities: nil)

        // Mail receives plain text and sets the subject
        let mailItem = shareSource.activityViewController(dummyVC, itemForActivityType: .mail)
        XCTAssertEqual(mailItem as? String, markdown)
        let subject = shareSource.activityViewController(dummyVC, subjectForActivityType: .mail)
        XCTAssertEqual(subject, "Status Update")

        // Messages receives plain text
        let messageItem = shareSource.activityViewController(dummyVC, itemForActivityType: .message)
        XCTAssertEqual(messageItem as? String, markdown)
    }

    func testNotionAndGeneralTargetsReceivePlainText() throws {
        let markdown = "## Notion Page\n\nContent to be imported into Notion."
        let shareSource = DocumentShareItemSource(title: "Notion Page", text: markdown, html: "<h2>Notion Page</h2>", fileURL: nil)
        let dummyVC = UIActivityViewController(activityItems: [shareSource], applicationActivities: nil)

        let notionActivity = UIActivity.ActivityType("com.notion.id.NotionShareExtension")
        let notionItem = shareSource.activityViewController(dummyVC, itemForActivityType: notionActivity)
        XCTAssertEqual(notionItem as? String, markdown, "Notion receives plain text Markdown")

        let generalItem = shareSource.activityViewController(dummyVC, itemForActivityType: nil)
        XCTAssertEqual(generalItem as? String, markdown, "Unknown/unspecified activity receives plain text Markdown")
    }

    func testUnsavedDocumentCreatesTemporaryMarkdownFile() throws {
        let markdown = "# Draft\n\nUnsaved content."
        let shareSource = DocumentShareItemSource(title: "Draft Doc", text: markdown, html: "<h1>Draft</h1>", fileURL: nil)

        XCTAssertTrue(FileManager.default.fileExists(atPath: shareSource.fileURL.path))
        XCTAssertEqual(shareSource.fileURL.pathExtension, "md")
        let content = try String(contentsOf: shareSource.fileURL, encoding: .utf8)
        XCTAssertEqual(content, markdown)

        // Clean up temporary file
        tempFiles.append(shareSource.fileURL)
    }

    func testLinkMetadataProvidesTitleAndURL() throws {
        let fileURL = try makeTemporaryFile(title: "Project", content: "# Project")
        let shareSource = DocumentShareItemSource(title: "Project Title", text: "# Project", html: "<h1>Project</h1>", fileURL: fileURL)
        let dummyVC = UIActivityViewController(activityItems: [shareSource], applicationActivities: nil)

        let metadata = try XCTUnwrap(shareSource.activityViewControllerLinkMetadata(dummyVC))
        XCTAssertEqual(metadata.title, "Project Title")
        XCTAssertEqual(metadata.originalURL, fileURL)
        XCTAssertEqual(metadata.url, fileURL)
    }

    func testDocumentShareItemTransferable() {
        let item = DocumentShareItem(title: "Doc", text: "# Title", flavor: .commonMark, fileURL: nil)
        XCTAssertEqual(item.title, "Doc")
        XCTAssertEqual(item.text, "# Title")
        XCTAssertTrue(item.html.contains("Title"))
    }
}

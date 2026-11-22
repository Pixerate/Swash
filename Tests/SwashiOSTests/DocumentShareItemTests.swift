//
//  DocumentShareItemTests.swift
//  SwashiOSTests
//
//  Tests for iOS document sharing and export activities (#182, #183):
//  - DocumentShareItemSource representations (AirDrop, Save to Files, Notes, Print, Mail, Messages, Notion)
//  - ExportPDFActivity, ExportHTMLActivity, CopyRichTextActivity, CopyHTMLActivity
//  - Toolbar and navigation title menu (UIDocumentProperties) share sheet configuration
//

import UIKit
import SwiftUI
import UniformTypeIdentifiers
import LinkPresentation
import XCTest
import PixerateMarkdown
@testable import Swash

@MainActor
final class DocumentShareItemTests: XCTestCase {
    private var tempFiles: [URL] = []

    override func tearDown() {
        IOSPresenter.onPresent = nil
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

    // MARK: - Share Sheet Activities & Print Formatter (#183)

    func testShareSheetIncludesExportCopyActivitiesAndPrintFormatter() throws {
        let markdown = "# Quarterly Report\n\nSummary with **bold** and `code`."
        let fileURL = try makeTemporaryFile(title: "Quarterly Report", content: markdown)
        let source = DocumentExporter.Source(
            text: markdown,
            flavor: .github,
            fileURL: fileURL,
            title: "Quarterly Report"
        )
        let model = IOSDocumentFeaturesModel()

        var presentedController: UIActivityViewController?
        IOSPresenter.onPresent = { vc in
            presentedController = vc as? UIActivityViewController
        }

        IOSPresenter.shareDocument(source: source, model: model)
        let activityVC = try XCTUnwrap(presentedController)
        XCTAssertEqual(activityVC.value(forKey: "subject") as? String, "Quarterly Report")

        let activities = IOSPresenter.documentActivities(for: source, model: model)
        XCTAssertEqual(activities.count, 4)

        let exportPDF = try XCTUnwrap(activities[0] as? ExportPDFActivity)
        XCTAssertEqual(ExportPDFActivity.activityCategory, .action)
        XCTAssertEqual(exportPDF.activityType, .exportPDF)
        XCTAssertEqual(exportPDF.activityTitle, "Export as PDF")
        XCTAssertNotNil(exportPDF.activityImage)
        XCTAssertTrue(exportPDF.canPerform(withActivityItems: []))

        let exportHTML = try XCTUnwrap(activities[1] as? ExportHTMLActivity)
        XCTAssertEqual(ExportHTMLActivity.activityCategory, .action)
        XCTAssertEqual(exportHTML.activityType, .exportHTML)
        XCTAssertEqual(exportHTML.activityTitle, "Export as HTML")
        XCTAssertNotNil(exportHTML.activityImage)
        XCTAssertTrue(exportHTML.canPerform(withActivityItems: []))

        let copyRichText = try XCTUnwrap(activities[2] as? CopyRichTextActivity)
        XCTAssertEqual(CopyRichTextActivity.activityCategory, .action)
        XCTAssertEqual(copyRichText.activityType, .copyRichText)
        XCTAssertEqual(copyRichText.activityTitle, "Copy as Rich Text")
        XCTAssertNotNil(copyRichText.activityImage)
        XCTAssertTrue(copyRichText.canPerform(withActivityItems: []))

        let copyHTML = try XCTUnwrap(activities[3] as? CopyHTMLActivity)
        XCTAssertEqual(CopyHTMLActivity.activityCategory, .action)
        XCTAssertEqual(copyHTML.activityType, .copyHTML)
        XCTAssertEqual(copyHTML.activityTitle, "Copy HTML")
        XCTAssertNotNil(copyHTML.activityImage)
        XCTAssertTrue(copyHTML.canPerform(withActivityItems: []))
    }

    func testPrintActivityReceivesMarkupPrintFormatter() throws {
        let markdown = "# Printable Note\n\nParagraph for printing."
        let source = DocumentExporter.Source(
            text: markdown,
            flavor: .commonMark,
            fileURL: nil,
            title: "Printable Note"
        )
        let shareSource = DocumentShareItemSource(source: source)
        let dummyVC = UIActivityViewController(activityItems: [shareSource], applicationActivities: nil)

        let printItem = shareSource.activityViewController(dummyVC, itemForActivityType: .print)
        let formatter = try XCTUnwrap(printItem as? UIMarkupTextPrintFormatter)
        XCTAssertTrue(formatter.markupText?.contains("Printable Note") == true)
        tempFiles.append(shareSource.fileURL)
    }

    func testTitleMenuDocumentPropertiesProvidesShareSheet() throws {
        let markdown = "# Title Menu Doc\n\nChecking title menu share sheet."
        let fileURL = try makeTemporaryFile(title: "TitleMenuDoc", content: markdown)
        let source = DocumentExporter.Source(
            text: markdown,
            flavor: .commonMark,
            fileURL: fileURL,
            title: "TitleMenuDoc"
        )
        let model = IOSDocumentFeaturesModel()

        let nav = UINavigationController()
        let host = UIViewController()
        let bridge = DocumentShareBridge.Controller()
        nav.viewControllers = [host]
        host.addChild(bridge)
        host.view.addSubview(bridge.view)
        bridge.didMove(toParent: host)
        bridge.configure(source: source, model: model)

        let properties = try XCTUnwrap(host.navigationItem.documentProperties)
        let provider = try XCTUnwrap(properties.activityViewControllerProvider)
        let activityVC = provider()
        XCTAssertEqual(activityVC.value(forKey: "subject") as? String, "TitleMenuDoc")
    }

    func testCopyRichTextAndCopyHTMLActivitiesUpdatePasteboard() {
        let markdown = "# Clipboard Heading\n\nA **bold** word."
        let source = DocumentExporter.Source(
            text: markdown,
            flavor: .commonMark,
            fileURL: nil,
            title: "ClipboardDoc"
        )

        let copyHTMLActivity = CopyHTMLActivity(source: source)
        copyHTMLActivity.perform()
        let copiedHTML = UIPasteboard.general.string ?? ""
        XCTAssertEqual(copiedHTML, DocumentExporter.bodyHTML(for: source, embedImages: false))
        XCTAssertTrue(copiedHTML.contains("<strong>bold</strong>"))

        let copyRichTextActivity = CopyRichTextActivity(source: source)
        copyRichTextActivity.perform()
        XCTAssertEqual(UIPasteboard.general.string, markdown)
        let htmlItem = UIPasteboard.general.value(forPasteboardType: UTType.html.identifier)
        XCTAssertNotNil(htmlItem)
    }

    func testExportHTMLAndPDFActivitiesProduceUnchangedOutputAndShareFile() async throws {
        let markdown = "# Export Check\n\nTesting export output."
        let source = DocumentExporter.Source(
            text: markdown,
            flavor: .commonMark,
            fileURL: nil,
            title: "Export Check"
        )
        let model = IOSDocumentFeaturesModel()

        var sharedControllers: [UIActivityViewController] = []
        IOSPresenter.onPresent = { vc in
            if let activityVC = vc as? UIActivityViewController {
                sharedControllers.append(activityVC)
            }
        }

        // Verify HTML export activity output matches DocumentExporter.standaloneHTML
        let htmlURL: URL = try await withCheckedThrowingContinuation { continuation in
            let htmlActivity = ExportHTMLActivity(source: source, model: model) { result in
                continuation.resume(with: result)
            }
            htmlActivity.perform()
        }
        tempFiles.append(htmlURL.deletingLastPathComponent())
        XCTAssertEqual(htmlURL.lastPathComponent, "Export Check.html")
        let exportedHTML = try String(contentsOf: htmlURL, encoding: .utf8)
        let expectedHTML = try await DocumentExporter.standaloneHTML(for: source)
        XCTAssertEqual(exportedHTML, expectedHTML)
        XCTAssertEqual(sharedControllers.count, 1)
        XCTAssertNil(model.exporting)

        // Verify PDF export activity output matches DocumentExporter.exportPDF
        let pdfURL: URL = try await withCheckedThrowingContinuation { continuation in
            let pdfActivity = ExportPDFActivity(source: source, model: model) { result in
                continuation.resume(with: result)
            }
            pdfActivity.perform()
        }
        tempFiles.append(pdfURL.deletingLastPathComponent())
        XCTAssertEqual(pdfURL.lastPathComponent, "Export Check.pdf")
        let exportedPDFData = try Data(contentsOf: pdfURL)
        let expectedPDFData = try await DocumentExporter.exportPDF(source)
        XCTAssertGreaterThan(exportedPDFData.count, 0)
        XCTAssertEqual(exportedPDFData.prefix(8), expectedPDFData.prefix(8))
        XCTAssertEqual(sharedControllers.count, 2)
        XCTAssertNil(model.exporting)
    }

    // MARK: - DocumentShareItemSource (#182)

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
        tempFiles.append(shareSource.fileURL)
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
        tempFiles.append(shareSource.fileURL)
    }

    func testUnsavedDocumentCreatesTemporaryMarkdownFile() throws {
        let markdown = "# Draft\n\nUnsaved content."
        let shareSource = DocumentShareItemSource(title: "Draft Doc", text: markdown, html: "<h1>Draft</h1>", fileURL: nil)

        XCTAssertTrue(FileManager.default.fileExists(atPath: shareSource.fileURL.path))
        XCTAssertEqual(shareSource.fileURL.pathExtension, "md")
        let content = try String(contentsOf: shareSource.fileURL, encoding: .utf8)
        XCTAssertEqual(content, markdown)

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

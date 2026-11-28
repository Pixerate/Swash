//
//  DocumentCommands.swift
//  Swash
//
//  Menu commands that act on the focused document window (copy links, outline) and the
//  focused values ContentView publishes for them.
//

#if os(macOS)
import SwiftUI
import AppKit
import PixerateMarkdown

enum DocumentCommand {
    case copyHeadingLink, copyMarkdownLink, copyFilePath
    case acceptSuggestion, dismissSuggestion, togglePartnerPause
    case reviewPartnerMarks, nextPartnerMark, previousPartnerMark
    case showPartnerEdits
}

struct DocumentCommandHandlerKey: FocusedValueKey {
    typealias Value = (DocumentCommand) -> Void
}

struct DocumentFileURLKey: FocusedValueKey {
    typealias Value = URL
}

/// Whether the focused window shows the heading outline, for View › Show Outline.
struct OutlineVisibilityKey: FocusedValueKey {
    typealias Value = Binding<Bool>
}

/// Whether the focused window shows Pixie's chat, for View › Show Pixie.
struct PixieVisibilityKey: FocusedValueKey {
    typealias Value = Binding<Bool>
}

/// Whether the writing partner is paused for the focused document (#112).
struct PartnerPausedKey: FocusedValueKey {
    typealias Value = Binding<Bool>
}

/// The focused document's view mode and a way to switch it, for the View menu.
struct ViewModeSelection {
    let current: ViewMode
    let select: (ViewMode) -> Void
}

struct ViewModeSelectionKey: FocusedValueKey {
    typealias Value = ViewModeSelection
}

extension FocusedValues {
    var viewModeSelection: ViewModeSelection? {
        get { self[ViewModeSelectionKey.self] }
        set { self[ViewModeSelectionKey.self] = newValue }
    }

    var documentCommandHandler: ((DocumentCommand) -> Void)? {
        get { self[DocumentCommandHandlerKey.self] }
        set { self[DocumentCommandHandlerKey.self] = newValue }
    }

    var documentFileURL: URL? {
        get { self[DocumentFileURLKey.self] }
        set { self[DocumentFileURLKey.self] = newValue }
    }

    var outlineVisibility: Binding<Bool>? {
        get { self[OutlineVisibilityKey.self] }
        set { self[OutlineVisibilityKey.self] = newValue }
    }

    var pixieVisibility: Binding<Bool>? {
        get { self[PixieVisibilityKey.self] }
        set { self[PixieVisibilityKey.self] = newValue }
    }

    var partnerPaused: Binding<Bool>? {
        get { self[PartnerPausedKey.self] }
        set { self[PartnerPausedKey.self] = newValue }
    }
}

/// Edit menu "Copy …" items and the View menu's view modes and outline toggle.
struct DocumentMenuCommands: Commands {
    @FocusedValue(\.documentCommandHandler) private var handler
    @FocusedValue(\.viewModeSelection) private var viewMode
    @FocusedValue(\.documentFileURL) private var fileURL
    @FocusedValue(\.outlineVisibility) private var showOutline
    @FocusedValue(\.pixieVisibility) private var showPixie
    @FocusedValue(\.partnerPaused) private var partnerPaused

    var body: some Commands {
        CommandGroup(after: .undoRedo) {
            Divider()
            Button("Accept Suggestion") {
                if !NSApp.sendAction(#selector(SwashNSTextView.acceptSuggestion(_:)), to: nil, from: nil) {
                    handler?(.acceptSuggestion)
                }
            }
            .keyboardShortcut(.return, modifiers: .option)
            .disabled(handler == nil)
            Button("Dismiss Suggestion") {
                if !NSApp.sendAction(#selector(SwashNSTextView.dismissSuggestion(_:)), to: nil, from: nil) {
                    handler?(.dismissSuggestion)
                }
            }
            .disabled(handler == nil)
            Button(partnerPaused?.wrappedValue == true ? "Resume Writing Partner" : "Pause Writing Partner") {
                if !NSApp.sendAction(#selector(SwashNSTextView.toggleWritingPartnerPause(_:)), to: nil, from: nil) {
                    handler?(.togglePartnerPause)
                }
            }
            .keyboardShortcut("p", modifiers: [.command, .option])
            .disabled(handler == nil)
            // What the partner isn't sure about (#128)
            Button("Review What to Check") {
                if !NSApp.sendAction(#selector(SwashNSTextView.reviewPartnerMarks(_:)), to: nil, from: nil) {
                    handler?(.reviewPartnerMarks)
                }
            }
            .keyboardShortcut("'", modifiers: [.command, .option])
            .disabled(handler == nil)
            Button("Next to Check") {
                if !NSApp.sendAction(#selector(SwashNSTextView.nextPartnerMark(_:)), to: nil, from: nil) {
                    handler?(.nextPartnerMark)
                }
            }
            .keyboardShortcut("]", modifiers: [.command, .option])
            .disabled(handler == nil)
            Button("Previous to Check") {
                if !NSApp.sendAction(#selector(SwashNSTextView.previousPartnerMark(_:)), to: nil, from: nil) {
                    handler?(.previousPartnerMark)
                }
            }
            .keyboardShortcut("[", modifiers: [.command, .option])
            .disabled(handler == nil)
            Button("Show Other Choice") {
                _ = NSApp.sendAction(#selector(SwashNSTextView.nextMarkCandidate(_:)), to: nil, from: nil)
            }
            .keyboardShortcut("'", modifiers: [.command, .option, .shift])
            .disabled(handler == nil)
            // What the partner changed this session, on its Copyedit and Ghostwrite layers (#229)
            Button("Writing Partner Edits…") {
                handler?(.showPartnerEdits)
            }
            .keyboardShortcut("e", modifiers: [.command, .option, .shift])
            .disabled(handler == nil)
        }
        CommandGroup(after: .pasteboard) {
            Divider()
            Button("Copy Heading Link") { handler?(.copyHeadingLink) }
                .keyboardShortcut("c", modifiers: [.command, .control])
                .disabled(handler == nil)
            Button("Copy as Markdown Link") { handler?(.copyMarkdownLink) }
                .disabled(handler == nil || fileURL == nil)
            Button("Copy File Path") { handler?(.copyFilePath) }
                .disabled(handler == nil || fileURL == nil)
            Divider()
            // NSTextView's find bar only answers menu items: without these, ⌘F does nothing (#271).
            Menu("Find") {
                Button("Find…") { TextFinderCommand.send(.showFindInterface) }
                    .keyboardShortcut("f", modifiers: .command)
                Button("Find and Replace…") { TextFinderCommand.send(.showReplaceInterface) }
                    .keyboardShortcut("f", modifiers: [.command, .option])
                Button("Find Next") { TextFinderCommand.send(.nextMatch) }
                    .keyboardShortcut("g", modifiers: .command)
                Button("Find Previous") { TextFinderCommand.send(.previousMatch) }
                    .keyboardShortcut("g", modifiers: [.command, .shift])
                // No ⌘E: it is Format › Inline Code (shared format manifest).
                Button("Use Selection for Find") { TextFinderCommand.send(.setSearchString) }
            }
            .disabled(handler == nil)
        }
        CommandGroup(before: .toolbar) {
            ForEach(Array(ViewMode.menuOrder.enumerated()), id: \.element) { index, mode in
                Toggle(mode.rawValue, isOn: Binding(
                    get: { viewMode?.current == mode },
                    set: { if $0 { viewMode?.select(mode) } }
                ))
                .keyboardShortcut(KeyEquivalent(Character(String(index + 1))), modifiers: .command)
                .disabled(viewMode == nil)
            }
            Divider()
            Button(showOutline?.wrappedValue == true ? "Hide Outline" : "Show Outline") { showOutline?.wrappedValue.toggle() }
                .keyboardShortcut("s", modifiers: [.command, .control])
                .disabled(showOutline == nil)
            Button(showPixie?.wrappedValue == true ? "Hide Pixie" : "Show Pixie") { showPixie?.wrappedValue.toggle() }
                .keyboardShortcut("i", modifiers: [.command, .option])
                .disabled(showPixie == nil)
            Divider()
        }
    }
}

/// The text written by the "Copy …" commands, kept free of UI so it is easy to check.
enum DocumentLinkText {
    /// `[Heading](#anchor)` for the heading whose section contains `location`.
    static func headingLink(in outline: MarkdownOutline, at location: Int) -> String? {
        guard let index = outline.headingIndex(containing: location) else { return nil }
        let heading = outline.headings[index]
        return "[\(MarkdownOutline.escapeLinkText(heading.title))](#\(heading.anchor))"
    }

    /// `[Title](file:///…)` linking to the document file.
    static func markdownLink(title: String, fileURL: URL) -> String {
        "[\(MarkdownOutline.escapeLinkText(title))](\(fileURL.absoluteString))"
    }

    static func copy(_ string: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(string, forType: .string)
    }
}

/// Sends an `NSTextFinder` action to the focused text view, the way AppKit's standard Find menu
/// items do: `performTextFinderAction(_:)` reads the action from the sender's `tag`.
enum TextFinderCommand {
    @discardableResult
    static func send(_ action: NSTextFinder.Action) -> Bool {
        let sender = NSMenuItem()
        sender.tag = action.rawValue
        return NSApp.sendAction(#selector(NSResponder.performTextFinderAction(_:)), to: nil, from: sender)
    }
}

#endif

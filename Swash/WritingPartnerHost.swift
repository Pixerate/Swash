//
//  WritingPartnerHost.swift
//  Swash
//
//  What the writing partner's session (WritingPartnerSession.swift) needs from an editor, so the
//  same session runs in the Mac's NSTextView and in the iOS editors (#109). Every offset here is a
//  raw-Markdown UTF-16 offset: the host maps them to its own text storage (GOTCHAS #9).
//

import Foundation
import CoreGraphics
import PixerateCore
import PixerateMarkdown

/// The editor the partner works in.
protocol WritingPartnerHost: AnyObject {
    /// The document's raw Markdown, as it is in the editor now.
    var partnerRawText: String { get }
    /// The selection, in raw offsets.
    var partnerRawSelection: NSRange { get }
    /// Moves the selection (raw offsets), optionally scrolling it into view.
    func setPartnerRawSelection(_ range: NSRange, scrollToVisible: Bool)
    var partnerFlavor: MarkdownFlavor { get }
    /// Whether the editor shows the Markdown styled (Edit Text), rather than its source.
    var partnerIsStyled: Bool { get }
    /// The parsed document for `text`, reusing the editor's cached parse when `text` is current.
    func partnerDocument(for text: String) -> MarkdownDocument
    /// Whether the editor is on screen and editable: the partner only acts then.
    var partnerCanEdit: Bool { get }
    /// Whether the editor is on screen (animations are skipped off screen).
    var partnerIsOnScreen: Bool { get }
    /// Whether an input method is composing (marked text): the partner never edits then.
    var partnerHasMarkedText: Bool { get }
    var partnerUndoManager: UndoManager? { get }
    /// Replaces the text with `newRawText` as one undo step named `actionName`, apart from the
    /// person's typing on either side, and puts the caret at `rawSelection`.
    func applyPartnerEdit(newRawText: String, rawSelection: NSRange, actionName: String)
    /// Turns the system's own autocorrect and inline predictions off while the partner is on, and
    /// back to what they were when it's off: both write at the caret and fight the partner's fixes.
    func setSystemTextAssistsSuppressed(_ suppressed: Bool)
    /// The system spell checker's correction for the word at `range` of `text`, if any.
    func partnerSpellingCorrection(forWordRange range: NSRange, in text: String) -> String?
    /// Tells the system spell checker to leave `words` alone in this document.
    func partnerIgnoreSpelling(_ words: [String])
    /// Speaks `text` to VoiceOver.
    func partnerAnnounce(_ text: String)
    /// Where the partner draws, made on first use.
    var partnerCanvas: (any WritingPartnerCanvas)? { get }
    /// The rectangles (in the canvas's coordinates) that `range` of the raw text covers.
    func partnerRects(forRaw range: NSRange) -> [CGRect]
    /// The caret rectangle at a raw offset (canvas coordinates).
    func partnerCaretRect(atRaw location: Int) -> CGRect?
    var partnerReducesMotion: Bool { get }
    /// The message shown the first time someone undoes one of the partner's fixes: it names how to
    /// pause the partner on this platform.
    var partnerUndoReminderText: String { get }
}

/// Where the partner draws: the sweep over checked words, suggestion and mark underlines, its
/// cursor and the word it is typing, and the notes it shows in place. Never changes the text.
protocol WritingPartnerCanvas: AnyObject {
    func sweep(_ rects: [CGRect])
    func showSuggestions(_ rects: [CGRect])
    func showMarks(_ rects: [CGRect])
    /// Starts drawing `carets` and the word `target` is typing.
    func attach(carets: AgentCaretStore, target: WritingPartnerTarget)
    /// Redraws the partner's cursor and the word it is typing.
    func renderPartner()
    func showIntroduction(at rect: CGRect, onChooseMode: @escaping (WritingPartnerMode) -> Void, onDismiss: @escaping () -> Void)
    func hideIntroduction()
    func showUndoReminder(at rect: CGRect, text: String, onPause: @escaping () -> Void, onDismiss: @escaping () -> Void)
    func hideUndoReminder()
    func showSuggestionPrompt(suggestion: JazzTextSuggestion, at rect: CGRect,
                              onAccept: @escaping () -> Void, onDismiss: @escaping () -> Void)
    func hideSuggestionPrompt()
}

/// Words the partner says, shared by the Mac and iOS notes.
enum WritingPartnerCopy {
    static let introduction = "Swash can tidy up behind you as you type"

    /// "your Mac", "your iPad" or "your iPhone".
    nonisolated static var device: String {
        #if os(macOS)
        return "your Mac"
        #else
        return isPad ? "your iPad" : "your iPhone"
        #endif
    }

    #if os(iOS)
    nonisolated(unsafe) static var isPad = false
    #endif

    nonisolated static var privacy: String {
        "Punctuation and spelling rules run on \(device) and never leave this device."
    }

    /// With Swash Pro, the pause tier sends the paragraph to Pixerate (docs/writing-partner-privacy.md),
    /// so the introduction says so before the person chooses.
    nonisolated static var signedInPrivacy: String {
        "Fixes as you type run on \(device). With Swash Pro, the paragraph you pause on is also sent to Pixerate for suggestions."
    }

    nonisolated static func privacy(signedIn: Bool) -> String {
        signedIn ? signedInPrivacy : privacy
    }
}

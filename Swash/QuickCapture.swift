//
//  QuickCapture.swift
//  Swash
//
//  Quick Note: a floating panel, summoned by a global shortcut, the menu bar item or Shortcuts,
//  that turns a jotted note into a new document or appends it to the last document you used.
//  Also the menu bar item itself and the Open at Login setting.
//

#if os(macOS)
import AppKit
import SwiftUI
import Carbon.HIToolbox
import ServiceManagement

/// The document window a quick note can be appended to.
struct QuickCaptureTarget {
    let title: String
    weak var window: NSWindow?
    let append: (String) -> Void
}

@MainActor
final class QuickCaptureController: NSObject, NSWindowDelegate {
    static let shared = QuickCaptureController()

    /// The most recently focused document, set by `ContentView`.
    var target: QuickCaptureTarget?
    /// Active tidy session for the currently displayed Quick Note panel.
    private(set) var session: QuickNoteTidySession?
    private var panel: NSPanel?

    var isVisible: Bool { panel?.isVisible == true }

    func toggle() {
        isVisible ? close() : show()
    }

    func show() {
        let panel = self.panel ?? makePanel()
        self.panel = panel
        let targetTitle = target?.window != nil ? target?.title : nil
        let session = QuickNoteTidySession()
        self.session = session
        panel.contentView = NSHostingView(rootView: QuickCaptureView(
            targetTitle: targetTitle,
            session: session,
            onCreate: { [weak self] text in
                self?.close()
                NSApp.activate()
                NewDocumentSeed.createDocument(with: text)
            },
            onAppend: { [weak self] text in
                guard let self = self, let target = self.target, let window = target.window else { return }
                self.close()
                NSApp.activate()
                window.makeKeyAndOrderFront(nil)
                target.append(text)
            },
            onCancel: { [weak self] in self?.close() }
        ))
        let screen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main
        if let visible = screen?.visibleFrame {
            let size = panel.frame.size
            panel.setFrameOrigin(NSPoint(x: visible.midX - size.width / 2, y: visible.maxY - size.height - visible.height * 0.18))
        }
        panel.makeKeyAndOrderFront(nil)
    }

    func close() {
        panel?.orderOut(nil)
    }

    private func makePanel() -> NSPanel {
        let panel = QuickCapturePanel(contentRect: NSRect(x: 0, y: 0, width: 520, height: 240),
                                      styleMask: [.titled, .closable, .fullSizeContentView, .nonactivatingPanel],
                                      backing: .buffered, defer: true)
        panel.title = "Quick Note"
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.delegate = self
        return panel
    }

    // Like Spotlight, the panel goes away when you click elsewhere.
    func windowDidResignKey(_ notification: Notification) {
        close()
    }
}

/// Nonactivating panels can't take keyboard focus unless they say so.
private final class QuickCapturePanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

struct QuickCaptureView: View {
    let targetTitle: String?
    let onCreate: (String) -> Void
    let onAppend: (String) -> Void
    let onCancel: () -> Void

    @State private var session: QuickNoteTidySession

    init(
        targetTitle: String?,
        session: QuickNoteTidySession? = nil,
        onCreate: @escaping (String) -> Void,
        onAppend: @escaping (String) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.targetTitle = targetTitle
        self.onCreate = onCreate
        self.onAppend = onAppend
        self.onCancel = onCancel
        let resolvedSession = session ?? QuickNoteTidySession()
        resolvedSession.onCreate = onCreate
        resolvedSession.onAppend = onAppend
        _session = State(initialValue: resolvedSession)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Quick Note", systemImage: "square.and.pencil")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.secondary)
                Spacer()
                if session.isChecking {
                    Label("Tidying…", systemImage: "sparkles")
                        .font(.system(size: 11))
                        .foregroundColor(.purple.opacity(0.85))
                }
            }

            ZStack(alignment: .topLeading) {
                if session.text.isEmpty {
                    Text("Write in Markdown…")
                        .font(.system(size: 14))
                        .foregroundColor(.secondary.opacity(0.7))
                        .padding(.top, 1)
                        .padding(.leading, 5)
                        .allowsHitTesting(false)
                }
                QuickNoteTextView(session: session)
            }

            if let proposal = session.proposal {
                QuickNoteTidyPromptView(
                    proposal: proposal,
                    onAccept: { session.acceptProposal() },
                    onDismiss: { session.dismissProposal() }
                )
            }

            HStack {
                Text(session.proposal == nil ? "esc to dismiss" : "esc to dismiss tidy")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                Spacer()
                if let title = targetTitle {
                    Button("Add to “\(title)”") {
                        Task { await session.save(.appendToTarget) }
                    }
                    .keyboardShortcut(.return, modifiers: [.command, .option])
                    .disabled(session.isEmpty)
                    .help("Append the note to the end of \(title) (⌥⌘↩)")
                }
                Button("New Document") {
                    Task { await session.save(.createDocument) }
                }
                .keyboardShortcut(.return, modifiers: .command)
                .buttonStyle(.borderedProminent)
                .disabled(session.isEmpty)
                .help("Open the note as a new document (⌘↩)")
            }
        }
        .padding(16)
        .padding(.top, 6)
        .frame(width: 520, height: session.proposal == nil ? 240 : 320)
        .background(.regularMaterial)
        .onExitCommand {
            if session.proposal != nil {
                session.dismissProposal()
            } else {
                onCancel()
            }
        }
    }
}

/// Inline "Tidy" prompt shown when a Quick Note is paused or saved (#108).
/// Previews the proposed changes as a diff, never applying them silently.
/// Accept applies all changes as one undo step ("Tidy"); Dismiss leaves the note alone.
struct QuickNoteTidyPromptView: View {
    let proposal: QuickNoteTidyProposal
    let onAccept: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Label("Tidy", systemImage: "sparkles")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.purple)
                Text(proposal.why)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer()
                Button("Dismiss", action: onDismiss)
                    .controlSize(.small)
                    .accessibilityLabel("Dismiss tidy-up")
                Button("Accept", action: onAccept)
                    .controlSize(.small)
                    .buttonStyle(.borderedProminent)
                    .tint(.purple)
                    .accessibilityLabel("Accept tidy-up")
            }

            ScrollView(.vertical) {
                diffText
                    .font(.system(size: 12))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 54)
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.purple.opacity(0.08))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(Color.purple.opacity(0.28), lineWidth: 1)
                )
        )
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Tidy proposal: \(proposal.why)")
    }

    private var diffText: Text {
        var combined = Text("")
        for segment in proposal.diff {
            switch segment.kind {
            case .unchanged:
                combined = combined + Text(segment.text).foregroundColor(.primary)
            case .removed:
                combined = combined + Text(segment.text).strikethrough().foregroundColor(.secondary)
            case .inserted:
                combined = combined + Text(segment.text).bold().foregroundColor(.purple)
            }
        }
        return combined
    }
}

/// AppKit text view for Quick Note that shares `QuickNoteTidySession.undoManager` so accepting
/// a tidy-up proposal is always one undo step (⌘Z).
struct QuickNoteTextView: NSViewRepresentable {
    let session: QuickNoteTidySession

    func makeCoordinator() -> Coordinator {
        Coordinator(session: session)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollablePlainDocumentContentTextView()
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        if let textView = scrollView.documentView as? NSTextView {
            textView.drawsBackground = false
            textView.font = .systemFont(ofSize: 14)
            textView.textColor = .labelColor
            textView.isRichText = false
            textView.allowsUndo = true
            textView.isAutomaticQuoteSubstitutionEnabled = false
            textView.isAutomaticDashSubstitutionEnabled = false
            textView.textContainerInset = NSSize(width: 0, height: 1)
            textView.string = session.text
            textView.delegate = context.coordinator
            session.textView = textView
            DispatchQueue.main.async {
                textView.window?.makeFirstResponder(textView)
            }
        }
        return scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        context.coordinator.session = session
        guard let textView = nsView.documentView as? NSTextView else { return }
        session.textView = textView
        if textView.string != session.text {
            textView.string = session.text
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var session: QuickNoteTidySession

        init(session: QuickNoteTidySession) {
            self.session = session
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            MainActor.assumeIsolated {
                session.userDidEditText(textView.string)
            }
        }

        func undoManager(for view: NSTextView) -> UndoManager? {
            MainActor.assumeIsolated {
                session.undoManager
            }
        }
    }
}

/// Appends a note to `text` as its own paragraph.
enum QuickCaptureText {
    static func appending(_ note: String, to text: String) -> String {
        let trimmed = note.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return text }
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return trimmed + "\n" }
        let separator = text.hasSuffix("\n\n") ? "" : (text.hasSuffix("\n") ? "\n" : "\n\n")
        return text + separator + trimmed + "\n"
    }
}

// MARK: - Global shortcut

enum QuickCaptureShortcut: String, CaseIterable, Identifiable {
    case none, controlOptionCommandN, controlOptionSpace, optionShiftN

    static let defaultsKey = "quickCaptureShortcut"
    static let defaultValue: QuickCaptureShortcut = .controlOptionCommandN

    static var current: QuickCaptureShortcut {
        UserDefaults.standard.string(forKey: defaultsKey).flatMap(QuickCaptureShortcut.init(rawValue:)) ?? defaultValue
    }

    var id: String { rawValue }

    var title: String {
        switch self {
        case .none: return "None"
        case .controlOptionCommandN: return "⌃⌥⌘N"
        case .controlOptionSpace: return "⌃⌥Space"
        case .optionShiftN: return "⌥⇧N"
        }
    }

    fileprivate var keyCode: Int? {
        switch self {
        case .none: return nil
        case .controlOptionCommandN, .optionShiftN: return kVK_ANSI_N
        case .controlOptionSpace: return kVK_Space
        }
    }

    fileprivate var carbonModifiers: Int {
        switch self {
        case .none: return 0
        case .controlOptionCommandN: return controlKey | optionKey | cmdKey
        case .controlOptionSpace: return controlKey | optionKey
        case .optionShiftN: return optionKey | shiftKey
        }
    }
}

/// A system-wide shortcut through Carbon's hot keys, which work in the sandbox without
/// accessibility permission.
@MainActor
final class GlobalHotKey {
    static let shared = GlobalHotKey()
    private var hotKey: EventHotKeyRef?
    private var handler: EventHandlerRef?

    func register(_ shortcut: QuickCaptureShortcut) {
        if let hotKey = hotKey {
            UnregisterEventHotKey(hotKey)
            self.hotKey = nil
        }
        guard let keyCode = shortcut.keyCode else { return }
        if handler == nil {
            var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { QuickCaptureController.shared.toggle() }
                }
                return noErr
            }, 1, &spec, nil, &handler)
        }
        let id = EventHotKeyID(signature: OSType(0x5357_5143), id: 1) // "SWQC"
        RegisterEventHotKey(UInt32(keyCode), UInt32(shortcut.carbonModifiers), id, GetApplicationEventTarget(), 0, &hotKey)
    }
}

// MARK: - Open at Login

enum LoginItem {
    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }

    static func setEnabled(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            NSApp.presentError(error)
        }
    }
}

// MARK: - Menu bar item

struct SwashMenuBarMenu: View {
    @State private var opensAtLogin = LoginItem.isEnabled

    var body: some View {
        Button("Quick Note…") { QuickCaptureController.shared.show() }
        Button("New Document") {
            NSApp.activate()
            NSDocumentController.shared.newDocument(nil)
        }
        Button("Open…") {
            NSApp.activate()
            NSDocumentController.shared.openDocument(nil)
        }
        Menu("Open Recent") {
            ForEach(NSDocumentController.shared.recentDocumentURLs, id: \.self) { url in
                Button(url.lastPathComponent) {
                    NSApp.activate()
                    DocumentOpener.shared.open([url])
                }
            }
        }
        .disabled(NSDocumentController.shared.recentDocumentURLs.isEmpty)
        Divider()
        Toggle("Open at Login", isOn: Binding(
            get: { opensAtLogin },
            set: { LoginItem.setEnabled($0); opensAtLogin = LoginItem.isEnabled }
        ))
        SettingsLink { Text("Settings…") }
        Divider()
        Button("Quit Swash") { NSApp.terminate(nil) }
    }
}
#endif

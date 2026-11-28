// The Pixie inspector (View › Show Pixie, ⌥⌘I): `PixieUI`'s chat on the document, with her
// avatar and her skills and memory in a sheet. The whole document is what the chat is about; the
// selection reaches her in the brief. Without Swash Pro it says what unlocks her instead of
// letting a request fail.

import PixerateStore
import PixieKit
import PixieUI
import SwiftUI

struct PixieSwashPanel: View {
    let pixie: PixieSwashModel
    let store: PixerateStore
    var onClose: () -> Void

    @State private var memoryPresented = false
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        PixieChatPanel(
            chat: pixie.chat,
            onClose: onClose,
            onOpenMemory: { memoryPresented = true },
            banner: store.hasPro ? nil : AnyView(lockedNote)
        )
        .sheet(isPresented: $memoryPresented) {
            VStack(spacing: 0) {
                PixieMemoryView(placeName: "This document") {
                    try await PixieMemorySnapshot.load(placeId: "", service: pixie.service)
                }
                Divider()
                HStack {
                    Spacer()
                    Button("Close") { memoryPresented = false }.keyboardShortcut(.cancelAction)
                }
                .padding(12)
            }
            .frame(minWidth: 480, minHeight: 460)
        }
    }

    private var lockedNote: some View {
        HStack(spacing: 8) {
            Image(systemName: "lock.fill").foregroundStyle(.secondary)
            Text("Pixie's chat is part of Swash Pro.").font(.caption)
            Spacer(minLength: 0)
            Button("Settings…") { openSettings() }
                .font(.caption)
                .buttonStyle(.borderless)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Color.primary.opacity(0.04))
    }
}

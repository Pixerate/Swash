//
//  PixieSwashInspector.swift
//  Swash
//
//  The Pixie inspector's content for one document window: makes the window's `PixieSwashModel` the
//  first time it is shown and keeps its document name current. `SwashApp` hands this to
//  `ContentView.pixieInspector`, because `ContentView` is also compiled into the Quick Look
//  extension, which has neither Pixie's package nor the store (GOTCHAS).
//

#if os(macOS)
import SwiftUI

struct PixieSwashInspector: View {
    let session: AgentDocumentSession
    let documentName: String
    let onClose: () -> Void

    @State private var pixie: PixieSwashModel?

    var body: some View {
        Group {
            if let pixie {
                PixieSwashPanel(pixie: pixie, onClose: onClose)
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onAppear {
            if pixie == nil { pixie = PixieSwashModel(session: session, store: PixerateAccess.shared.store) }
            pixie?.documentName = documentName
        }
        .onChange(of: documentName) { _, name in pixie?.documentName = name }
    }

    /// For `ContentView.pixieInspector`.
    static func make(session: AgentDocumentSession, documentName: String, onClose: @escaping () -> Void) -> AnyView {
        AnyView(PixieSwashInspector(session: session, documentName: documentName, onClose: onClose))
    }
}
#endif

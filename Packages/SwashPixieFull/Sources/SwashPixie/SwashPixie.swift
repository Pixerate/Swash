// SwashPixie with Pixie: her chat on Swash documents.

import PixerateStore
import SwiftUI

public enum SwashPixie {
    /// Whether this build has Pixie.
    public static let isAvailable = true

    /// Her chat for a document window: made the first time it is shown, for that document.
    @MainActor
    public static func inspector(for document: SwashPixieDocument, store: PixerateStore, onClose: @escaping () -> Void) -> AnyView {
        AnyView(PixieSwashInspector(document: document, store: store, onClose: onClose))
    }
}

/// Makes the window's `PixieSwashModel` the first time it is shown.
struct PixieSwashInspector: View {
    let document: SwashPixieDocument
    let store: PixerateStore
    let onClose: () -> Void

    @State private var pixie: PixieSwashModel?

    var body: some View {
        Group {
            if let pixie {
                PixieSwashPanel(pixie: pixie, store: store, onClose: onClose)
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onAppear {
            if pixie == nil { pixie = PixieSwashModel(document: document, store: store) }
        }
    }
}

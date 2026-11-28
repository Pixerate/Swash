// The open-source stub: Pixie isn't in this build.

import PixerateStore
import SwiftUI

public enum SwashPixie {
    /// Whether this build has Pixie. Swash hides her toggle and menu item when it doesn't.
    public static let isAvailable = false

    /// Her chat for a document window. The stub draws nothing.
    @MainActor
    public static func inspector(for document: SwashPixieDocument, store: PixerateStore, onClose: @escaping () -> Void) -> AnyView {
        AnyView(EmptyView())
    }
}

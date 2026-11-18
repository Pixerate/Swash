//
//  WidgetTrustManager.swift
//  Swash
//
//  Permission gate for executable/sandboxed web widgets embedded in Markdown documents,
//  mirroring FolderAccessManager's explicit user-approval flow.
//

import Combine
import Foundation

@MainActor
final class WidgetTrustManager: ObservableObject {
    static let shared = WidgetTrustManager()
    static let trustDidChangeNotification = Notification.Name("WidgetTrustManagerDidChange")

    private let defaultsKey = "swash_trusted_widget_documents"
    @Published private(set) var trustedKeys: Set<String>

    init(userDefaults: UserDefaults = .standard) {
        let saved = userDefaults.stringArray(forKey: defaultsKey) ?? []
        self.trustedKeys = Set(saved)
        self.userDefaults = userDefaults
    }

    private let userDefaults: UserDefaults

    func isTrusted(documentKey: String) -> Bool {
        trustedKeys.contains(documentKey)
    }

    func grantTrust(for documentKey: String) {
        guard !trustedKeys.contains(documentKey) else { return }
        trustedKeys.insert(documentKey)
        persist()
        NotificationCenter.default.post(name: Self.trustDidChangeNotification, object: documentKey)
    }

    func revokeTrust(for documentKey: String) {
        guard trustedKeys.remove(documentKey) != nil else { return }
        persist()
        NotificationCenter.default.post(name: Self.trustDidChangeNotification, object: documentKey)
    }

    private func persist() {
        userDefaults.set(Array(trustedKeys).sorted(), forKey: defaultsKey)
    }
}

//
//  PixieSwashModel.swift
//  Swash
//
//  Pixie's chat on one Swash document: `PixieKit`'s chat over the document's agent tools
//  (`PixieSwashHost`), talking to Pixerate's Pixie routes on the `text` surface. Requests are
//  signed by Swash's store (`authorizedRequest`), so she works for a Pixerate account or an App
//  Store customer alike; Swash Pro or Pixerate Pro unlocks her (`agent.pixie-text`). Nothing is
//  sent until the person asks her something, and her chats are not stored on Pixerate: a chat
//  lasts as long as the window (docs/writing-partner-privacy.md).
//

#if os(macOS)
import Foundation
import Observation
import PixerateStore
import PixieKit

@MainActor
@Observable
final class PixieSwashModel {
    let chat: PixieChat
    let host: PixieSwashHost
    @ObservationIgnored let service: PixieService
    /// The document's name, for her brief.
    @ObservationIgnored var documentName = "Untitled"

    init(session: AgentDocumentSession, store: PixerateStore) {
        let host = PixieSwashHost(session: session)
        let service = PixieService(baseURL: store.configuration.baseURL, surface: "text") { request in
            try await PixieSwashModel.send(request, signedBy: store)
        }
        self.host = host
        self.service = service
        // No place: her threads stay in this window and are never stored on Pixerate.
        chat = PixieChat(service: service, host: { host }, placeId: { nil })
        chat.brief = { [weak self] _ in self.map { host.brief(name: $0.documentName) } }
    }

    /// Signs a Pixie request with the store (customer and account tokens) and sends it.
    nonisolated static func send(_ request: URLRequest, signedBy store: PixerateStore) async throws -> PixieHTTPResponse {
        let url = request.url!
        let path = url.path + (url.query.map { "?\($0)" } ?? "")
        let method = request.httpMethod ?? "GET"
        let body = request.httpBody
        let signed = try await MainActor.run { try store.authorizedRequest(path: path, method: method, body: body) }
        let (data, response) = try await URLSession.shared.data(for: signed)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 402 { await store.refreshEntitlements() }
        return PixieHTTPResponse(status: status, data: data)
    }
}
#endif

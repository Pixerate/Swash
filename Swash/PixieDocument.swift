//
//  PixieDocument.swift
//  Swash
//
//  A document's agent session as `SwashPixie` reads it: the same tools MCP agents use, and the
//  facts her brief needs, read when she asks for them.
//

#if os(macOS)
import Foundation
import SwashPixie

extension AgentDocumentSession {
    var pixieDocument: SwashPixieDocument {
        SwashPixieDocument(
            registry: registry,
            markdown: { [unowned self] in readMarkdown() },
            selection: { [unowned self] in readSelection() },
            flavor: { [unowned self] in flavor == .slack ? "slack" : "github" },
            readOnlyReason: { [unowned self] in readOnlyReason },
            name: { [unowned self] in name }
        )
    }
}
#endif

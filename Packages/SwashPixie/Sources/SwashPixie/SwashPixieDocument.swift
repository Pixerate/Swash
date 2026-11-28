// SwashPixie's interface, shared by the open-source stub and the full package (`SwashPixieFull`
// links this file), so Swash builds against either.

import Foundation
import PixerateCore

/// What Pixie needs from a Swash document window: its agent tools (the registry MCP agents use)
/// and a few facts about it, read when she needs them.
@MainActor
public struct SwashPixieDocument {
    /// The document's agent tools.
    public var registry: ToolRegistry
    /// The live raw Markdown.
    public var markdown: () -> String
    /// The person's selection, in raw-Markdown offsets, or nil without an editor.
    public var selection: () -> NSRange?
    /// `github` or `slack`.
    public var flavor: () -> String
    /// Why the document can't be edited, or nil when it can.
    public var readOnlyReason: () -> String?
    /// The document's name.
    public var name: () -> String

    public init(
        registry: ToolRegistry,
        markdown: @escaping () -> String,
        selection: @escaping () -> NSRange?,
        flavor: @escaping () -> String,
        readOnlyReason: @escaping () -> String?,
        name: @escaping () -> String
    ) {
        self.registry = registry
        self.markdown = markdown
        self.selection = selection
        self.flavor = flavor
        self.readOnlyReason = readOnlyReason
        self.name = name
    }
}

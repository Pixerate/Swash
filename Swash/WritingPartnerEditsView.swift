//
//  WritingPartnerEditsView.swift
//  Swash
//
//  Writing Partner Edits (#229): what the partner changed this session, on its Copyedit and
//  Ghostwrite layers, apart from what the person typed. Each edit, or a whole layer, can be
//  reverted on its own, as one undo step, without undoing anything typed since. Shared by the
//  Mac (Edit › Writing Partner Edits) and iOS (the editor's menu).
//

import SwiftUI

struct WritingPartnerEditsView: View {
    /// The edits as they stand now.
    let load: () -> [LayeredEdit]
    /// Reverts the edits with these ids; returns how many it reverted.
    let revert: (Set<Int>) -> Int
    var onDone: (() -> Void)? = nil

    @State private var edits: [LayeredEdit] = []
    @State private var status: String?

    var body: some View {
        NavigationStack {
            Group {
                if edits.isEmpty {
                    ContentUnavailableView {
                        Label("No Edits Yet", systemImage: "pencil.and.scribble")
                    } description: {
                        Text("What the writing partner changes while this document is open is listed here, apart from what you type.")
                    }
                } else {
                    List {
                        ForEach(PartnerEditLayer.partnerLayers) { layer in
                            let onLayer = edits.filter { $0.layer == layer }
                            if !onLayer.isEmpty {
                                Section {
                                    ForEach(onLayer) { edit in
                                        WritingPartnerEditRow(edit: edit) { perform(revert: [edit.id]) }
                                    }
                                } header: {
                                    HStack {
                                        Text("\(layer.title) · \(onLayer.count)")
                                        Spacer()
                                        Button("Revert All") { perform(revert: Set(onLayer.map(\.id))) }
                                            .font(.caption)
                                            .accessibilityLabel("Revert all \(layer.title) edits")
                                    }
                                }
                            }
                        }
                        Section {
                        } footer: {
                            Text("Your own typing is never reverted. These layers last while the document is open; the saved file has the text as it reads now.")
                        }
                    }
                }
            }
            .navigationTitle("Writing Partner Edits")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { onDone?() }
                }
            }
            .safeAreaInset(edge: .bottom) {
                if let status {
                    Text(status)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .padding(8)
                }
            }
        }
        .onAppear { edits = load() }
        #if os(macOS)
        .frame(minWidth: 420, minHeight: 360)
        #endif
    }

    private func perform(revert ids: Set<Int>) {
        let count = revert(ids)
        edits = load()
        status = count == 0 ? "Nothing to revert: that text has changed since." : (count == 1 ? "Reverted 1 edit." : "Reverted \(count) edits.")
    }
}

private struct WritingPartnerEditRow: View {
    let edit: LayeredEdit
    let onRevert: () -> Void

    private static func shown(_ text: String) -> String {
        let trimmed = text.replacingOccurrences(of: "\n", with: "⏎")
        return trimmed.isEmpty ? "(nothing)" : (trimmed.count > 80 ? String(trimmed.prefix(80)) + "…" : trimmed)
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text("\(Text(Self.shown(edit.original)).strikethrough().foregroundStyle(.secondary))  →  \(Text(Self.shown(edit.replacement)))")
                    .lineLimit(3)
                if !edit.rules.isEmpty {
                    Text(edit.rules.map(\.title).joined(separator: ", "))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 8)
            Button("Revert", action: onRevert)
                .buttonStyle(.borderless)
                .accessibilityLabel("Revert \(edit.replacement) to \(edit.original)")
        }
        .accessibilityElement(children: .combine)
        .accessibilityAction(named: "Revert", onRevert)
    }
}

#Preview("Writing Partner Edits") {
    @Previewable @State var stack: EditLayerStack = {
        var stack = EditLayerStack()
        stack.record(range: NSRange(location: 0, length: 1), original: "i", replacement: "I", layer: .copyedit, rules: [.pronounI])
        stack.record(range: NSRange(location: 2, length: 5), original: "dont", replacement: "don't", layer: .copyedit, rules: [.contraction])
        stack.record(range: NSRange(location: 20, length: 33), original: "met sam, budget ok",
                     replacement: "We met Sam and agreed the budget.", layer: .ghostwrite)
        return stack
    }()
    WritingPartnerEditsView(load: { stack.edits }, revert: { ids in
        stack.remove(ids)
        return ids.count
    })
}

#Preview("Writing Partner Edits - Empty") {
    WritingPartnerEditsView(load: { [] }, revert: { _ in 0 })
}

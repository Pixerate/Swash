//
//  WritingPartnerStyleSettings.swift
//  Swash
//
//  Settings › Writing: how the writing partner's fixes look (#100). The styles are Flair's text
//  treatments, and the preview plays the chosen one on a sample sentence: the partner's cursor
//  selects a misspelt word, types the right one over it, and the fix lands.
//

#if os(macOS)
import AppKit
import FlairEffects
import SwiftUI

/// The "Partner style" picker and its preview.
struct WritingPartnerStyleSection: View {
    @AppStorage(WritingPartnerDefaults.style) private var style = WritingPartnerDefaults.defaultStyle

    /// Every treatment, the partner's default first.
    private var styles: [FlairTextTreatment] {
        FlairTextTreatments.all.sorted { a, b in
            (a.id == WritingPartnerDefaults.defaultStyle ? 0 : 1) < (b.id == WritingPartnerDefaults.defaultStyle ? 0 : 1)
        }
    }

    var body: some View {
        Section {
            Picker("Partner style", selection: $style) {
                ForEach(styles, id: \.id) { treatment in
                    Text(treatment.name).tag(treatment.id)
                }
            }
            WritingPartnerStylePreview(style: style)
                .frame(height: 64)
                .accessibilityLabel("A preview of the partner fixing a misspelt word in this style")
        } footer: {
            // Other targets compile this file without SettingsView's footer style
            Text(FlairTextTreatments.treatment(id: style)?.description ?? "")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }
}

private struct WritingPartnerStylePreview: NSViewRepresentable {
    let style: String

    func makeNSView(context: Context) -> WritingPartnerStylePreviewView { WritingPartnerStylePreviewView() }

    func updateNSView(_ view: WritingPartnerStylePreviewView, context: Context) { view.style = style }
}

#Preview("Partner style") {
    Form { WritingPartnerStyleSection() }
        .formStyle(.grouped)
        .frame(width: 480)
}

#Preview("First-run introduction (#112)") {
    let view = PartnerIntroductionView(frame: NSRect(origin: .zero, size: PartnerIntroductionView.preferredSize))
    view.configure(onChooseMode: { _ in }, onDismiss: {})
    return view
}

#Preview("First-undo reminder (#112)") {
    let view = PartnerUndoReminderView(frame: NSRect(origin: .zero, size: PartnerUndoReminderView.preferredSize))
    view.configure(onPause: {}, onDismiss: {})
    return view
}
#endif

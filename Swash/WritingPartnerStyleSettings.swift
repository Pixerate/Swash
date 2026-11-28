//
//  WritingPartnerStyleSettings.swift
//  Swash
//
//  Settings › Writing: how the writing partner's fixes look (#100). The styles are Flair's text
//  treatments, and the preview plays the chosen one on a sample sentence as the chosen level would
//  (#229): nothing for Off, a misspelt word fixed for Copyedit, rough notes rewritten for Ghostwrite.
//

#if os(macOS)
import AppKit
import FlairEffects
import SwiftUI

/// The "Partner style" picker and its preview of `level`.
struct WritingPartnerStyleSection: View {
    var level: WritingPartnerMode = .copyedit
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
            WritingPartnerStylePreview(style: style, level: level)
                .frame(height: 64)
                .accessibilityLabel(WritingPartnerPreviewScript.script(for: level).accessibilityLabel)
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
    let level: WritingPartnerMode

    func makeNSView(context: Context) -> WritingPartnerStylePreviewView { WritingPartnerStylePreviewView() }

    func updateNSView(_ view: WritingPartnerStylePreviewView, context: Context) {
        view.style = style
        view.level = level
    }
}

#Preview("Partner style") {
    @Previewable @State var level = WritingPartnerMode.copyedit
    Form {
        Picker("Level", selection: $level) {
            ForEach(WritingPartnerMode.allCases) { Text($0.title).tag($0) }
        }
        .pickerStyle(.segmented)
        WritingPartnerStyleSection(level: level)
    }
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

// MARK: - Previews

#Preview("Writing Partner Style Section - Ghostwrite", traits: .sectionContainer) {
    WritingPartnerStyleSection(level: .ghostwrite)
}

#Preview("Writing Partner Style Section - Off", traits: .sectionContainer) {
    WritingPartnerStyleSection(level: .off)
}
#endif

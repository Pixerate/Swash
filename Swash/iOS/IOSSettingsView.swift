//
//  IOSSettingsView.swift
//  Swash
//
//  Settings sheet for iPhone and iPad. Updates come from the App Store and file associations
//  from the document types, so only the Mac's general settings apply here.
//

#if os(iOS)
import SwiftUI
import PixerateStickers
import PixerateStore

struct IOSSettingsView: View {
    @AppStorage("markdownFlavor") private var markdownFlavor: MarkdownFlavor = .github
    @Environment(\.dismiss) private var dismiss
    var access: PixerateAccess = .shared

    private var versionString: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "–"
        let build = info?["CFBundleVersion"] as? String ?? "–"
        return "\(version) (\(build))"
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("General") {
                    Picker("Markdown Scheme", selection: $markdownFlavor) {
                        ForEach(MarkdownFlavor.allCases) { flavor in
                            Text(flavor.rawValue).tag(flavor)
                        }
                    }
                }
                Section {
                    NavigationLink {
                        IOSWritingPartnerSettings()
                    } label: {
                        LabeledContent("Writing Partner",
                                       value: (WritingPartnerMode(rawValue: UserDefaults.standard.string(forKey: WritingPartnerDefaults.mode) ?? "") ?? .copyedit).title)
                    }
                }
                IOSTypographySettingsSections()
                PixerateAccountSections(access: access)
                if StickerCatalog.isAvailable {
                    StickerSetsSection()
                }
                Section {
                    LabeledContent("Version", value: versionString)
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .sheetRootNavigation()
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .horizontalBarsOnly()
        }
        .task {
            guard !access.isPreview else { return }
            await access.start()
        }
        .onAppear {
            access.clearLastError()
        }
    }
}

extension View {
    /// Keeps a control-heavy sheet's bar horizontal on the iPhone Duo (iOS 27.1). A single text
    /// button ("Done") gains nothing from a vertical bar and would cost the form its width (#65).
    @ViewBuilder
    func horizontalBarsOnly() -> some View {
        if #available(iOS 27.1, *) {
            toolbarVerticalBehavior(.disabled)
        } else {
            self
        }
    }
}

#Preview("iOS Settings") {
    IOSSettingsView()
}

#Preview("iOS Settings - Dark Mode") {
    IOSSettingsView()
        .preferredColorScheme(.dark)
}
#endif

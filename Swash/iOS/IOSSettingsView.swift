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

struct IOSSettingsView: View {
    @AppStorage("markdownFlavor") private var markdownFlavor: MarkdownFlavor = .github
    @Environment(\.dismiss) private var dismiss

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
                                       value: (WritingPartnerMode(rawValue: UserDefaults.standard.string(forKey: WritingPartnerDefaults.mode) ?? "") ?? .automatic).title)
                    }
                }
                IOSTypographySettingsSections()
                PixerateAccountSections()
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

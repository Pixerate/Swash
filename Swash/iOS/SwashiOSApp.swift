//
//  SwashiOSApp.swift
//  Swash
//
//  App entry point on iPhone and iPad. The macOS entry point is in SwashApp.swift.
//

#if os(iOS)
import SwiftUI
import UIKit

@main
struct SwashApp: App {
    @UIApplicationDelegateAdaptor(SwashAppDelegate.self) private var appDelegate
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        DocumentGroup(newDocument: SwashDocument()) { file in
            IOSContentView(document: file.$document, fileURL: file.fileURL)
        }
        .commands {
            // The iPadOS menu bar and hardware-keyboard shortcuts, as on the Mac
            FormatMenuCommands()
            WritingModeCommands()
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active:
                // Notes saved by the share extension open when Swash comes to the front
                if let note = DocumentOpener.importInbox() {
                    DocumentOpener.open(note)
                }
            case .inactive, .background:
                DocumentOpener.saveOpenDocumentsOnBackground()
            @unknown default:
                break
            }
        }

        // The document manager keeps the system's background, Create Document button and layout,
        // and draws the site's hero wordmark where the title was (IOSSwashWordmark.swift). The
        // launch scene ignores a Text title's font and colour, and a nil title falls back to the
        // app's name, so the title is blank: its row still holds the button where it was.
        DocumentGroupLaunchScene(Text(verbatim: " "), overlayAccessoryView: { geometry in
            SwashLaunchWordmark(titleViewFrame: geometry.titleViewFrame)
        })
    }
}

/// Gives each scene a delegate that sees swash:// links. SwiftUI keeps managing the scene and
/// still opens document (file) URLs itself; views' `onOpenURL` doesn't fire on the document
/// browser, which is what's on screen when no document is open.
final class SwashAppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        PixerateAccess.startAtLaunch()
        // Levels stored before #229 become Copyedit; the switches Settings no longer shows are cleared once
        WritingPartnerDefaults.adoptLearnedDefaults()
        if let raw = UserDefaults.standard.string(forKey: WritingPartnerDefaults.mode),
           let level = WritingPartnerMode(rawValue: raw), level.rawValue != raw {
            UserDefaults.standard.set(level.rawValue, forKey: WritingPartnerDefaults.mode)
        }
        // The writing partner's pause tier: Pixerate with Swash Pro, else Apple Intelligence (#109)
        WritingBandleaderFactory.installPixerateBandleader()
        WritingBandleaderFactory.installOnDeviceBandleader()
        return true
    }

    func application(_ application: UIApplication, configurationForConnecting connectingSceneSession: UISceneSession,
                     options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        let configuration = UISceneConfiguration(name: nil, sessionRole: connectingSceneSession.role)
        configuration.delegateClass = SwashSceneDelegate.self
        return configuration
    }
}

final class SwashSceneDelegate: NSObject, UIWindowSceneDelegate {
    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
        handle(connectionOptions.urlContexts)
    }

    func scene(_ scene: UIScene, openURLContexts URLContexts: Set<UIOpenURLContext>) {
        handle(URLContexts)
    }

    private func handle(_ contexts: Set<UIOpenURLContext>) {
        for context in contexts where context.url.scheme == "swash" {
            DocumentOpener.handle(context.url)
        }
    }
}
#endif

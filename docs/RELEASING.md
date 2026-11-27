# Releasing Swash

Swash is released by GitHub Actions ([`.github/workflows/release.yml`](../.github/workflows/release.yml)). When a push to `main` includes pending changesets (or the workflow is run by hand), it:

1. Imports Apple code-signing certificates from repository secrets, if configured, or falls back to ad-hoc signing.
2. Builds and signs the universal (Apple silicon and Intel) `.app`.
3. Packages it as a `.dmg` disk image and a `.zip` archive.
4. Versions the app from the pending changesets and writes the changelog.
5. Publishes a GitHub Release with the assets attached, and updates the Sparkle `appcast.xml` feed that the app checks for updates.

## Code signing is optional

By default, builds are ad-hoc signed (`CODE_SIGN_IDENTITY="-"`) and need no certificate. If `MACOS_CERTIFICATE` is not set in the repository secrets, the workflow makes ad-hoc builds.

To sign and notarize builds with an Apple Developer account:

1. Export your **Developer ID Application** certificate from Keychain Access as a `.p12` file.
2. Convert it to Base64: `base64 -i Certificate.p12 | pbcopy`.
3. Add these repository secrets under **Settings › Secrets and variables › Actions**:
   - `MACOS_CERTIFICATE`: the Base64 string of your `.p12` certificate.
   - `MACOS_CERTIFICATE_PWD`: the password for the `.p12` file (leave empty if it has none).
   - `KEYCHAIN_PASSWORD`: any temporary password for the CI keychain.
   - `CODE_SIGN_IDENTITY` *(optional)*: the certificate name (detected automatically if omitted).
   - `NOTARIZATION_APPLE_ID`, `NOTARIZATION_PASSWORD`, `NOTARIZATION_TEAM_ID` *(optional)*: for Apple notarization.

## iPhone and iPad (TestFlight)

After the macOS release is published, the workflow archives the iOS app. An iOS failure can't hold up the macOS release.

- **Without App Store Connect secrets** the archive is unsigned. It only checks that the iOS release build works, including the sticker pack when the stickers token is set.
- **With them**, Xcode signs automatically through an App Store Connect API key and uploads the build to TestFlight, with the release's version and the run number as the build number.

To turn on TestFlight uploads:

1. In App Store Connect, register the bundle IDs: `com.pixerate.Swash`, `com.pixerate.Swash.ShareExtension`, `com.pixerate.Swash.WidgetExtension` and `com.pixerate.Swash.Stickers`. Create the app record for `com.pixerate.Swash`, and the App Group `group.com.pixerate.Swash` that the app and share extension use (`Swash/Swash-iOS.entitlements`).
2. Under **Users and Access › Integrations › App Store Connect API**, create a team key with the **App Manager** role and download the `.p8` file (it can only be downloaded once).
3. Add these repository secrets:
   - `APP_STORE_CONNECT_API_KEY`: the Base64 of the `.p8` file (`base64 -i AuthKey_XXXX.p8 | pbcopy`).
   - `APP_STORE_CONNECT_KEY_ID`: the key's ID.
   - `APP_STORE_CONNECT_ISSUER_ID`: the issuer ID shown above the keys list.
   - `APPLE_TEAM_ID`: your 10-character team ID.

All four must be set; with any missing, the build stays unsigned.

## Mac App Store (Universal Purchase)

Swash supports Universal Purchase on the App Store under bundle identifier `com.pixerate.Swash`, sharing the same app record and subscription with the iOS app (iPhone and iPad).

### Direct Distribution vs. Mac App Store Distribution
- **Direct Distribution** (`Release` configuration, scheme `Swash`): Uses Sparkle for background updates and automatic update checks. Its keys (`SUFeedURL`, `SUPublicEDKey`, `SUEnableAutomaticChecks`) are in `Swash/Info.plist`.
- **Mac App Store** (`Release-AppStore` configuration, scheme `Swash (App Store)`): Updates are delivered through the Mac App Store. The configuration leaves out `SparkleUpdater.swift` and the Sparkle package (not linked or embedded), the Updates settings tab and the Check for Updates… menu item, and Sparkle's Mach lookup exception entitlements. A build phase deletes Sparkle's Info.plist keys.

### Archiving and Uploading
Releases do this automatically after the direct download is published: "Inject Pixie (Mac App Store)" swaps in Pixie (below), "Archive Mac App Store App" archives the `Swash (App Store)` scheme and checks it (`scripts/verify_app_store_build.sh`, and that Pixie is in when she was injected), and "Upload Mac App to App Store Connect" uploads it with the App Store Connect secrets. Without those secrets the archive is unsigned and nothing is uploaded. The app record needs the macOS platform added in App Store Connect (Universal Purchase) before the first upload.

To archive the macOS app for Mac App Store distribution by hand:
```bash
xcodebuild archive \
  -scheme "Swash (App Store)" \
  -configuration Release-AppStore \
  -archivePath build/Swash-macOS.xcarchive
```

Export it with `xcodebuild -exportArchive` (method `app-store-connect`), then validate and upload it with Xcode Organizer, Transporter or `xcrun altool --upload-app`, using the same App Store Connect API keys as iOS (`APP_STORE_CONNECT_API_KEY`, `APP_STORE_CONNECT_KEY_ID`, `APP_STORE_CONNECT_ISSUER_ID`). App Store builds aren't notarized: `notarytool` is only for direct distribution.

To verify an App Store build locally before submission:
```bash
scripts/verify_app_store_build.sh path/to/Swash.app
```

### Testing Swash Pro Subscriptions

Testing Swash Pro purchases and entitlement verification requires an App Store environment accepted by the Pixerate server (`Production` or `Sandbox`):

1. **Test on Device via TestFlight (or a Sandbox Development Build)**:
   - Use an Apple Account configured as a **Sandbox Apple Account** in **Settings › Developer › Sandbox Apple Account** (iOS / iPadOS) or **System Settings › App Store › Sandbox Account** (macOS).
   - Sign in with the Sandbox tester account when prompted during purchase or restore.
   - The device receives a real StoreKit JWS transaction signed for the Sandbox environment, which pixerate.com accepts and verifies to unlock Pro.

2. **Xcode `.storekit` Testing Limitation**:
   - The `Swash` scheme includes `Swash/Swash.storekit` for offline UI testing of StoreKit flows.
   - However, transactions minted under Xcode testing are signed with a local Xcode test key (`Xcode` environment).
   - The Pixerate server only accepts `Production` and `Sandbox` environments (`APP_STORE_ENVIRONMENTS`). Consequently, purchases made using Xcode StoreKit configuration cannot be verified on the server and will not unlock Swash Pro until PixerateAccount is updated to trust Xcode-environment transactions locally.

## Stickers (official builds)

`Packages/PixerateStickers` is an open-source stub with no artwork, so anyone can build Swash. Official builds swap in the private [Pixerate/stickers](https://github.com/Pixerate/stickers) package (#62), which adds the sticker sets and the iMessage sticker pack. To turn this on, add a `PIXERATE_PACKAGES_TOKEN` repository secret: a [fine-grained personal access token](https://github.com/settings/personal-access-tokens/new) (or a GitHub App token) with **read-only Contents** access to `Pixerate/stickers` only. Without it, releases keep the stub. The workflow pins the stickers release in the "Inject Proprietary Stickers" step.

## Pixie (official builds, Mac)

`Packages/SwashPixie` is an open-source stub: Pixie isn't in it (`SwashPixie.isAvailable` is false), so anyone can build Swash and her toggle and View › Show Pixie stay hidden. `Packages/SwashPixieFull` is the same package with her chat, on the private [Pixerate/pixie](https://github.com/Pixerate/pixie) package; Swash only ever references `Packages/SwashPixie`, so builds without access never try to fetch it.

Pixie ships in the **Mac App Store** build only: the direct download (DMG and Sparkle) is built and published from the open-source stub first, as the stickers rule requires. To build with Pixie yourself (you need read access to Pixerate/pixie), run `./scripts/use-full-pixie.sh`, which copies the full package over the stub (resolving its link to the shared `SwashPixieDocument.swift`). Don't commit the result: `git checkout -- Packages/SwashPixie Swash.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved` puts the stub back. The release runs the script before the Mac App Store archive and lets git fetch Pixerate/pixie with `PIXERATE_PACKAGES_TOKEN`, so that token needs read-only Contents access to Pixerate/pixie as well as Pixerate/stickers. Without the token the Mac App Store build keeps the stub.

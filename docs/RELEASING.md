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

## Stickers (official builds)

`Packages/PixerateStickers` is an open-source stub with no artwork, so anyone can build Swash. Official builds swap in the private [Pixerate/stickers](https://github.com/Pixerate/stickers) package (#62), which adds the sticker sets and the iMessage sticker pack. To turn this on, add a `PIXERATE_PACKAGES_TOKEN` repository secret: a [fine-grained personal access token](https://github.com/settings/personal-access-tokens/new) (or a GitHub App token) with **read-only Contents** access to `Pixerate/stickers` only. Without it, releases keep the stub. The workflow pins the stickers release in the "Inject Proprietary Stickers" step.

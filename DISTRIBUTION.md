# Release and update publishing

EasySign 0.1.3 (build 5) targets macOS 14 or later. The public source repository is `kavostudio/easysign`. GitHub Releases hosts downloadable archives; GitHub Pages serves `docs/appcast.xml`. Version 0.1.3 is published as a signed, notarized preview release.

## Build and signing

1. Run `swift test` and the fixture checks described in docs/GUIDE.md.
2. Increment `CURRENT_PROJECT_VERSION` for every update. Sparkle compares this build number. Set `MARKETING_VERSION` to the user-facing version.
3. Build a universal archive with an approved Developer ID identity:

```sh
xcodebuild -project EasySign.xcodeproj -scheme EasySign \
  -configuration Release -destination 'generic/platform=macOS' \
  -archivePath Distribution/EasySign.xcarchive \
  'ARCHS=arm64 x86_64' ONLY_ACTIVE_ARCH=NO \
  CODE_SIGN_IDENTITY='Developer ID Application' DEVELOPMENT_TEAM=YOUR_TEAM_ID archive
```

Use Xcode Organizer's **Distribute App → Developer ID** flow, or `xcodebuild -exportArchive` with method `developer-id`, manual signing, your team, and your signing certificate. This ensures Sparkle's nested helpers are signed for distribution. Do not merely re-sign the outer app, and do not use `codesign --deep` as a signing shortcut. `--deep` is appropriate for verification.

Verify the exported app with `codesign --verify --deep --strict --verbose=2` and inspect its authority, secure timestamp, hardened runtime, and entitlements. Preserve framework symlinks with `ditto`. No library-validation exception is enabled. For local Run builds, select your own signing team/certificate; ad-hoc builds may fail library validation when loading Sparkle.

## Notarize before publishing

Create a ZIP containing only the exported app using `ditto -c -k --keepParent`. Submit with `xcrun notarytool submit` and an existing Keychain profile; wait for **Accepted**, then staple and validate the app. Check Gatekeeper with `spctl --assess --type execute --verbose=2`.

Create a read-only DMG containing the stapled app and an Applications shortcut. Sign the DMG with Developer ID, notarize it, staple and validate its ticket. Only then generate its checksum and Sparkle signature. Modifying the DMG afterward invalidates the update signature. Do not publish an ad-hoc or unnotarized build into the public update feed.

## Sparkle signing

Sparkle 2.10.0 is pinned in Xcode's Package.resolved. Keep the Ed25519 private key in a secure Keychain profile. The commands below use `YOUR_SPARKLE_KEY_ACCOUNT` as a placeholder for your local account name. Only its public key, `SUPublicEDKey`, is in the app and repository. Keep a secure independent backup of the private key outside Git; never put it in release assets or logs. Do not generate a replacement key for each release.

The tools are located in `DerivedData/SourcePackages/artifacts/sparkle/Sparkle/bin/` after package resolution. Retrieve the public key using `generate_keys --account YOUR_SPARKLE_KEY_ACCOUNT -p`. Do not replace the configured key unless following Sparkle's documented key-rotation process.

For each release, put only final, notarized update archives in an ignored local staging directory. Generate the appcast with:

```sh
DerivedData/SourcePackages/artifacts/sparkle/Sparkle/bin/generate_appcast \
  --account YOUR_SPARKLE_KEY_ACCOUNT \
  --download-url-prefix 'https://github.com/kavostudio/easysign/releases/download/vVERSION/' \
  --maximum-deltas 0 Distribution/UpdateStaging
```

Use a real version tag in place of `vVERSION`. Start the staging directory with the current appcast to retain history; verify older items still reference their original tags. Keep release notes embedded or publish the corresponding files. Inspect all archive URLs, build numbers, minimum OS, EdDSA signatures, and byte lengths. `SUVerifyUpdateBeforeExtraction` is enabled; downloaded updates must pass signature verification before unpacking.

Upload the final DMG and checksum to the corresponding GitHub Release. Confirm the download URL works before committing the generated feed as `docs/appcast.xml`. GitHub Pages publishes main:/docs over HTTPS. Do not advertise unavailable release assets. Never commit the private key, Apple certificates, notary credentials, local bookmarks, profiles, backups, or Mail files. Signing and notarization remain local; no signing secrets are stored on GitHub.

## Verification and limitations

On macOS 26.5.2 (Apple silicon), build 2 passed 27 core tests, a universal archive/export, and strict nested Developer ID signature verification. The isolated `Tests/UpdaterCheck/UpdaterCheck.swift` fixture loaded the signed Sparkle framework, showed automatic checks disabled, and successfully checked the live GitHub Pages feed. Sparkle reported the current version was up to date. The fixture uses a separate bundle identifier and contains no Mail or profile integration.

To reproduce the fixture check, compile it together with `Sources/EasySign/AppUpdates.swift`, linking the resolved Sparkle XCFramework's macOS framework. Bundle the executable with Sparkle under `Contents/Frameworks`, an `@executable_path/../Frameworks` runpath, and the app's `SU*` Info.plist values. Use a separate bundle identifier and sign the fixture and framework with the same approved identity. Launch in a graphical session and choose **Check for Updates…**.

Test the upgrade from a real older signed build to a newer signed build, including rejection of a tampered archive, canceled updates, offline checks, and preservation of `~/Library/Application Support/EasySign/`. An empty-feed check alone does not verify installation. Builds distributed before Sparkle integration require one manual installation.

Automatic checks are opt-in. Manual checks are available in both the app menu and menu-bar panel. Sparkle system profiling is disabled. Update requests contact GitHub but do not include signatures, sender profiles, or backups. HTTP servers necessarily receive connection metadata such as IP addresses.

Before a production release, test a downloaded quarantined copy on another Mac, folder-access denial/recovery, Mail automation, and apply/restore using a dedicated test signature. Sender-name delivery has a reported inconsistency still under investigation. Intel and macOS 14 runtime behavior remain unverified. Mail storage changes and iCloud synchronization remain compatibility risks.

The source Icon Composer bundle is `Resources/AppIcon.icon`; Xcode generates both modern assets and the `.icns` fallback. Any icon, executable, or resource change requires rebuilding, signing, notarizing, and regenerating the update signature.

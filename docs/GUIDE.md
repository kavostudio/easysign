# EasySign guide

[← Back to EasySign](../README.md)

A local SwiftUI macOS app for replacing the HTML payload of an existing Apple Mail signature. No backend, app account, analytics, or subscription. Sparkle provides optional signed software updates. Requires macOS 14 or later; tested on Apple silicon with macOS 26.5.2 (25F84), Xcode 26.4 (17E192), and Mail 16.0 (3864.600.51.1.1).

## Build and run

1. Open `EasySign.xcodeproj` in Xcode.
2. Resolve the pinned Sparkle package. Select your own signing team and Apple Development or Developer ID certificate in Signing & Capabilities, then choose **EasySign → My Mac** and Run (⌘R).
3. Choose your Mail or Signatures folder when prompted. Create and assign signatures inside Mail; EasySign never changes account mappings or identifier plists.

The project retains hardened runtime and no App Sandbox. Run builds with a valid signing identity: Sparkle requires library validation to succeed. Ad-hoc or unsigned builds are suitable for compile checks only. Do not disable library validation for release builds. Debug builds target the current Mac; Release supports Apple silicon and Intel. See [DISTRIBUTION.md](../DISTRIBUTION.md) for packaging, Developer ID signing, notarization, and current release limitations. This is a direct-download app, not an App Store build.

Command-line build, from this directory:

```sh
xcodebuild -project EasySign.xcodeproj -scheme EasySign -configuration Debug -destination 'platform=macOS,arch=arm64' -derivedDataPath DerivedData \
  CODE_SIGN_IDENTITY='Developer ID Application' DEVELOPMENT_TEAM=YOUR_TEAM_ID build
open DerivedData/Build/Products/Debug/EasySign.app
```

Use `arch=x86_64` on Intel; that runtime has not been tested.

## First-run setup

EasySign opens a two-step setup sheet on first launch. Create a signature in Mail, then use **Choose Folder…** or **Open Signature File…** to grant access. If several Mail stores are found, choose the correct folder explicitly. An empty folder offers Refresh; denied access offers Retry and instructions.

The optional **Connect Mail** step reads configured addresses and requests Automation permission only after you click it. You can skip either step and reopen setup from **Help → Set Up EasySign…**. Completion is saved in `~/Library/Application Support/EasySign/Setup.plist`. Setup never changes a signature or sends a message.

## Use

- Select an existing signature, or use **Open Signature File…**.
- Paste HTML into the plain source editor, or import a UTF-8 `.html` file. Complete documents and fragments are supported. Smart quotes, smart dashes, rich-text conversion, and autocorrection are disabled.
- The source and preview sit side by side; choose 320 px or 640 px, light/dark background, and remote-content loading. Remote requests can contact the servers referenced by the HTML. Turning remote loading off reloads the preview with those requests blocked. Applying never needs the network.
- Quit Mail normally using the Mail toolbar menu. Resolve Mail's own save/draft prompts. EasySign does not force-quit or automatically retry a write.
- Click **Apply to Mail**. On verified success, use **Reopen Mail** from the same menu and inspect a new message.
- **Restore Backup** lists all saved versions with the original path, timestamp, reason, and lock state. Choose a backup and confirm its destination. The current version is backed up before restoration.

Unsaved editor changes trigger a discard confirmation on switching files, reloading, importing, changing folders, closing, and quitting. Source drafts are not autosaved. Lock status is a snapshot from the last load; Refresh rereads it, and Apply always rechecks the actual file.

The examples `Examples/revision-one.html` and `Examples/revision-two.html` provide a complete document and fragment for a dedicated test signature. To return to revision one after applying revision two, restore the **Before apply** backup created when revision two was installed.

## File access

macOS may deny direct access to `~/Library/Mail`. Grant EasySign access through its folder picker; another app’s permission does not transfer to EasySign.

Prefer selecting the specific `MailData/Signatures` folder, or `~/Library/Mail` when discovery is needed. Choose a file directly as a fallback; if replacement is denied, select its containing Signatures folder and Retry. Security-scoped bookmarks are stored under Application Support and renewed when stale. macOS privacy protection applies even without App Sandbox.

If folder selection is still denied, the app explains the next step: **System Settings → Privacy & Security → Full Disk Access → add EasySign**, then quit and reopen EasySign and Retry. Full Disk Access is a fallback, not requested automatically. Rebuilding or moving an ad-hoc signed app can invalidate grants; select the folder again. The app does not change TCC settings itself, use sudo, or change unrelated permissions.

Discovery enumerates `V<number>/MailData/Signatures` candidates and never ranks by version or modification date. Multiple candidates require a user choice. A single candidate is displayed without claiming independent proof that Mail uses it. Exact unique-id matches in `AllSignatures.plist` supply names; missing or ambiguous matches use filenames. AccountsMap and other mappings are never changed.

Manually edited files can contain raw HTML under headers that declare quoted-printable encoding. EasySign labels these bodies as raw HTML for inspection and requires **Repair and Apply** confirmation before changing their encoding. On Apply, the new HTML is correctly encoded under the unchanged headers. Restoring such a backup restores the original bytes, including the original encoding mismatch.

## File safety and supported formats

Parsing and mutation live in `Sources/EasySignCore`, independently tested with temporary fixtures. Supported single-part MIME HTML signatures require a declared charset and MIME-Version 1.0 (Mail comments allowed). Supported charsets: UTF-8, US-ASCII, ISO-8859-1, Windows-1252. Transfer encodings: quoted-printable, base64, 7bit, 8bit, binary. Unsupported, ambiguous, oversized (>10 MB), multipart, or Content-Length-bearing files are rejected. A source that cannot be represented without changing the declared charset/7bit encoding is rejected rather than corrupted. Imports currently require UTF-8.

Every mutation checks the original file's inode/device, bytes, timestamps, permissions, flags, ACL, and extended attributes. Symbolic links, hard links, append-only files, and system-immutable files are rejected. The operation checks that Mail is closed repeatedly, coordinates with cooperating file writers, creates and verifies a complete pre-change backup, stages a sibling file, unlocks only the target if necessary, and uses native atomic RENAME_SWAP. This retains the old inode until completion. The written payload and metadata are verified, the target is locked, and the final result is verified again.

Normal apply preserves exact header bytes, permissions, owner/group, ACL, and extended attributes, while updating file content/modification time and setting the user immutable flag. Restore restores the saved bytes, file metadata, and original lock state; it does not always lock the result. Native copying can modify quarantine flags, so the code explicitly restores exact attribute bytes before verification. Quarantine is preserved by default. If present, a separately confirmed advanced option removes it only from the selected staged signature; the backup retains its original value.

On failure the transaction attempts to restore the original inode, contents, and lock state. An externally modified replacement is retained instead of being overwritten during rollback, and the app reports **Rollback failed** with the verified backup and retained transaction paths. A failed final lock is never reported as a successful apply. If failure changed file metadata, Refresh before retrying.

No filesystem API can atomically combine another process's running state with a write, and NSFileCoordinator does not constrain every Mail/iCloud writer. Tiny races remain possible; repeated checks, atomic swap, verification, and guarded rollback reduce their impact. This is not a transaction across Mail or iCloud. Crash/power-loss recovery is manual from the retained backup; the app does not claim crash-proof journaling.

## Backups and recovery

Backups and preferences live under:

```text
~/Library/Application Support/EasySign/
  Access.plist                     security-scoped bookmarks
  ApplyHistory.plist               last successful apply timestamps
  Backups/<UUID>/
    original.mailsignature         original bytes and copied metadata
    record.json                    original path, identity, timestamp,
                                   SHA-256, mode, UID/GID, timestamps,
                                   ACL, xattrs, flags, and operation reason
```

The backup directory is private to the current user. Backup payload copies are intentionally unlocked so they can be managed; their original lock state is in `record.json`. Backups contain personal signature data, are not encrypted separately from your Mac, and are never silently deleted. Failed partial backup directories start with `.pending-` and are retained but not offered as verified backups.

For recovery, close Mail, launch EasySign, and choose **Restore Backup**. If the original path is missing, the app asks you to locate an existing `.mailsignature` file. It never recreates account metadata. The confirmation names the exact destination. Current state is always backed up first. Backup contents and metadata are verified before use.

If automatic rollback fails, keep Mail closed and retain both the displayed backup and `.EasySign-<UUID>.mailsignature` transaction file. Use Restore Backup after locating the correct destination. If EasySign cannot run, the recovery payload is an ordinary complete signature file; restore it to the recorded original location only while Mail is closed, then match the original lock state recorded in `record.json`. Do not copy `record.json` into Mail. Backup verification failure or unresolvable permissions must be investigated before further writes.

## Preview isolation

WKWebView uses nonpersistent storage, disabled page JavaScript, no file base URL or local read-access grant, and a preview-only Content Security Policy. It blocks scripts, frames, objects, media, forms, local filesystem resources, and network connections other than allowed image/font/stylesheet loads. Additional HTML CSP can restrict the preview further. Non-click navigation is blocked; explicitly clicked HTTP(S) links open in the default browser. Other schemes are cancelled. The preview's CSP/background wrapper is never installed into Mail.

Preview rendering is approximate. Dark background is not Gmail dark-mode emulation. User HTML may specify its own colors/backgrounds. Viewport presets do not guarantee rendering in Mail, Gmail, Outlook, or recipients' devices.

## Verification

```sh
swift test
swiftc -parse-as-library Sources/EasySign/HTMLPreview.swift Tests/PreviewCheck/PreviewCheck.swift -o /tmp/EasySignPreviewCheck
/tmp/EasySignPreviewCheck
```

The native preview check requires a graphical macOS session. It creates an isolated preview window using fixture HTML and checks rendering, disabled script execution, nonpersistent storage, and the offline resource policy.

No real signature mutation or email sending is part of automated tests.

## Known limitations

- Mail storage is undocumented and can change between versions. Only the tested environment above has been verified. Older/newer macOS versions and Intel builds need testing.
- iCloud or another device may replace a signature, remove its lock, propagate an older value, or recreate metadata. Locking is local protection, not an iCloud synchronization guarantee. EasySign never adjusts sync settings.
- Signatures must be created and assigned to accounts in Mail. No account ownership is inferred, and no account mappings/defaults/identifier files are written.
- No rich visual editor, templates, image hosting, cloud sync, account configuration, or other email clients.
- A deleted destination must be recreated by Mail/user and selected for restore. This app does not recreate Mail's metadata.
- Unsupported MIME encodings are rejected. Existing malformed quoted-printable files are labelled for raw-source inspection and require confirmation before repair.
- Sent/received rendering, remote-content policy in recipient clients, and final account assignment must be checked by the user. EasySign never sends mail.

## Sender profiles

Add a profile in the sidebar: label, sender name, and an address from the Mail
picker. It reads active accounts and aliases from Apple Mail, removes duplicate
addresses, and offers Refresh / permission recovery. Sender names stay editable. Profiles are stored locally in
`~/Library/Application Support/EasySign/Profiles.json` (private file permissions).
Use **New Message** or select a message or conversation in Mail and choose **Reply** from
EasySign's menu bar. Mail opens the draft; you compose and send there. EasySign
never sends. Closing the main window keeps the menu-bar helper available; Quit
EasySign exits it.

The first Mail action requests macOS Automation permission. If denied, enable
**System Settings → Privacy & Security → Automation → EasySign → Mail**, then
retry the action. This permission is separate from signature-folder access.

Recent draft status is tied to the draft identifier and checked while visible.
A closed or inaccessible draft becomes unverified. Mail's From menu may display
its configured default name despite the applied identity. Profiles do not edit
account settings or automatically select signatures: the draft uses Mail's
signature selection. Signature installation, backups, and restore remain in the
signature editor. Reply All and applying identities to arbitrary existing drafts
are not included. Phone handoff is unverified. A sender-name inconsistency has been reported: verify the received From header before relying on profiles for production use. Selecting a conversation opens a native message picker sorted newest first.

Profile validation, persistence, and script escaping are covered by `swift test`.
UI checks use `Tests/WindowCheck/WindowCheck.swift` and temporary profile storage.
The app's own Automation permission must be granted locally; prior Script Editor
or terminal permission does not transfer to EasySign.

## Signature source display

The source pane shows the original Mail MIME headers in a selectable, read-only
section, followed by the decoded HTML body for editing. This is an editing view,
not a byte-for-byte display of encoded payloads. Apply preserves the original
header bytes and encodes the edited body according to those headers.

A malformed quoted-printable body opens as Raw HTML, with an explanation in file details.
Applying requires explicit confirmation to repair that body encoding, and the
pre-change backup retains the exact original bytes. Opening a signature changes
no files. Unsupported headers, charsets, and other unsupported encodings still
produce an error rather than a guessed conversion.

### Navigation regression check

The standalone AppKit model check uses temporary signatures and never discovers the real Mail store:

```sh
swift test
swiftc -parse-as-library -I .build/arm64-apple-macosx/debug/Modules \
  Sources/EasySign/AppModel.swift Sources/EasySign/AccessStore.swift \
  Tests/NavigationCheck/NavigationCheck.swift \
  .build/arm64-apple-macosx/debug/EasySignCore.build/*.swift.o \
  -o /tmp/EasySignNavigationCheck
/tmp/EasySignNavigationCheck
```

Use the corresponding architecture directory on Intel Macs. This covers cancelled and confirmed navigation, profile transitions, close/discard, stale editor callbacks, failed loads, and busy-state guards. On macOS 26.5.2, the temporary native window was also checked for cancellation restoring the sidebar highlight and profile round-trips restoring discarded source without a repeated prompt. Real-Mail apply/restore acceptance remains separate.

## Updates and hosting

Sparkle 2.10.0 is pinned through Xcode's Swift Package Manager integration. Use **EasySign → Check for Updates…**, or the menu-bar panel. Automatic checks are off until enabled using **Check for Updates Automatically**. Checks and downloads contact GitHub; they never upload signatures, profiles, or backups. Sparkle system profiling is disabled. Remote signature preview resources remain a separate toggle.

Source and release downloads: https://github.com/kavostudio/easysign

HTTPS update feed: https://kavostudio.github.io/easysign/appcast.xml

The feed offers signed, notarized releases. Version 0.1.0 is the first public preview. Builds that predate Sparkle require one manual installation to gain automatic-update support. See [DISTRIBUTION.md](../DISTRIBUTION.md) for the release process and key management. Sparkle's license is included in Resources/Sparkle-LICENSE.txt and in the app bundle.

## Documentation screenshot

The README screenshot uses the production SwiftUI views through `Tests/WindowCheck/WindowCheck.swift --screenshot`, with temporary files and `Examples/studio-signature.html`. It contains fictional sample data. Compile the fixture using its absolute source path so its example-file lookup resolves correctly; no real Mail signature is needed.

### Setup regression check

The setup fixture uses temporary files and covers first-run presentation, completion persistence, saved folder access, unsaved-edit protection, retry, and failed preference writes:

```sh
swiftc -parse-as-library -I .build/arm64-apple-macosx/debug/Modules \
  Sources/EasySign/AppModel.swift Sources/EasySign/AccessStore.swift \
  Tests/SetupCheck/SetupCheck.swift \
  .build/arm64-apple-macosx/debug/EasySignCore.build/*.swift.o \
  -o /tmp/EasySignSetupCheck
/tmp/EasySignSetupCheck
```

`Tests/WindowCheck/WindowCheck.swift --setup` presents the setup sheet with temporary data for UI checks. Actual macOS permission prompts must also be verified in the signed app.

### Check setup

Choose **Help → Check Setup…**, or **Check Setup…** in the window’s More menu.
The read-only check reports folder readability, signature format and edited HTML compatibility,
external file changes, lock state, and Mail Automation permission when Mail is running.
Unsaved HTML stays in the editor. Choose **Connect Mail** to explicitly open Mail and test account access;
macOS may ask for Automation permission. Folder selection and reload retain the usual discard confirmation.

These checks do not prove that backups or replacement writes will succeed. Apply still verifies the backup,
checks that Mail is closed, verifies the replacement, and locks the file. No test signature is installed by the check.
Use `Tests/WindowCheck/WindowCheck.swift --check-setup` for a temporary-data UI fixture.

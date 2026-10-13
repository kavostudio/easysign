import SwiftUI
import EasySignCore
import Carbon

struct SetupView: View {
    @Bindable var model: AppModel
    @Bindable var profiles: ProfileModel
    @State private var step = Step.signatures
    @State private var attemptedFolder = false
    private enum Step { case signatures, profiles }

    private var hasSignatures: Bool {
        !model.accessDenied && model.error == nil && !model.entries.isEmpty
            && (model.directory != nil || model.selected != nil)
    }
    private var checkingMail: Bool {
        if case .loading = profiles.addressState { return true }
        return false
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack {
                Image("EasySignLogo").resizable().scaledToFit()
                    .frame(width: 40, height: 40).accessibilityHidden(true)
                Spacer()
                Text(step == .signatures ? "1 of 2" : "2 of 2")
                    .font(.caption).foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 8) {
                Text(step == .signatures ? "Connect your signatures" : "Use profiles in Mail")
                    .font(.title2.weight(.semibold))
                Text(step == .signatures
                     ? "Create a signature in Mail → Settings → Signatures, then choose its folder here."
                     : "Optional. Connect Mail to choose from your configured email addresses when adding a profile.")
                    .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if step == .signatures { signatures } else { mailProfiles }
            if let error = model.error {
                Text(error).font(.callout).foregroundStyle(.red)
                    .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            }
            Divider()
            HStack {
                if step == .signatures {
                    Button("Set Up Later", action: model.finishSetup).keyboardShortcut(.cancelAction)
                } else {
                    Button("Back") { step = .signatures }.disabled(checkingMail)
                }
                Spacer()
                Button(step == .signatures ? (hasSignatures ? "Continue" : "Skip for Now") : "Finish") {
                    if step == .signatures { step = .profiles }
                    else { model.finishSetup() }
                }
                .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                .disabled(checkingMail)
            }
        }
        .padding(28).frame(width: 480)
        .interactiveDismissDisabled()
    }

    private var signatures: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Button("Choose Folder…") { attemptedFolder = true; model.pickFolder() }
                Button("Open Mail", action: model.reopenMail)
            }
            Text("Choose the Signatures folder, or ~/Library/Mail to find it. Press ⇧⌘G in the picker to enter a path.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if model.directories.count > 1 {
                Picker("Mail folder", selection: Binding(get: { model.directory }, set: { if let url = $0 { model.chooseDirectory(url) } })) {
                    Text("Choose a folder…").tag(Optional<URL>.none)
                    ForEach(model.directories, id: \.self) { url in
                        Text(url.path).tag(Optional(url))
                    }
                }
                Text("More than one Mail store was found. Choose the one Mail uses.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if model.accessDenied {
                Label("Folder access was denied", systemImage: "lock.shield")
                Text("Choose the folder again. If access is still denied, add EasySign in System Settings → Privacy & Security → Full Disk Access, then quit and reopen EasySign.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Button("Retry", action: model.refresh)
            } else if hasSignatures {
                Label("\(model.entries.count) signatures ready", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            } else if attemptedFolder && model.directory != nil {
                Text("No signatures yet. Create one in Mail, then refresh.")
                    .font(.callout).foregroundStyle(.secondary)
                Button("Refresh", action: model.refresh)
            } else if attemptedFolder && model.directories.isEmpty {
                Text("No folder connected. Choose a Mail folder or open a signature file.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Button("Open Signature File…") { attemptedFolder = true; model.openFile() }
                .buttonStyle(.link)
            Text("You’ll edit and preview HTML here. Quit Mail before applying; EasySign saves a backup first.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    private var mailProfiles: some View {
        VStack(alignment: .leading, spacing: 14) {
            switch profiles.addressState {
            case .idle:
                Button("Connect Mail") { Task { await profiles.refreshAddresses() } }
                Text("Mail may open. When macOS asks, allow EasySign to control Mail.")
                    .font(.callout).foregroundStyle(.secondary)
            case .loading:
                ProgressView("Connecting to Mail…").controlSize(.small)
            case .loaded(let addresses):
                if addresses.isEmpty {
                    Label("No email accounts found", systemImage: "envelope")
                    Text("Add an account in Mail, then try again.").foregroundStyle(.secondary)
                    Button("Retry") { Task { await profiles.refreshAddresses() } }
                } else {
                    Label("Mail connected", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    Text("Add a profile from the sidebar when you’re ready.").foregroundStyle(.secondary)
                }
            case .failed(let message):
                Text(message).font(.callout).foregroundStyle(.secondary)
                    .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                Button("Retry") { Task { await profiles.refreshAddresses() } }
            }
            Text("You compose and send in Mail. EasySign never sends messages automatically.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Text("You can reopen this setup from Help → Set Up EasySign.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

// Kept with onboarding so setup and troubleshooting use the same native controls.
struct SetupCheckView: View {
    @Bindable var model: AppModel
    @Bindable var profiles: ProfileModel
    @State private var checks: [SetupReadiness.Check]?
    @State private var revision = 0
    @State private var connecting = false
    @State private var connectionResult: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Check Setup").font(.title2.weight(.semibold))
            Text("Access and readiness for Apple Mail.").foregroundStyle(.secondary)
            if let checks {
                ForEach(Array(zip(["Signatures folder", "Selected signature", "Mail connection"], checks).enumerated()), id: \.offset) { _, pair in
                    checkRow(pair.0, check: pair.1)
                }
            } else {
                ProgressView("Checking…").controlSize(.small)
            }
            if let error = model.error {
                Text(error).font(.callout).foregroundStyle(.red)
                    .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            }
            if let connectionResult {
                Text(connectionResult).font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text("Quit Mail before applying. These checks don’t test backup creation or writing; Apply verifies both separately.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Divider()
            HStack {
                Button("Check Again") { connectionResult = nil; revision += 1 }
                    .disabled(checks == nil || connecting)
                Spacer()
                Button("Done") { model.showingSetupCheck = false }
                    .keyboardShortcut(.cancelAction).disabled(connecting)
            }
        }
        .padding(24).frame(width: 500)
        .interactiveDismissDisabled(connecting)
        .task(id: revision) { await runChecks() }
    }

    private func checkRow(_ title: String, check: SetupReadiness.Check) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: check.state == .ready ? "checkmark.circle.fill" : check.state == .attention ? "exclamationmark.circle.fill" : "info.circle")
                .foregroundStyle(check.state == .ready ? Color.green : check.state == .attention ? Color.orange : Color.secondary)
                .accessibilityLabel(check.state == .ready ? "Ready" : check.state == .attention ? "Needs attention" : "Information")
            VStack(alignment: .leading, spacing: 6) {
                Text(title).fontWeight(.medium)
                Text(check.detail).font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let action = check.action {
                    Button(action == .chooseFolder ? "Choose Folder…" : action == .openFile ? "Open Signature File…" : "Reload Signature") {
                        switch action {
                        case .chooseFolder: model.pickFolder()
                        case .openFile: model.openFile()
                        case .reload: model.refresh()
                        }
                        revision += 1
                    }.disabled(connecting)
                }
                if title == "Mail connection" {
                    Button(connecting ? "Connecting…" : "Connect Mail") {
                        connecting = true
                        Task {
                            await profiles.refreshAddresses()
                            switch profiles.addressState {
                            case .loaded(let addresses):
                                connectionResult = addresses.isEmpty ? "Mail responded, but no enabled account addresses were found. Add an account in Mail and retry." : "Mail connected successfully."
                            case .failed(let message): connectionResult = message
                            case .idle, .loading: connectionResult = "Mail connection was not checked. Try again."
                            }
                            connecting = false
                            revision += 1
                        }
                    }.disabled(connecting)
                    Text("Optional for profiles. May open Mail and request Automation permission.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
        }
    }

    private func runChecks() async {
        checks = nil
        let directory = model.directory
        let selected = model.selected
        let html = model.html
        let allowUnencoded = model.allowUnencodedQuotedPrintable
        let ambiguous = model.directories.count > 1
        let mailInstalled = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.mail") != nil
        let mailRunning = !NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.mail").isEmpty
        let result = await Task.detached {
            let folder = SetupReadiness.folder(directory, hasManualFile: selected != nil, ambiguous: ambiguous)
            let signature = SetupReadiness.signature(selected, html: html, allowUnencoded: allowUnencoded)
            let mail: SetupReadiness.Check
            if !mailInstalled {
                mail = .init(.attention, "Apple Mail could not be located on this Mac.")
            } else if !mailRunning {
                mail = .init(.information, "Mail is closed, as required when applying signatures. Connect Mail to check profile access.")
            } else {
                let target = NSAppleEventDescriptor(bundleIdentifier: "com.apple.mail")
                let status = AEDeterminePermissionToAutomateTarget(target.aeDesc, typeWildCard, typeWildCard, false)
                switch status {
                case noErr: mail = .init(.ready, "Automation permission is available. Mail is running; quit it before applying signatures.")
                case OSStatus(errAEEventNotPermitted):
                    mail = .init(.attention, "Allow EasySign in System Settings → Privacy & Security → Automation → Mail, then check again.")
                default: mail = .init(.information, "Mail access is not confirmed. Connect Mail to check permission and configured accounts.")
                }
            }
            return [folder, signature, mail]
        }.value
        guard !Task.isCancelled else { return }
        checks = result
    }
}

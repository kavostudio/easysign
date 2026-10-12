import SwiftUI

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
                Image(systemName: step == .signatures ? "signature" : "person.crop.circle")
                    .font(.system(size: 28)).foregroundStyle(.tint).accessibilityHidden(true)
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

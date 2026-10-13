import SwiftUI
import EasySignCore

enum UtilityStyle {
    static let accent = Color(nsColor: .controlAccentColor)
    static let canvas = Color(nsColor: .windowBackgroundColor)
    static let surface = Color(nsColor: .textBackgroundColor)
    static let separator = Color.primary.opacity(0.08)
}

struct ContentView: View {
    @Bindable var model: AppModel
    @Bindable var profiles: ProfileModel
    private enum Destination: Hashable {
        case profile(UUID)
        case signature(URL)
    }
    @State private var sidebarSelection: Destination?
    private var currentDestination: Destination? {
        if model.showingProfiles { return profiles.selectedID.map(Destination.profile) }
        return model.selected.map { .signature($0.url) }
    }
    @State private var remoteContent = true
    @State private var dark = false
    @State private var narrow = true
    @State private var search = ""
    @State private var showingDetails = false
    @State private var showingPreviewInfo = false
    @State private var showingAccessHelp = false

    private var filteredEntries: [SignatureEntry] {
        guard !search.isEmpty else { return model.entries }
        return model.entries.filter { $0.name.localizedCaseInsensitiveContains(search) || $0.excerpt.localizedCaseInsensitiveContains(search) }
    }

    private var editorBinding: Binding<String> {
        let revision = model.editorRevision
        return Binding(get: { model.html }, set: { model.editHTML($0, revision: revision) })
    }

    private var selectedName: String {
        guard let selected = model.selected else { return "Signature" }
        return model.entries.first { $0.url == selected.url }?.name ?? selected.url.lastPathComponent
    }

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 220, ideal: 248, max: 330)
        } detail: {
            VStack(spacing: 0) {
                if model.showingProfiles {
                    if let profile = profiles.profiles.first(where: { $0.id == profiles.selectedID }) {
                        ProfileDetail(model: profiles, profile: profile)
                    } else {
                        ContentUnavailableView {
                            Label("Your identities, in Mail", systemImage: "person.crop.square")
                        } description: {
                            Text("Create a profile to compose or reply.")
                        } actions: {
                            Button("Add profile") { profiles.editing = IdentityProfile() }
                                .buttonStyle(.borderedProminent)
                        }
                    }
                } else if let selected = model.selected {
                    documentHeader(selected)
                    contextualStatus
                    workspace.padding(.horizontal, 22).padding(.bottom, 16)
                    documentFooter(selected)
                } else {
                    welcome
                }
            }
            .background(UtilityStyle.canvas)
            .navigationTitle("EasySign")
            .toolbar {
                ToolbarItem(placement: .automatic) {
                    Button(action: model.importHTML) {
                        HStack(spacing: 6) { Image(systemName: "square.and.arrow.down"); Text("Import HTML") }
                    }
                    .help("Import a UTF-8 HTML file")
                    .disabled(model.showingProfiles || model.selected == nil)
                }
                ToolbarItem(placement: .automatic) {
                    Menu {
                        Button("Check Setup…") { model.showingSetupCheck = true }
                            .disabled(profiles.busy || model.showingSetup)
                        Divider()
                        Button("Quit Mail Normally", action: model.quitMail).disabled(!model.mailRunning)
                        Button("Reopen Mail", action: model.reopenMail).disabled(model.mailRunning)
                        Divider()
                        Button("Restore Backup…", action: model.showBackups)
                        Button("Open Signature File…", action: model.openFile)
                    } label: { Image(systemName: "ellipsis") }
                    .help("Mail and signature actions")
                    .accessibilityLabel("More actions")
                }
            }
        }
        .tint(UtilityStyle.accent)
        .disabled(model.busy)
        .frame(minWidth: 920, minHeight: 620)
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didLaunchApplicationNotification)) { _ in model.updateMailState() }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didTerminateApplicationNotification)) { _ in model.updateMailState() }
        .onAppear { sidebarSelection = currentDestination }
        .onChange(of: currentDestination) { _, value in sidebarSelection = value }
        .onChange(of: sidebarSelection) { _, destination in
            guard let destination, destination != currentDestination else { return }
            Task { @MainActor in
                switch destination {
                case .signature(let url): model.select(url)
                case .profile(let id):
                    if model.showProfiles() { profiles.selectedID = id }
                }
                // A cancelled transition must restore the native selection highlight.
                sidebarSelection = currentDestination
            }
        }
        .onChange(of: model.html) { _, _ in if model.dirty { model.successfulOperation = nil } }
        .alert("Couldn’t complete the operation", isPresented: Binding(get: { model.error != nil && !model.showingSetup && !model.showingSetupCheck }, set: { if !$0 { model.error = nil } })) {
            Button("OK") { model.error = nil }
            if model.mailRunning { Button("Quit Mail Normally") { model.error = nil; model.quitMail() } }
        } message: { Text(model.error ?? "") }
        .sheet(item: $profiles.replyChoice) { choice in
            ReplyMessagePicker(choice: choice) { id in
                Task { await profiles.compose(choice.profile, action: .reply, replyTarget: id) }
            }
        }
        .sheet(item: $profiles.editing) { profile in ProfileEditor(model: profiles, profile: profile) }
        .alert("Mail action failed", isPresented: Binding(get: { profiles.error != nil }, set: { if !$0 { profiles.error = nil } })) {
            Button("OK") { profiles.error = nil }
        } message: { Text(profiles.error ?? "") }
        .sheet(isPresented: $model.showingSetupCheck) { SetupCheckView(model: model, profiles: profiles) }
        .sheet(isPresented: $model.showingSetup) { SetupView(model: model, profiles: profiles) }
        .sheet(isPresented: $model.showingBackups) { BackupPicker(model: model) }
    }

    private var sidebar: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search signatures", text: $search).textFieldStyle(.plain)
                    .accessibilityLabel("Search signatures")
                if !search.isEmpty {
                    Button { search = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.borderless).help("Clear search").accessibilityLabel("Clear search")
                }
            }.font(.callout).padding(8)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
                .padding(12)
            if model.directories.count > 1 {
                Picker("Mail store", selection: Binding(get: { model.directory }, set: { if let url = $0 { model.chooseDirectory(url) } })) {
                    Text("Choose a Mail store…").tag(Optional<URL>.none)
                    ForEach(model.directories, id: \.self) { url in Text(url.path).tag(Optional(url)) }
                }.padding(.horizontal, 12).padding(.bottom, 8)
            }
            List(selection: $sidebarSelection) {
                Section {
                    ForEach(profiles.profiles) { profile in
                        Label(profile.label, systemImage: "person.crop.circle")
                            .lineLimit(1).truncationMode(.middle)
                            .tag(Destination.profile(profile.id))
                            .help(profile.label)
                    }
                } header: { Text("Profiles") }
                Section {
                    ForEach(filteredEntries) { entry in
                        SignatureRow(entry: entry)
                            .tag(Destination.signature(entry.url))
                            .help(entry.name + "\n" + entry.url.path)
                    }
                    if filteredEntries.isEmpty {
                        Text(search.isEmpty ? "No signatures" : "No matching signatures")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                } header: { Text("Signatures") }
            }.listStyle(.sidebar)
            Divider()
            HStack {
                Menu {
                    Button("Add Profile…") { profiles.editing = IdentityProfile() }
                    Divider()
                    Button("Choose Signature Folder…", action: model.pickFolder)
                    Button("Open Signature File…", action: model.openFile)
                } label: { Label("Add", systemImage: "plus") }
                    .menuStyle(.borderlessButton).fixedSize().help("Add a profile or connect signatures")
                Button(action: model.refresh) { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.bordered).controlSize(.small)
                    .help("Refresh signatures").accessibilityLabel("Refresh signatures")
                Spacer()
                if model.accessDenied {
                    Button("Retry access", action: model.refresh).controlSize(.small)
                } else {
                    Text("On this Mac").font(.caption).foregroundStyle(.secondary)
                }
            }.padding(12)
        }
    }

    private func documentHeader(_ selected: FileSnapshot) -> some View {
        HStack(alignment: .center, spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                Text(selectedName).font(.title2.weight(.semibold))
                    .lineLimit(2).truncationMode(.middle).help(selectedName)
                HStack(spacing: 7) {
                    Text("Apple Mail signature").foregroundStyle(.secondary)
                    Text("·").foregroundStyle(.tertiary)
                    Label(model.dirty ? "Unsaved edits" : "Saved", systemImage: model.dirty ? "circle.fill" : "checkmark")
                        .foregroundStyle(model.dirty ? Color.orange : Color.secondary)
                        .imageScale(.small)
                }.font(.system(size: 11))
            }
            Spacer(minLength: 10)
            Button { showingDetails.toggle() } label: { Image(systemName: "info.circle").font(.system(size: 16)) }
                .buttonStyle(.bordered).controlSize(.small).help("File details and advanced options")
                .accessibilityLabel("Signature file details")
                .popover(isPresented: $showingDetails, arrowEdge: .bottom) { fileDetails(selected) }
            Button(action: model.showBackups) { Label("Restore Backup", systemImage: "clock.arrow.circlepath") }
                .controlSize(.regular).help("Choose a previous version to restore")
            Button { Task { await model.apply() } } label: {
                HStack(spacing: 7) {
                    if model.busy { ProgressView().controlSize(.small) }
                    else { Image(systemName: "arrow.up.doc") }
                    Text(model.busy ? "Applying…" : "Apply to Mail").fontWeight(.medium)
                }
            }
            .buttonStyle(.borderedProminent).tint(UtilityStyle.accent).controlSize(.regular)
            .disabled(model.mailRunning).help(model.mailRunning ? "Quit Apple Mail before applying" : "Back up, apply, verify, and lock this signature (⌘S)")
        }.padding(.horizontal, 24).padding(.top, 24).padding(.bottom, 18)
    }

    @ViewBuilder private var contextualStatus: some View {
        if let success = model.successfulOperation {
            HStack(spacing: 9) {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(UtilityStyle.accent)
                Text(success).fontWeight(.medium)

                Spacer()
                Button("Reopen Mail", action: model.reopenMail).disabled(model.mailRunning).buttonStyle(.borderless)
            }.font(.system(size: 12)).padding(12)
                .background(UtilityStyle.accent.opacity(0.07), in: RoundedRectangle(cornerRadius: 9))
                .padding(.horizontal, 22).padding(.bottom, 14)
        } else if model.mailRunning {
            HStack(spacing: 9) {
                Image(systemName: "envelope.badge").foregroundStyle(.secondary)
                Text("Mail is open").fontWeight(.medium)
                Text("Quit to apply changes.").foregroundStyle(.secondary)
                Spacer(minLength: 8)
                Button("Quit Mail", action: model.quitMail).buttonStyle(.bordered)
            }.font(.system(size: 12)).padding(12)
                .background(.quaternary.opacity(0.55), in: RoundedRectangle(cornerRadius: 9))
                .padding(.horizontal, 22).padding(.bottom, 14)
        }
    }

    private var workspace: some View {
        HSplitView {
            sourcePane.frame(minWidth: 270, idealWidth: 430)
            previewPane.frame(minWidth: 320, idealWidth: 480)
        }
        .background(UtilityStyle.surface)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay { RoundedRectangle(cornerRadius: 10).strokeBorder(UtilityStyle.separator, lineWidth: 1) }
    }

    private var sourcePane: some View {
        VStack(spacing: 0) {
            HStack(spacing: 7) {
                Image(systemName: "chevron.left.forwardslash.chevron.right").foregroundStyle(.tertiary)
                Text("Signature source").fontWeight(.medium)
                Spacer()
                Label("Headers protected", systemImage: "lock").font(.system(size: 10)).foregroundStyle(.secondary)
            }.font(.system(size: 12)).padding(.horizontal, 15).frame(height: 42)
            Rectangle().fill(UtilityStyle.separator).frame(height: 1)
            VStack(spacing: 0) {
                SourceEditor(text: .constant(model.signatureHeaders), isEditable: false, accessibilityLabel: "Mail headers, read only")
                    .frame(height: 145)
                    .background(UtilityStyle.canvas)
                HStack {
                    Text("HTML body").fontWeight(.medium)
                    Spacer()
                    Text(model.allowUnencodedQuotedPrintable ? "Raw HTML" : "Decoded for editing")
                        .foregroundStyle(.secondary)
                }.font(.system(size: 10)).padding(.horizontal, 15).frame(height: 28)
                    .background(UtilityStyle.canvas)
                SourceEditor(text: editorBinding).id(model.editorRevision)
            }
            HStack {
                Text("\(model.html.utf8.count.formatted()) bytes").monospacedDigit()
                Spacer()
                Text("⌘Z to undo")
            }.font(.system(size: 10)).foregroundStyle(.tertiary).padding(.horizontal, 15).frame(height: 28)
        }
    }

    private var previewPane: some View {
        VStack(spacing: 0) {
            HStack(spacing: 7) {
                Text("Preview").fontWeight(.medium)
                Button { showingPreviewInfo.toggle() } label: { Image(systemName: "info.circle") }
                    .buttonStyle(.bordered).controlSize(.small).help("About the preview").accessibilityLabel("Preview limitations")
                    .popover(isPresented: $showingPreviewInfo) {
                        Text("Preview is an approximation. Dark background is not Gmail dark-mode emulation, and neither viewport guarantees identical rendering for recipients.")
                            .font(.system(size: 12)).lineSpacing(3).padding(18).frame(width: 300)
                    }
                Spacer()
                Picker("Preview width", selection: $narrow) {
                    Text("Narrow").tag(true); Text("Wide").tag(false)
                }.pickerStyle(.segmented).labelsHidden().controlSize(.small).frame(width: 114)
                Button { dark.toggle() } label: { Image(systemName: dark ? "moon.fill" : "sun.max") }
                    .buttonStyle(.bordered).controlSize(.small).help(dark ? "Use a light preview background" : "Use a dark preview background")
                    .accessibilityLabel("Dark preview background").accessibilityValue(dark ? "On" : "Off")
            }.font(.system(size: 12)).padding(.horizontal, 15).frame(height: 42)
            Rectangle().fill(UtilityStyle.separator).frame(height: 1)
            GeometryReader { geometry in
                let viewportWidth: CGFloat = narrow ? 320 : 640
                let horizontalInset = max(0, min(22, (geometry.size.width - viewportWidth) / 2))
                ScrollView(.horizontal) {
                    HTMLPreview(html: model.html, remoteContent: remoteContent, dark: dark)
                        .frame(width: viewportWidth, height: max(160, geometry.size.height - 56))
                        .background(dark ? Color(red: 0.125, green: 0.129, blue: 0.141) : .white)
                        .clipShape(RoundedRectangle(cornerRadius: 5))
                        .overlay { RoundedRectangle(cornerRadius: 5).strokeBorder(.black.opacity(0.05), lineWidth: 1) }
                        .shadow(color: .black.opacity(0.06), radius: 6, y: 2)
                        .padding(.top, 22).padding(.bottom, 34)
                        .padding(.horizontal, horizontalInset)
                        .frame(minWidth: geometry.size.width, alignment: .top)
                }.clipped()
            }.clipped().background(UtilityStyle.canvas.opacity(0.75))
            HStack(spacing: 5) {
                Toggle(isOn: $remoteContent) {
                    Label("Remote images & fonts", systemImage: "network")
                }.toggleStyle(.checkbox)
                    .help("Allow image, font, and stylesheet requests to remote servers. Apply works offline.")
                Spacer()
                Text(narrow ? "320 px" : "640 px").monospacedDigit().foregroundStyle(.tertiary)
            }.font(.system(size: 10)).foregroundStyle(.secondary).padding(.horizontal, 15).frame(height: 28)
        }
    }

    private func documentFooter(_ selected: FileSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(SignatureDocument.warnings(for: model.html), id: \.self) { warning in
                Label(warning, systemImage: "exclamationmark.triangle").font(.system(size: 11)).foregroundStyle(.orange)
            }
            HStack(spacing: 12) {
                Label(selected.metadata.isLocked ? "File locked" : "File unlocked", systemImage: selected.metadata.isLocked ? "lock" : "lock.open")
                Text("·").foregroundStyle(.tertiary)
                Text(model.lastApply.map { "Last applied \($0.formatted(date: .abbreviated, time: .shortened))" } ?? "Not yet applied with EasySign")
                    .lineLimit(1)
                Spacer(minLength: 8)

            }.font(.system(size: 10)).foregroundStyle(.secondary)
        }.padding(.horizontal, 25).padding(.bottom, 17)
    }

    private func fileDetails(_ selected: FileSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 15) {
            Text("Signature file").font(.headline)
            Text(selected.url.path).font(.system(size: 11, design: .monospaced)).textSelection(.enabled).lineSpacing(3)
            Divider()
            LabeledContent("Lock state", value: selected.metadata.isLocked ? "Locked" : "Unlocked")
            LabeledContent("Last apply", value: model.lastApply?.formatted(date: .abbreviated, time: .shortened) ?? "Not yet applied")
            Text(model.status).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            if selected.metadata.extendedAttributes["com.apple.quarantine"] != nil {
                Divider()
                Text("Advanced").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                Toggle("Remove quarantine on next apply", isOn: $model.removeQuarantine).toggleStyle(.checkbox)
                Text("Usually unnecessary. Applies only to this file, requires confirmation, and preserves the original attribute in its backup.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }.font(.system(size: 12)).padding(20).frame(width: 365)
    }

    private var welcome: some View {
        VStack(spacing: 0) {
            Spacer()
            VStack(alignment: .leading, spacing: 23) {
                Image("EasySignLogo").resizable().scaledToFit()
                    .frame(width: 70, height: 70).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 10) {
                    Text(model.accessDenied ? "Connect your Mail signatures" : (model.entries.isEmpty ? "Your signature,\nready for Mail." : "Choose a signature"))
                        .font(.system(size: 28, weight: .semibold)).tracking(-0.65)
                    Text(model.entries.isEmpty ? "Choose a signature created in Mail, then paste your HTML." : "Choose a signature from the sidebar to start editing.")
                        .font(.system(size: 13)).foregroundStyle(.secondary).lineSpacing(4)
                }
                HStack(spacing: 12) {
                    Button("Choose Signature Folder…", action: model.pickFolder).buttonStyle(.borderedProminent).tint(UtilityStyle.accent).controlSize(.regular)
                    Button("Open Signature File…", action: model.openFile).buttonStyle(.borderless)
                }
                if model.accessDenied {
                    HStack(spacing: 8) {
                        Image(systemName: "lock.shield").foregroundStyle(.secondary)
                        Text("macOS needs your permission to read this folder.").foregroundStyle(.secondary)
                        Button("Help") { showingAccessHelp.toggle() }.buttonStyle(.borderless)
                            .popover(isPresented: $showingAccessHelp) {
                                VStack(alignment: .leading, spacing: 12) {
                                    Text("Grant folder access").font(.headline)
                                    Text("Choose the Mail or Signatures folder using the button above. Press ⇧⌘G in the picker to enter ~/Library/Mail.")
                                    Text("If macOS still denies access: System Settings → Privacy & Security → Full Disk Access → add EasySign. Quit and reopen EasySign, then retry.")
                                    Button("Retry discovery", action: model.refresh)
                                }.font(.system(size: 12)).padding(20).frame(width: 340)
                            }
                        Button("Retry", action: model.refresh).buttonStyle(.borderless)
                    }.font(.system(size: 11))
                }
            }.frame(maxWidth: 460).padding(36)
            Spacer()
            HStack(spacing: 16) {
                Label("Local by design", systemImage: "desktopcomputer")
                Label("No account needed", systemImage: "person.crop.circle.badge.checkmark")
                Label("Automatic backups", systemImage: "clock.arrow.circlepath")
            }.font(.system(size: 10)).foregroundStyle(.tertiary).padding(.bottom, 25)
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }

}

private struct SignatureRow: View {
    let entry: SignatureEntry
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "signature").frame(width: 20)
            VStack(alignment: .leading, spacing: 4) {
                Text(entry.name).font(.system(size: 12, weight: .medium)).lineLimit(2).truncationMode(.middle)
                Text(entry.excerpt == "Needs inspection — Malformed quoted-printable payload." ? "Manually edited signature" : entry.excerpt)
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }.frame(maxWidth: .infinity, alignment: .leading).padding(.top, 2)
        }.padding(.vertical, 3)
    }
}

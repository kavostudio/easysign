import SwiftUI
import EasySignCore

// Serial execution keeps Apple events off the UI thread. No shell or UI scripting.
actor MailAutomation {
    func run(_ source: String) throws -> String {
        let result = try execute(source)
        return result.stringValue ?? String(result.int32Value)
    }
    func addresses() throws -> [String] {
        let result = try execute("""
        tell application "Mail"
            set configuredAddresses to {}
            repeat with a in accounts
                if enabled of a then
                    set accountAddresses to get email addresses of a
                    repeat with addressValue in accountAddresses
                        set end of configuredAddresses to contents of addressValue
                    end repeat
                end if
            end repeat
            return configuredAddresses
        end tell
        """)
        var addresses: [String] = []
        if result.numberOfItems > 0 {
            for index in 1...result.numberOfItems {
                guard let address = result.atIndex(index)?.stringValue else {
                    throw Failure(message: "Mail returned an unreadable address. Try refreshing.")
                }
                addresses.append(address)
            }
        }
        return Array(Set(addresses)).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }
    func replyMessages() throws -> [ReplyMessage] {
        let result = try execute(MailDraftScript.selection)
        var messages: [ReplyMessage] = []
        let now = Date()
        for index in 0..<result.numberOfItems {
            guard let row = result.atIndex(index + 1), row.numberOfItems == 4,
                  let identifier = row.atIndex(1), identifier.int32Value > 0,
                  let sender = row.atIndex(2)?.stringValue,
                  let subject = row.atIndex(3)?.stringValue,
                  let ageText = row.atIndex(4)?.stringValue, let age = Double(ageText), age.isFinite else {
                throw Failure(message: "Mail returned unreadable message details. Try Reply again.")
            }
            messages.append(ReplyMessage(id: Int(identifier.int32Value), sender: sender, subject: subject, received: now.addingTimeInterval(-age)))
        }
        return ReplyMessage.newestFirst(messages)
    }
    private func execute(_ source: String) throws -> NSAppleEventDescriptor {
        var error: NSDictionary?
        guard let script = NSAppleScript(source: source) else { throw Failure(message: "Couldn’t prepare the Mail action.") }
        let result = script.executeAndReturnError(&error)
        if let error {
            let denied = (error[NSAppleScript.errorNumber] as? Int) == -1743
            throw Failure(message: denied
                ? "Allow EasySign in System Settings → Privacy & Security → Automation → Mail, then retry."
                : (error[NSAppleScript.errorMessage] as? String ?? "Mail couldn’t complete this action."))
        }
        return result
    }
    struct Failure: LocalizedError { let message: String; var errorDescription: String? { message } }
}

@MainActor @Observable final class ProfileModel {
    enum AddressState {
        case idle, loading, loaded([String]), failed(String)
    }
    var addressState: AddressState = .idle
    var configuredAddresses: [String] {
        if case .loaded(let addresses) = addressState { return addresses }
        return []
    }
    func refreshAddresses() async {
        if case .loading = addressState { return }
        addressState = .loading
        do { addressState = .loaded(try await automation.addresses()) }
        catch { addressState = .failed(error.localizedDescription) }
    }
    var profiles: [IdentityProfile] = []
    var selectedID: UUID?
    var editing: IdentityProfile?
    struct ReplyChoice: Identifiable {
        let id = UUID()
        let profile: IdentityProfile
        let messages: [ReplyMessage]
    }
    var replyChoice: ReplyChoice?
    var error: String?
    var busy = false
    var drafts: [DraftIdentity] = []
    var loaded = false
    private var storageAvailable = true
    private let automation = MailAutomation()
    private let store: ProfileStore
    init(supportDirectory: URL? = nil) {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("EasySign")
        store = ProfileStore(url: (supportDirectory ?? support).appendingPathComponent("Profiles.json"))
    }
    struct DraftIdentity: Identifiable {
        let id: Int
        let sender: String
        let label: String
        let action: String
        var verified: Bool
    }
    func load() {
        guard !loaded else { return }
        loaded = true
        do { profiles = try store.load(); selectedID = profiles.first?.id }
        catch { storageAvailable = false; self.error = "Couldn’t load profiles. \(error.localizedDescription)" }
    }
    func save(_ profile: IdentityProfile) {
        guard storageAvailable else { error = "Profiles could not be read. Recover Profiles.json before saving."; return }
        do {
            let value = try profile.validated()
            var updated = profiles
            if let index = updated.firstIndex(where: { $0.id == value.id }) { updated[index] = value }
            else { updated.append(value) }
            try store.save(updated)
            profiles = updated; selectedID = value.id; editing = nil
        } catch { self.error = error.localizedDescription }
    }
    func remove(_ id: UUID) {
        guard storageAvailable else { return }
        do {
            let updated = profiles.filter { $0.id != id }
            try store.save(updated); profiles = updated; selectedID = updated.first?.id
        } catch { self.error = error.localizedDescription }
    }
    func compose(_ profile: IdentityProfile, action: MailDraftScript.Action, replyTarget: Int? = nil) async {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        var created = false
        do {
            _ = try profile.validated()
            let addresses = try await automation.addresses()
            guard addresses.contains(profile.email) else {
                throw MailAutomation.Failure(message: "This address is not active in Mail. Edit the profile and choose an available address.")
            }
            let source: String
            if action == .reply {
                if let replyTarget { source = MailDraftScript.reply(to: replyTarget) }
                else {
                    let messages = try await automation.replyMessages()
                    guard let first = messages.first else {
                        throw MailAutomation.Failure(message: "Select an email or conversation in Mail, then try Reply again.")
                    }
                    if messages.count > 1 {
                        replyChoice = ReplyChoice(profile: profile, messages: messages)
                        return
                    }
                    source = MailDraftScript.reply(to: first.id)
                }
            } else { source = MailDraftScript.create(.newMessage) }
            let result = try await automation.run(source)
            guard let id = Int(result), id > 0 else { throw MailAutomation.Failure(message: "Mail didn’t return a draft identifier.") }
            created = true
            let sender = try await automation.run(MailDraftScript.apply(profile, id: id))
            drafts.insert(.init(id: id, sender: sender, label: profile.label, action: action == .reply ? "Reply" : "New message", verified: true), at: 0)
        } catch {
            self.error = error.localizedDescription + (created ? " A draft was opened. It has not been sent." : "")
        }
    }
    func verifyDrafts() async {
        guard !busy, !drafts.isEmpty else { return }
        guard !NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.mail").isEmpty else {
            for index in drafts.indices { drafts[index].verified = false }
            return
        }
        for draft in drafts where draft.verified {
            let source = "tell application \"Mail\"\nreturn sender of (first outgoing message whose id is \(draft.id))\nend tell"
            let sender = try? await automation.run(source)
            if let index = drafts.firstIndex(where: { $0.id == draft.id }) { drafts[index].verified = sender == draft.sender }
        }
    }
}

struct ProfileEditor: View {
    @Bindable var model: ProfileModel
    @State var profile: IdentityProfile
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text(model.profiles.contains(where: { $0.id == profile.id }) ? "Edit profile" : "New profile").font(.title2.weight(.semibold))
            Form {
                TextField("Label", text: $profile.label, prompt: Text("Work"))
                TextField("Sender name", text: $profile.name, prompt: Text("Alex Example | Studio"))
                HStack {
                    Picker("Email", selection: $profile.email) {
                        Text("Choose an address…").tag("")
                        if !profile.email.isEmpty && !model.configuredAddresses.contains(profile.email) {
                            Text("\(profile.email) · unavailable").tag(profile.email)
                        }
                        ForEach(model.configuredAddresses, id: \.self) { address in
                            Text(address).tag(address)
                        }
                    }
                    Button { Task { await model.refreshAddresses() } } label: { Image(systemName: "arrow.clockwise") }
                        .buttonStyle(.borderless).help("Refresh Mail addresses").accessibilityLabel("Refresh Mail addresses")
                }
            }.textFieldStyle(.roundedBorder)
            Group {
                switch model.addressState {
                case .idle, .loading:
                    HStack { ProgressView().controlSize(.small); Text("Reading Mail addresses…") }
                case .loaded(let addresses):
                    if addresses.isEmpty { Text("No active addresses. Add an account in Mail, then refresh.") }
                case .failed(let message):
                    Text(message).foregroundStyle(.red)
                }
            }.font(.caption).foregroundStyle(.secondary)
            if let error = model.error { Text(error).font(.caption).foregroundStyle(.red) }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") { model.save(profile) }.keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent).disabled((try? profile.validated()) == nil || !model.configuredAddresses.contains(profile.email))
            }
        }.padding(24).frame(width: 440)
            .task { await model.refreshAddresses() }
    }
}

struct ProfileDetail: View {
    @Bindable var model: ProfileModel
    let profile: IdentityProfile
    @State private var deleting = false
    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            HStack {
                Image(systemName: "person.crop.square").font(.system(size: 32, weight: .light)).foregroundStyle(UtilityStyle.accent)
                Spacer()
                Menu {
                    Button("Edit profile…") { model.editing = profile }
                    Button("Delete profile…", role: .destructive) { deleting = true }
                } label: { Image(systemName: "ellipsis.circle") }.menuStyle(.borderlessButton).frame(width: 28)
                    .help("Edit or delete profile").accessibilityLabel("Profile actions")
            }
            VStack(alignment: .leading, spacing: 8) {
                Text(profile.label).font(.title2.weight(.semibold))
                Text(profile.name).font(.body)
                Text(profile.email).foregroundStyle(.secondary).textSelection(.enabled)
            }
            HStack {
                Button("New Message", systemImage: "square.and.pencil") { Task { await model.compose(profile, action: .newMessage) } }
                    .buttonStyle(.borderedProminent)
                Button("Reply", systemImage: "arrowshape.turn.up.left") { Task { await model.compose(profile, action: .reply) } }
                    .help("Select an email or conversation in Mail first")
                if model.busy { ProgressView().controlSize(.small) }
            }.controlSize(.regular).disabled(model.busy)
            Text("Select an email or conversation in Mail. Send from Mail as usual.").font(.caption).foregroundStyle(.secondary)
            Divider()
            LabeledContent("Signature", value: "Uses Mail’s selection").foregroundStyle(.secondary)
            if !model.drafts.isEmpty {
                DraftStatus(model: model)
            }
            Spacer()
        }.padding(24).frame(maxWidth: 650, maxHeight: .infinity, alignment: .topLeading)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .confirmationDialog("Delete \(profile.label)?", isPresented: $deleting) {
                Button("Delete profile", role: .destructive) { model.remove(profile.id) }
            } message: { Text("Mail accounts and signatures stay unchanged.") }
    }
}

struct DraftStatus: View {
    @Bindable var model: ProfileModel
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Recent drafts").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            ForEach(model.drafts.prefix(5)) { draft in
                VStack(alignment: .leading, spacing: 3) {
                    Label("\(draft.label) · \(draft.action) #\(draft.id)", systemImage: draft.verified ? "checkmark.circle" : "questionmark.circle")
                    Text(draft.verified ? "Identity checked · \(draft.sender)" : "Identity unverified · draft closed or changed")
                        .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
            }
            Text("Mail’s From menu may show its default name.").font(.caption).foregroundStyle(.secondary)
        }.task {
            while !Task.isCancelled {
                await model.verifyDrafts()
                do { try await Task.sleep(for: .seconds(3)) } catch { return }
            }
        }
    }
}

struct ProfileMenu: View {
    @Bindable var model: ProfileModel
    @State private var recentDraftsExpanded = true
    var checkForUpdates: (() -> Void)? = nil
    var canCheckForUpdates = false
    @Environment(\.openWindow) private var openWindow

    private func showMainWindow() {
        openWindow(id: "main")
        NSApp.activate(ignoringOtherApps: true)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Image("EasySignLogo").resizable().scaledToFit().frame(width: 28, height: 28).accessibilityHidden(true)
                Text("EasySign").font(.headline)
                Spacer()
                Button("Open EasySign", systemImage: "macwindow") { showMainWindow() }
                    .controlSize(.small).help("Open the main window")
            }.padding(16)
            Divider()
            if model.profiles.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    Text("No profiles yet").font(.body.weight(.medium))
                    Button("Add Profile…", systemImage: "plus") {
                        showMainWindow()
                        model.editing = IdentityProfile()
                    }.buttonStyle(.borderedProminent)
                }.padding(16)
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(model.profiles) { profile in
                            HStack(spacing: 10) {
                                Image(systemName: "person.crop.circle").font(.system(size: 20))
                                    .foregroundStyle(.secondary).accessibilityHidden(true)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(profile.label).font(.system(size: 13, weight: .medium))
                                        .lineLimit(1).truncationMode(.middle)
                                    Text(profile.email).font(.caption).foregroundStyle(.secondary)
                                        .lineLimit(1).truncationMode(.middle)
                                }.frame(maxWidth: .infinity, alignment: .leading)
                                    .help(profile.label + "\n" + profile.email)
                                Button {
                                    Task { await model.compose(profile, action: .newMessage) }
                                } label: { Image(systemName: "square.and.pencil").frame(width: 20, height: 20) }
                                    .help("New message as " + profile.label)
                                    .accessibilityLabel("New message as " + profile.label)
                                Button {
                                    showMainWindow()
                                    Task { await model.compose(profile, action: .reply) }
                                } label: { Image(systemName: "arrowshape.turn.up.left").frame(width: 20, height: 20) }
                                    .help("Reply as " + profile.label)
                                    .accessibilityLabel("Reply as " + profile.label)
                            }.buttonStyle(.bordered).controlSize(.small)
                                .disabled(model.busy)
                                .padding(.horizontal, 16).frame(height: 62)
                        }
                    }
                }.frame(height: CGFloat(min(model.profiles.count, 5)) * 62)
            }
            if let error = model.error {
                Divider()
                VStack(alignment: .leading, spacing: 8) {
                    ScrollView { Text(error).font(.callout).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                        .frame(maxHeight: 90)
                    Button("Dismiss") { model.error = nil }.controlSize(.small)
                }.padding(16)
            }
            if !model.drafts.isEmpty {
                Divider()
                DisclosureGroup("Recent drafts", isExpanded: $recentDraftsExpanded) {
                    ScrollView { DraftStatus(model: model).padding(.top, 8) }.frame(maxHeight: 180)
                }.font(.callout).padding(16)
            }
            if let checkForUpdates {
                Divider()
                Button("Check for Updates…", systemImage: "arrow.triangle.2.circlepath", action: checkForUpdates)
                    .controlSize(.small).disabled(!canCheckForUpdates || model.busy).padding(12)
            }
            Divider()
            HStack {
                if model.busy {
                    ProgressView().controlSize(.small)
                    Text("Opening draft…").font(.caption).foregroundStyle(.secondary)
                } else {
                    Text("Compose in Apple Mail").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }
                    .controlSize(.small).disabled(model.busy)
                    .help("Quit EasySign").accessibilityLabel("Quit EasySign")
            }.padding(12)
        }.frame(width: 390).tint(UtilityStyle.accent)
            .task { model.load(); await model.verifyDrafts() }
    }
}

struct ReplyMessagePicker: View {
    let choice: ProfileModel.ReplyChoice
    let reply: (Int) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var selectedID: Int?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text("Reply to a message").font(.title2.weight(.semibold))
                Spacer()
                Text("Newest first").font(.caption).foregroundStyle(.secondary)
            }.padding(24)
            List(selection: $selectedID) {
                ForEach(choice.messages) { message in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(alignment: .firstTextBaseline, spacing: 16) {
                            Text(message.sender).font(.system(size: 13, weight: .semibold)).lineLimit(1).truncationMode(.middle)
                            Spacer(minLength: 0)
                            Text(message.received.formatted(date: .abbreviated, time: .shortened))
                                .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize()
                        }
                        Text(message.subject.isEmpty ? "No subject" : message.subject)
                            .font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(2)
                    }
                    .padding(.vertical, 8)
                    .tag(message.id)
                    .help(message.sender + "\n" + message.subject)
                    .accessibilityElement(children: .combine)
                }
            }.listStyle(.inset).frame(height: 320)
            Divider()
            HStack {
                Text("\(choice.messages.count) messages").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Reply") {
                    guard let selectedID else { return }
                    dismiss()
                    reply(selectedID)
                }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction).disabled(selectedID == nil)
            }.padding(20)
        }.frame(width: 640)
    }
}

import AppKit
import Observation
import UniformTypeIdentifiers
import EasySignCore

@MainActor @Observable
final class AppModel {
    var entries: [SignatureEntry] = []
    var directories: [URL] = []
    var directory: URL?
    var selected: FileSnapshot?
    var showingProfiles = true
    var editorRevision = UUID()
    private var started = false
    var discardDecision: (() -> Bool)?
    var signatureHeaders = ""
    var html = ""
    var loadedHTML = ""
    var status = "Select a signature created in Apple Mail."
    var error: String?
    var accessDenied = false
    var busy = false
    var backups: [BackupRecord] = []
    var showingBackups = false
    var lastApply: Date?
    var allowUnencodedQuotedPrintable = false
    var removeQuarantine = false
    let access = AccessStore()
    var backupStore: BackupStore { BackupStore(directory: access.support.appendingPathComponent("Backups", isDirectory: true)) }
    var dirty: Bool { html != loadedHTML }
    var mailRunning = !NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.mail").isEmpty
    var successfulOperation: String?

    func updateMailState() {
        mailRunning = !NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.mail").isEmpty
    }

    func start() {
        guard !started else { return }
        started = true
        discoverSavedAccess()
    }

    private func discoverSavedAccess() {
        updateMailState()
        do {
            let urls = try access.restore()
            if let last = urls.last {
                if last.pathExtension == "mailsignature" { select(last); return }
                try discover(last); return
            }
            try discover(FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Mail"))
        } catch { reportAccess(error) }
    }

    func discover(_ root: URL) throws {
        let children = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
        if root.lastPathComponent == "Signatures" || children.contains(where: { $0.pathExtension == "mailsignature" }) {
            directories = [root]
        } else { directories = try SignatureDiscovery.candidates(in: root) }
        accessDenied = false
        if directories.count == 1 { try loadDirectory(directories[0]) }
        else {
            directory = nil; entries = []
            status = directories.isEmpty ? "No signature directories found. Create a signature in Mail, then refresh or open its file." : "Multiple Mail stores found. Choose the directory containing your signature; EasySign will not guess which is active."
        }
    }

    func chooseDirectory(_ url: URL) {
        guard confirmDiscard() else { return }
        do { try loadDirectory(url); clearDocument() }
        catch { reportAccess(error) }
    }

    private func loadDirectory(_ url: URL) throws {
        let discovered = try SignatureDiscovery.signatures(in: url)
        entries = discovered; directory = url
        accessDenied = false; error = nil
        status = "\(entries.count) signatures · \(url.path)"
    }

    func refresh() {
        guard confirmDiscard() else { return }
        let target = selected?.url
        do {
            if let directory { try loadDirectory(directory) } else if target == nil { discoverSavedAccess(); return }
            if let target { try load(target) }
            accessDenied = false
        } catch { reportAccess(error) }
    }

    func pickFolder() {
        guard confirmDiscard() else { return }
        let panel = NSOpenPanel()
        panel.title = "Choose Mail or Signatures Folder"
        panel.message = "Select ~/Library/Mail or the specific MailData/Signatures folder. EasySign reads signature files and name metadata only."
        panel.canChooseFiles = false; panel.canChooseDirectories = true
        panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Mail")
        if panel.runModal() == .OK, let url = panel.url {
            do {
                try access.remember(url)
                try discover(url)
                clearDocument()
            } catch { reportAccess(error) }
        }
    }

    func openFile() {
        guard confirmDiscard() else { return }
        let panel = NSOpenPanel()
        panel.title = "Open Signature File"
        panel.allowedContentTypes = [UTType(filenameExtension: "mailsignature") ?? .data]
        if panel.runModal() == .OK, let url = panel.url {
            do { try access.remember(url); try load(url) } catch { reportAccess(error) }
        }
    }

    func select(_ url: URL) {
        guard !busy else { return }
        if selected?.url == url { showingProfiles = false; return }
        guard confirmDiscard() else { return }
        do { try load(url) } catch { reportAccess(error) }
    }

    private func load(_ url: URL) throws {
        let snapshot = try FileSnapshot(url: url)
        let document: SignatureDocument
        var recovered = false
        do { document = try SignatureDocument(data: snapshot.data) }
        catch {
            guard error.localizedDescription == "Malformed quoted-printable payload." else { throw error }
            document = try SignatureDocument(data: snapshot.data, allowUnencodedQuotedPrintable: true)
            recovered = true
        }
        successfulOperation = nil
        accessDenied = false; error = nil
        allowUnencodedQuotedPrintable = recovered
        signatureHeaders = String(decoding: document.headers, as: UTF8.self)
        editorRevision = UUID()
        selected = snapshot; html = document.html; loadedHTML = document.html
        showingProfiles = false
        removeQuarantine = false
        lastApply = loadLastApply(for: url)
        status = recovered ? "This body is shown as raw HTML because it does not match the quoted-printable encoding declared in Mail’s headers. This can happen after manual editing; it does not necessarily mean the HTML is broken. Applying will encode the body to match those headers and back up the original file first." : "Loaded · \(document.charset) · \(document.transferEncoding)"
        if !entries.contains(where: { $0.url == url }) {
            entries.append(SignatureEntry(url: url, name: url.lastPathComponent, excerpt: "Manually selected file"))
        }
    }

    func importHTML() {
        guard confirmDiscard() else { return }
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.html]
        panel.title = "Import HTML Source"
        if panel.runModal() == .OK, let url = panel.url {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            do {
                let data = try Data(contentsOf: url)
                guard data.count <= 10_000_000 else { throw EasySignError("HTML exceeds the 10 MB limit.") }
                guard let source = String(data: data, encoding: .utf8) else { throw EasySignError("Import a UTF-8 HTML file. Other import encodings are not supported yet.") }
                html = source
            } catch { self.error = error.localizedDescription }
        }
    }

    func confirmDiscard() -> Bool {
        guard dirty else { return true }
        if let discardDecision { return discardDecision() }
        let alert = NSAlert()
        alert.messageText = "Discard unsaved HTML edits?"
        alert.informativeText = "Your installed Mail signature has not changed. These editor changes will be lost."
        alert.addButton(withTitle: "Keep Editing"); alert.addButton(withTitle: "Discard Edits")
        return alert.runModal() == .alertSecondButtonReturn
    }

    func discardEdits() {
        html = loadedHTML
        editorRevision = UUID()
    }

    @discardableResult func showProfiles() -> Bool {
        guard !busy, confirmDiscard() else { return false }
        discardEdits()
        showingProfiles = true
        return true
    }

    func closeEditor() -> Bool {
        guard !busy, confirmDiscard() else { return false }
        discardEdits()
        return true
    }

    func editHTML(_ source: String, revision: UUID) {
        guard revision == editorRevision, !showingProfiles, !busy else { return }
        html = source
    }

    private func clearDocument() {
        editorRevision = UUID()
        selected = nil
        signatureHeaders = ""
        html = ""
        loadedHTML = ""
        lastApply = nil
        successfulOperation = nil
        allowUnencodedQuotedPrintable = false
        removeQuarantine = false
        showingProfiles = false
    }

    func quitMail() {
        let apps = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.mail")
        let accepted = apps.map { $0.terminate() }.allSatisfy { $0 }
        status = accepted ? "Asked Mail to quit normally. Resolve any Mail prompts, then retry Apply or Restore." : "Mail did not accept the quit request. Switch to Mail and choose Mail → Quit Mail, then retry."
    }

    func reopenMail() {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.mail") else { error = "Apple Mail could not be located."; return }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration()) { _, failure in
            if let failure { Task { @MainActor in self.error = failure.localizedDescription } }
        }
    }

    func apply() async {
        guard let selected, !busy else { return }
        if allowUnencodedQuotedPrintable {
            let alert = NSAlert()
            alert.messageText = "Apply this custom HTML?"
            alert.informativeText = "This file declares quoted-printable, but its body is not valid quoted-printable. EasySign is showing the body as raw HTML. Applying will encode it to match the existing headers. A backup preserves the original file."
            alert.addButton(withTitle: "Cancel")
            alert.addButton(withTitle: "Back Up and Apply")
            guard alert.runModal() == .alertSecondButtonReturn else { return }
        }
        if removeQuarantine {
            let alert = NSAlert()
            alert.messageText = "Remove quarantine from this signature?"
            alert.informativeText = "Quarantine removal is not normally required. This apply will remove only this file’s com.apple.quarantine attribute. The verified backup preserves it for restoration."
            alert.addButton(withTitle: "Cancel"); alert.addButton(withTitle: "Apply and Remove Quarantine")
            guard alert.runModal() == .alertSecondButtonReturn else { return }
        }
        await write(selected: selected, restore: nil)
    }

    func showBackups() {
        do { backups = try backupStore.list(); showingBackups = true } catch { self.error = error.localizedDescription }
    }

    func restore(_ backup: BackupRecord) async {
        guard confirmDiscard(), !busy else { return }
        var destination: FileSnapshot
        do {
            // The current selection is an explicit destination only when its original path matches.
            if let selected, selected.url.path == backup.originalPath { destination = selected }
            else if FileManager.default.fileExists(atPath: backup.originalPath) {
                destination = try FileSnapshot(url: URL(fileURLWithPath: backup.originalPath))
            } else {
                let panel = NSOpenPanel()
                panel.title = "Locate Destination for Backup"
                panel.message = "The original destination is missing. Select the signature that should receive this backup. EasySign will first back it up."
                panel.allowedContentTypes = [UTType(filenameExtension: "mailsignature") ?? .data]
                guard panel.runModal() == .OK, let url = panel.url else { return }
                try access.remember(url)
                destination = try FileSnapshot(url: url)
            }
            let alert = NSAlert()
            alert.messageText = "Restore this backup?"
            alert.informativeText = "Backup: \(backup.date.formatted())\nDestination: \(destination.url.path)\nThe current file will be backed up first. The backup’s original lock state and attributes will be restored."
            alert.addButton(withTitle: "Cancel"); alert.addButton(withTitle: "Restore Backup")
            guard alert.runModal() == .alertSecondButtonReturn else { return }
            showingBackups = false
            await write(selected: destination, restore: backup)
        } catch { self.error = error.localizedDescription }
    }

    private func write(selected: FileSnapshot, restore: BackupRecord?) async {
        updateMailState()
        guard !mailRunning else { error = "Apple Mail is still running. Use Quit Mail, resolve any draft or save prompts, then retry. EasySign never force-quits Mail."; return }
        busy = true
        successfulOperation = nil
        defer { busy = false }
        let source = html
        let quarantine = removeQuarantine
        let allowUnencoded = allowUnencodedQuotedPrintable
        let store = backupStore
        do {
            // File coordination must not block the UI event loop.
            try await Task.detached {
                let writer = SignatureWriter(backups: store) {
                    guard NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.mail").isEmpty else {
                        throw EasySignError("Mail is running or reopened during the operation. Close Mail and retry.")
                    }
                }
                if let restore { try writer.restore(restore, to: selected) }
                else { try writer.apply(html: source, to: selected, removeQuarantine: quarantine, allowUnencodedQuotedPrintable: allowUnencoded) }
            }.value
            if restore == nil { try saveLastApply(for: selected.url) }
            try load(selected.url)
            successfulOperation = restore == nil ? "Signature applied and locked" : "Backup restored"
            status = restore == nil ? "Applied and locked successfully. You can reopen Mail." : "Backup restored and verified. You can reopen Mail."
        } catch { self.error = error.localizedDescription }
    }

    private func reportAccess(_ failure: Error) {
        let ns = failure as NSError
        accessDenied = ns.code == NSFileReadNoPermissionError || ns.code == NSFileWriteNoPermissionError ||
            failure.localizedDescription.localizedCaseInsensitiveContains("not permitted") || failure.localizedDescription.localizedCaseInsensitiveContains("permission")
        error = accessDenied ? nil : failure.localizedDescription
        if accessDenied {
            status = "Access denied. Choose the Mail or Signatures folder to grant access, then Retry. If selection is still denied: System Settings → Privacy & Security → Full Disk Access → add EasySign, quit and reopen EasySign."
        }
    }

    private var historyURL: URL { access.support.appendingPathComponent("ApplyHistory.plist") }
    private func loadLastApply(for url: URL) -> Date? {
        guard let data = try? Data(contentsOf: historyURL), let values = try? PropertyListDecoder().decode([String: Date].self, from: data) else { return nil }
        return values[url.path]
    }
    private func saveLastApply(for url: URL) throws {
        var values: [String: Date] = [:]
        if FileManager.default.fileExists(atPath: historyURL.path) {
            values = try PropertyListDecoder().decode([String: Date].self, from: Data(contentsOf: historyURL))
        }
        values[url.path] = Date()
        try PropertyListEncoder().encode(values).write(to: historyURL, options: .atomic)
    }
}

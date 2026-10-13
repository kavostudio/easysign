import Foundation

/// Read-only checks. Applying still performs its own backup and write verification.
public enum SetupReadiness {
    public enum State: Sendable { case ready, information, attention }
    public enum Action: Sendable { case chooseFolder, openFile, reload }
    public struct Check: Sendable {
        public let state: State
        public let detail: String
        public let action: Action?
        public init(_ state: State, _ detail: String, action: Action? = nil) {
            self.state = state; self.detail = detail; self.action = action
        }
    }

    public static func folder(_ directory: URL?, hasManualFile: Bool, ambiguous: Bool) -> Check {
        guard let directory else {
            if hasManualFile { return Check(.information, "Using a manually selected signature file.") }
            return Check(.attention, ambiguous ? "Multiple Mail stores found. Choose the Signatures folder Mail uses." : "Choose your Mail or Signatures folder.", action: .chooseFolder)
        }
        do {
            let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            let count = files.filter { !$0.lastPathComponent.hasPrefix(".") && $0.pathExtension.lowercased() == "mailsignature" }.count
            return count == 0
                ? Check(.information, "Folder is readable, but has no signatures. Create one in Mail → Settings → Signatures.")
                : Check(.ready, "Folder is readable · \(count) signature\(count == 1 ? "" : "s") found.")
        } catch {
            return Check(.attention, "Couldn’t read this folder. Choose it again. If macOS still denies access, enable EasySign in System Settings → Privacy & Security → Full Disk Access, then restart EasySign.", action: .chooseFolder)
        }
    }

    public static func signature(_ selected: FileSnapshot?, html: String, allowUnencoded: Bool) -> Check {
        guard let selected else { return Check(.information, "Select a signature to check its content and lock state.", action: .openFile) }
        do { try selected.requireUnchanged() }
        catch { return Check(.attention, "The selected file changed or is no longer readable. Reload it; you’ll be asked before discarding edits.", action: .reload) }
        do {
            let document = try SignatureDocument(data: selected.data, allowUnencodedQuotedPrintable: allowUnencoded)
            _ = try document.replacingHTML(html)
            if allowUnencoded {
                return Check(.information, "Manually edited signature. Applying will encode the HTML to match Mail’s headers, after backing up the original.")
            }
            return Check(.ready, selected.metadata.isLocked
                         ? "HTML is supported. File is locked; EasySign handles unlocking when applying."
                         : "HTML is supported. EasySign will lock the file after applying.")
        } catch {
            return Check(.attention, "This signature or the edited HTML needs attention. \(error.localizedDescription)", action: .openFile)
        }
    }
}

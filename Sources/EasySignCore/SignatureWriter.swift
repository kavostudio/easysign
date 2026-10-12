import Foundation
import Darwin

public enum WritePhase: Sendable { case backupCreated, staged, unlocked, replaced, verified, locked }

/// NSFileCoordinator serializes cooperating writers. The atomic swap retains the original inode for rollback.
public struct SignatureWriter {
    public let backups: BackupStore
    public var requireMailClosed: () throws -> Void
    public var checkpoint: (WritePhase) throws -> Void = { _ in }

    public init(backups: BackupStore, requireMailClosed: @escaping () throws -> Void) {
        self.backups = backups
        self.requireMailClosed = requireMailClosed
    }

    @discardableResult
    public func apply(html: String, to loaded: FileSnapshot, removeQuarantine: Bool = false, allowUnencodedQuotedPrintable: Bool = false) throws -> BackupRecord {
        let document = try SignatureDocument(data: loaded.data, allowUnencodedQuotedPrintable: allowUnencodedQuotedPrintable)
        let replacement = try document.replacingHTML(html)
        return try perform(loaded: loaded, replacement: replacement, restoring: nil, removeQuarantine: removeQuarantine)
    }

    @discardableResult
    public func restore(_ record: BackupRecord, to loaded: FileSnapshot) throws -> BackupRecord {
        _ = try SignatureDocument(data: loaded.data, allowUnencodedQuotedPrintable: true)
        let backup = try backups.verify(record)
        _ = try SignatureDocument(data: backup.data, allowUnencodedQuotedPrintable: true)
        return try perform(loaded: loaded, replacement: backup.data, restoring: record, removeQuarantine: false)
    }

    private func perform(loaded: FileSnapshot, replacement: Data, restoring record: BackupRecord?, removeQuarantine: Bool) throws -> BackupRecord {
        try requireMailClosed()
        try loaded.requireUnchanged()
        var coordinationError: NSError?
        var result: Result<BackupRecord, Error>?
        NSFileCoordinator().coordinate(writingItemAt: loaded.url, options: .forReplacing, error: &coordinationError) { target in
            result = Result { try transaction(loaded: loaded, target: target, replacement: replacement, restoring: record, removeQuarantine: removeQuarantine) }
        }
        if let coordinationError { throw coordinationError }
        guard let result else { throw EasySignError("File coordination did not grant access. Retry after selecting the folder.") }
        return try result.get()
    }

    private func transaction(loaded: FileSnapshot, target: URL, replacement: Data, restoring record: BackupRecord?, removeQuarantine: Bool) throws -> BackupRecord {
        guard target.standardizedFileURL == loaded.url.standardizedFileURL else { throw EasySignError("The selected destination moved. Reload it.") }
        try requireMailClosed()
        try loaded.requireUnchanged()
        let backup = try backups.create(from: loaded, reason: record == nil ? "Before apply" : "Before restore")
        try checkpoint(.backupCreated)
        let stage = target.deletingLastPathComponent().appendingPathComponent(".EasySign-\(UUID().uuidString).mailsignature")
        let originalFlags = loaded.metadata.flags
        let desiredMetadata = record?.metadata ?? loaded.metadata
        let finalFlags = record?.metadata.flags ?? (originalFlags | UInt32(UF_IMMUTABLE))
        var unlocked = false
        var swapped = false
        var stagedSnapshot: FileSnapshot?
        var expectedTarget: FileSnapshot?
        do {
            let source = record.map { backups.payload(for: $0) } ?? backups.payload(for: backup)
            try copyCompleteFile(from: source, to: stage)
            try setFlags(desiredMetadata.flags & ~UInt32(UF_IMMUTABLE), at: stage)
            if record == nil {
                guard chmod(stage.path, desiredMetadata.mode | 0o200) == 0 else { throw posixError("Prepare staged file") }
                let handle = try FileHandle(forWritingTo: stage)
                do {
                    try handle.truncate(atOffset: 0)
                    try handle.write(contentsOf: replacement)
                    try handle.synchronize()
                    try handle.close()
                } catch { try? handle.close(); throw error }
                guard chmod(stage.path, desiredMetadata.mode) == 0 else { throw posixError("Preserve permissions") }
            }
            if removeQuarantine, desiredMetadata.extendedAttributes["com.apple.quarantine"] != nil {
                guard removexattr(stage.path, "com.apple.quarantine", XATTR_NOFOLLOW) == 0 else { throw posixError("Remove selected signature quarantine") }
            }
            stagedSnapshot = try FileSnapshot(url: stage)
            guard let prepared = stagedSnapshot, prepared.data == replacement,
                  desiredMetadata.equivalentPermissions(to: prepared.metadata, flags: desiredMetadata.flags & ~UInt32(UF_IMMUTABLE), excludingQuarantine: removeQuarantine) else {
                throw EasySignError("Staged content or metadata failed verification.")
            }
            try checkpoint(.staged)
            try requireMailClosed()
            try loaded.requireUnchanged()
            if loaded.metadata.isLocked {
                try setFlags(originalFlags & ~UInt32(UF_IMMUTABLE), at: target)
                unlocked = true
            }
            expectedTarget = try FileSnapshot(url: target)
            guard let expectedTarget, expectedTarget.data == loaded.data,
                  expectedTarget.metadata.inode == loaded.metadata.inode,
                  loaded.metadata.equivalentPermissions(to: expectedTarget.metadata, flags: originalFlags & ~UInt32(UF_IMMUTABLE)) else {
                throw EasySignError("The target changed before replacement.")
            }
            try checkpoint(.unlocked)
            try requireMailClosed()
            try expectedTarget.requireUnchanged()
            try requireMailClosed()
            guard renamex_np(stage.path, target.path, UInt32(RENAME_SWAP)) == 0 else { throw posixError("Atomically replace signature") }
            swapped = true
            let displaced = try FileSnapshot(url: stage)
            guard displaced.metadata.inode == loaded.metadata.inode, displaced.data == loaded.data,
                  loaded.metadata.equivalentPermissions(to: displaced.metadata, flags: originalFlags & ~UInt32(UF_IMMUTABLE)) else {
                throw EasySignError("An external writer raced with replacement. The displaced file is retained for recovery.")
            }
            try checkpoint(.replaced)
            try requireMailClosed()
            let written = try FileSnapshot(url: target)
            guard let stagedSnapshot, written.metadata.inode == stagedSnapshot.metadata.inode,
                  written.data == replacement,
                  stagedSnapshot.metadata.equivalentPermissions(to: written.metadata, flags: stagedSnapshot.metadata.flags) else {
                throw EasySignError("Written content or metadata failed verification.")
            }
            try checkpoint(.verified)
            try written.requireUnchanged()
            try setFlags(finalFlags, at: target)
            try checkpoint(.locked)
            let final = try FileSnapshot(url: target)
            guard final.data == replacement, final.metadata.inode == stagedSnapshot.metadata.inode,
                  stagedSnapshot.metadata.equivalentPermissions(to: final.metadata, flags: finalFlags) else {
                throw EasySignError("Final lock or content verification failed.")
            }
            try requireMailClosed()
        } catch {
            let failure = error
            do {
                if swapped {
                    // Never overwrite a new external edit during rollback.
                    let current = try FileSnapshot(url: target)
                    guard let stagedSnapshot, current.metadata.inode == stagedSnapshot.metadata.inode,
                          current.data == replacement else {
                        throw EasySignError("The replacement changed externally; automatic rollback would overwrite that change.")
                    }
                    try setFlags(current.metadata.flags & ~UInt32(UF_IMMUTABLE), at: target)
                    guard renamex_np(stage.path, target.path, UInt32(RENAME_SWAP)) == 0 else { throw posixError("Roll back replacement") }
                    try setFlags(originalFlags, at: target)
                    let restored = try FileSnapshot(url: target)
                    guard restored.data == loaded.data, restored.metadata.inode == loaded.metadata.inode,
                          loaded.metadata.equivalentPermissions(to: restored.metadata, flags: originalFlags) else {
                        throw EasySignError("Rollback verification failed.")
                    }
                } else if unlocked {
                    let current = try FileSnapshot(url: target)
                    guard current.metadata.inode == loaded.metadata.inode else { throw EasySignError("The unlocked target was replaced externally.") }
                    try setFlags(originalFlags, at: target)
                    guard current.data == loaded.data else { throw EasySignError("The original lock state was restored, but external content changes were retained.") }
                    guard try FileMetadata(url: target).flags == originalFlags else { throw EasySignError("Could not restore the original lock state.") }
                }
            } catch {
                throw EasySignError("\(failure.localizedDescription)\nRollback failed: \(error.localizedDescription)\nVerified backup: \(backups.payload(for: backup).path)\nRetained transaction file: \(stage.path)")
            }
            try? FileManager.default.removeItem(at: stage)
            throw EasySignError("\(failure.localizedDescription)\n\(swapped || unlocked ? "Rollback succeeded; original file and lock state restored." : "The target was not modified.")\nBackup: \(backup.id.uuidString)")
        }
        // The original is already retained in the verified backup. A cleanup failure is surfaced, not hidden.
        do { try FileManager.default.removeItem(at: stage) }
        catch { throw EasySignError("The signature was installed and verified, but its temporary original could not be removed: \(stage.path). Your backup is intact. Reload to inspect the installed state.") }
        return backup
    }
}

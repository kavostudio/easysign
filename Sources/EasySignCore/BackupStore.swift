import Foundation
import Darwin

public struct BackupRecord: Codable, Identifiable, Sendable {
    public let id: UUID
    public let date: Date
    public let originalPath: String
    public let metadata: FileMetadata
    public let digest: String
    public let reason: String
}

public struct BackupStore: Sendable {
    public let directory: URL
    public init(directory: URL) { self.directory = directory }

    public func list() throws -> [BackupRecord] {
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { !$0.lastPathComponent.hasPrefix(".") }
            .map { try JSONDecoder().decode(BackupRecord.self, from: Data(contentsOf: $0.appendingPathComponent("record.json"))) }
            .sorted { $0.date > $1.date }
    }

    public func payload(for record: BackupRecord) -> URL {
        directory.appendingPathComponent(record.id.uuidString).appendingPathComponent("original.mailsignature")
    }

    public func verify(_ record: BackupRecord) throws -> FileSnapshot {
        let snapshot = try FileSnapshot(url: payload(for: record))
        guard snapshot.digest == record.digest,
              snapshot.metadata.modifiedSeconds == record.metadata.modifiedSeconds,
              snapshot.metadata.modifiedNanos == record.metadata.modifiedNanos,
              record.metadata.equivalentPermissions(to: snapshot.metadata, flags: record.metadata.flags & ~UInt32(UF_IMMUTABLE)) else {
            throw EasySignError("Backup contents or metadata failed verification. Nothing was changed.")
        }
        return snapshot
    }

    public func create(from snapshot: FileSnapshot, reason: String) throws -> BackupRecord {
        try snapshot.requireUnchanged()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let record = BackupRecord(id: UUID(), date: Date(), originalPath: snapshot.url.path,
                                  metadata: snapshot.metadata, digest: snapshot.digest, reason: reason)
        let pending = directory.appendingPathComponent(".pending-\(record.id.uuidString)")
        try FileManager.default.createDirectory(at: pending, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let content = pending.appendingPathComponent("original.mailsignature")
        do {
            try copyCompleteFile(from: snapshot.url, to: content)
            try setFlags(snapshot.metadata.flags & ~UInt32(UF_IMMUTABLE), at: content)
            let copied = try FileSnapshot(url: content)
            guard copied.data == snapshot.data,
                  snapshot.metadata.equivalentPermissions(to: copied.metadata, flags: copied.metadata.flags) else {
                throw EasySignError("The backup copy did not match the original.")
            }
            try snapshot.requireUnchanged()
            try JSONEncoder().encode(record).write(to: pending.appendingPathComponent("record.json"), options: .atomic)
            try FileManager.default.moveItem(at: pending, to: directory.appendingPathComponent(record.id.uuidString))
            _ = try verify(record)
            return record
        } catch {
            // Keep failed backup artifacts for diagnosis; never silently delete a backup.
            throw EasySignError("Backup failed before modifying the signature: \(error.localizedDescription)")
        }
    }
}

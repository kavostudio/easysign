import Foundation
import CryptoKit
import Darwin

public struct FileMetadata: Codable, Equatable, Sendable {
    public let device: Int32
    public let inode: UInt64
    public let mode: UInt16
    public let owner: UInt32
    public let group: UInt32
    public let flags: UInt32
    public let modifiedSeconds: Int64
    public let modifiedNanos: Int64
    public let changedSeconds: Int64
    public let changedNanos: Int64
    public let createdSeconds: Int64
    public let createdNanos: Int64
    public let extendedAttributes: [String: Data]
    public let acl: String?
    public var isLocked: Bool { flags & UInt32(UF_IMMUTABLE) != 0 }

    public init(url: URL) throws {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { throw posixError("Read file information") }
        guard info.st_mode & S_IFMT == S_IFREG, info.st_nlink == 1 else {
            throw EasySignError("Choose a regular signature file, not a symbolic link or hard link.")
        }
        guard info.st_flags & UInt32(SF_IMMUTABLE | SF_APPEND | UF_APPEND) == 0 else {
            throw EasySignError("This file has unsupported system or append-only protection.")
        }
        device = info.st_dev; inode = info.st_ino; mode = info.st_mode & 0o7777
        owner = info.st_uid; group = info.st_gid; flags = info.st_flags
        modifiedSeconds = Int64(info.st_mtimespec.tv_sec); modifiedNanos = Int64(info.st_mtimespec.tv_nsec)
        changedSeconds = Int64(info.st_ctimespec.tv_sec); changedNanos = Int64(info.st_ctimespec.tv_nsec)
        createdSeconds = Int64(info.st_birthtimespec.tv_sec); createdNanos = Int64(info.st_birthtimespec.tv_nsec)
        let count = listxattr(url.path, nil, 0, XATTR_NOFOLLOW)
        guard count >= 0 else { throw posixError("Read extended attributes") }
        var names = [CChar](repeating: 0, count: count)
        if count > 0 {
            guard listxattr(url.path, &names, count, XATTR_NOFOLLOW) == count else { throw posixError("Read attribute names") }
        }
        var attributes: [String: Data] = [:]
        for nameBytes in names.split(separator: 0) {
            let name = String(decoding: nameBytes.map { UInt8(bitPattern: $0) }, as: UTF8.self)
            let size = getxattr(url.path, name, nil, 0, 0, XATTR_NOFOLLOW)
            guard size >= 0 else { throw posixError("Read attribute size") }
            var data = Data(count: size)
            let read = data.withUnsafeMutableBytes { getxattr(url.path, name, $0.baseAddress, size, 0, XATTR_NOFOLLOW) }
            guard read == size else { throw posixError("Read attribute") }
            attributes[name] = data
        }
        extendedAttributes = attributes
        if let aclValue = acl_get_file(url.path, ACL_TYPE_EXTENDED) {
            defer { acl_free(UnsafeMutableRawPointer(aclValue)) }
            var size: ssize_t = 0
            guard let text = acl_to_text(aclValue, &size) else { throw posixError("Read ACL") }
            defer { acl_free(text) }
            acl = String(cString: text)
        } else if errno == ENOENT { acl = nil }
        else { throw posixError("Read ACL") }
    }

    func equivalentPermissions(to other: Self, flags expectedFlags: UInt32, excludingQuarantine: Bool = false) -> Bool {
        permissionDifferences(to: other, flags: expectedFlags, excludingQuarantine: excludingQuarantine).isEmpty
    }

    // Only category names are exposed; never include attribute values or account identifiers.
    func permissionDifferences(to other: Self, flags expectedFlags: UInt32, excludingQuarantine: Bool = false) -> [String] {
        var expectedAttributes = extendedAttributes
        if excludingQuarantine { expectedAttributes.removeValue(forKey: "com.apple.quarantine") }
        var differences: [String] = []
        if mode != other.mode { differences.append("permissions") }
        if owner != other.owner { differences.append("file owner") }
        if group != other.group { differences.append("file group") }
        if other.flags != expectedFlags { differences.append("file flags") }
        if expectedAttributes != other.extendedAttributes { differences.append("extended attributes") }
        if acl != other.acl { differences.append("access rules") }
        if createdSeconds != other.createdSeconds || createdNanos != other.createdNanos { differences.append("creation date") }
        return differences
    }

}

public struct FileSnapshot: Sendable {
    public let url: URL
    public let data: Data
    public let metadata: FileMetadata
    public var digest: String { Self.digest(data) }

    public init(url: URL) throws {
        guard url.pathExtension.lowercased() == "mailsignature" else { throw EasySignError("Select a .mailsignature file.") }
        let before = try FileMetadata(url: url)
        let values = try url.resourceValues(forKeys: [.fileSizeKey])
        guard let size = values.fileSize, size <= 10_000_000 else { throw EasySignError("Signature exceeds the 10 MB limit.") }
        data = try Data(contentsOf: url)
        metadata = try FileMetadata(url: url)
        guard metadata == before else { throw EasySignError("The file changed while being read. Reload it and retry.") }
        self.url = url
    }

    public func requireUnchanged() throws {
        let now = try FileSnapshot(url: url)
        guard data == now.data, metadata == now.metadata else {
            throw EasySignError("The selected file changed outside EasySign. Reload it before applying.")
        }
    }

    public static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

func posixError(_ operation: String) -> EasySignError {
    EasySignError("\(operation): \(String(cString: strerror(errno)))")
}

func setFlags(_ flags: UInt32, at url: URL) throws {
    guard chflags(url.path, flags) == 0 else { throw posixError("Set file lock state") }
}

func copyCompleteFile(from source: URL, to destination: URL) throws {
    let original = try FileMetadata(url: source)
    guard copyfile(source.path, destination.path, nil, copyfile_flags_t(COPYFILE_ALL | COPYFILE_EXCL | COPYFILE_NOFOLLOW)) == 0 else {
        throw posixError("Copy file and metadata")
    }
    try setFlags(original.flags & ~UInt32(UF_IMMUTABLE), at: destination)
    try restoreACL(original, at: destination)
    try restoreAttributes(original, at: destination)
    try restoreDates(original, at: destination)
}

/// copyfile recomputes inherited ACL entries for the destination directory.
/// Backups and staged replacements must retain the source's exact access rules.
func restoreACL(_ metadata: FileMetadata, at destination: URL) throws {
    let permissions: acl_t?
    if let text = metadata.acl {
        permissions = acl_from_text(text)
    } else {
        permissions = acl_init(0)
    }
    guard let permissions else { throw posixError("Prepare original access rules") }
    defer { acl_free(UnsafeMutableRawPointer(permissions)) }
    guard acl_set_file(destination.path, ACL_TYPE_EXTENDED, permissions) == 0 else {
        throw posixError("Preserve original access rules")
    }
}

/// copyfile can alter quarantine flags. Restore exact xattr bytes, including quarantine, before verification.
func restoreAttributes(_ metadata: FileMetadata, at destination: URL) throws {
    let copied = try FileMetadata(url: destination)
    for name in copied.extendedAttributes.keys where metadata.extendedAttributes[name] == nil {
        guard removexattr(destination.path, name, XATTR_NOFOLLOW) == 0 else { throw posixError("Preserve extended attributes") }
    }
    for (name, value) in metadata.extendedAttributes where copied.extendedAttributes[name] != value {
        let result = value.withUnsafeBytes { setxattr(destination.path, name, $0.baseAddress, value.count, 0, XATTR_NOFOLLOW) }
        guard result == 0 else { throw posixError("Preserve extended attribute") }
    }
}

func restoreDates(_ metadata: FileMetadata, at destination: URL) throws {
    var attributes = attrlist()
    attributes.bitmapcount = UInt16(ATTR_BIT_MAP_COUNT)
    attributes.commonattr = attrgroup_t(ATTR_CMN_CRTIME | ATTR_CMN_MODTIME)
    var dates = [
        timespec(tv_sec: Int(metadata.createdSeconds), tv_nsec: Int(metadata.createdNanos)),
        timespec(tv_sec: Int(metadata.modifiedSeconds), tv_nsec: Int(metadata.modifiedNanos))
    ]
    let result = dates.withUnsafeMutableBytes {
        setattrlist(destination.path, &attributes, $0.baseAddress, $0.count, UInt32(FSOPT_NOFOLLOW))
    }
    guard result == 0 else { throw posixError("Preserve file timestamps") }
}

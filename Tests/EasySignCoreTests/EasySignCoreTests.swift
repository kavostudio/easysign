import XCTest
import Foundation
import Darwin
@testable import EasySignCore

final class EasySignCoreTests: XCTestCase {
    private func document(_ html: String = "<b>Original</b>", transfer: String = "8bit", charset: String = "utf-8", newline: String = "\n") -> Data {
        Data(("Content-Transfer-Encoding: \(transfer)\(newline)Content-Type: text/html;\(newline)\tcharset=\(charset)\(newline)Message-Id: <fixture@example.invalid>\(newline)Mime-Version: 1.0 (Mac OS X Mail 16.0 \\(3864.600.51.1.1\\))\(newline)\(newline)" + html).utf8)
    }

    private func fixture(locked: Bool = false) throws -> (URL, FileSnapshot, BackupStore) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("EasySignTests-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        let file = root.appendingPathComponent("fixture.mailsignature")
        try document().write(to: file)
        guard chmod(file.path, 0o640) == 0 else { throw posixError("Fixture permissions") }
        let attribute = Data("fixture-attribute".utf8)
        let result = attribute.withUnsafeBytes { setxattr(file.path, "com.easysign.fixture", $0.baseAddress, attribute.count, 0, 0) }
        XCTAssertEqual(result, 0)
        if locked { try setFlags(UInt32(UF_IMMUTABLE), at: file) }
        addTeardownBlock {
            if let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) {
                for case let url as URL in enumerator { _ = chflags(url.path, 0) }
            }
            try FileManager.default.removeItem(at: root)
        }
        return (root, try FileSnapshot(url: file), BackupStore(directory: root.appendingPathComponent("Backups")))
    }

    private func addFixtureACL(at url: URL, permissions: String) throws {
        let command = Process()
        command.executableURL = URL(fileURLWithPath: "/bin/chmod")
        command.arguments = ["+a", "user:\(NSUserName()) allow \(permissions)", url.path]
        try command.run()
        command.waitUntilExit()
        XCTAssertEqual(command.terminationStatus, 0)
    }

    func testBackupPreservesInheritedACLForEmptySignature() throws {
        for locked in [false, true] {
            let (_, original, backups) = try fixture()
            try document("").write(to: original.url)
            try addFixtureACL(at: original.url, permissions: "read,write,readattr,writeattr,readextattr,writeextattr,readsecurity,writesecurity,inherited")
            if locked { try setFlags(UInt32(UF_IMMUTABLE), at: original.url) }
            let loaded = try FileSnapshot(url: original.url)
            let writer = SignatureWriter(backups: backups, requireMailClosed: {})
            let record = try writer.apply(html: "<b>Hello Ž</b>", to: loaded)
            XCTAssertEqual(try backups.verify(record).metadata.acl, loaded.metadata.acl)
            let applied = try FileSnapshot(url: original.url)
            XCTAssertEqual(applied.metadata.acl, loaded.metadata.acl)
            XCTAssertEqual(try SignatureDocument(data: applied.data).html, "<b>Hello Ž</b>")
            XCTAssertTrue(applied.metadata.isLocked)
            try writer.restore(record, to: applied)
            let restored = try FileSnapshot(url: original.url)
            XCTAssertEqual(restored.data, loaded.data)
            XCTAssertEqual(restored.metadata.acl, loaded.metadata.acl)
            XCTAssertEqual(restored.metadata.isLocked, locked)
        }
    }

    func testBackupDoesNotAcquireDestinationFolderACL() throws {
        let (_, original, backups) = try fixture()
        try FileManager.default.createDirectory(at: backups.directory, withIntermediateDirectories: true)
        try addFixtureACL(at: backups.directory, permissions: "read,readattr,readextattr,readsecurity,file_inherit,directory_inherit")
        let record = try backups.create(from: original, reason: "Test")
        XCTAssertEqual(try backups.verify(record).metadata.acl, original.metadata.acl)
        try original.requireUnchanged()
    }

    func testInheritedACLSurvivesRollback() throws {
        let (_, original, backups) = try fixture()
        try addFixtureACL(at: original.url, permissions: "read,readattr,readsecurity,inherited")
        try setFlags(UInt32(UF_IMMUTABLE), at: original.url)
        let loaded = try FileSnapshot(url: original.url)
        var writer = SignatureWriter(backups: backups, requireMailClosed: {})
        writer.checkpoint = { if $0 == .replaced { throw EasySignError("Injected failure") } }
        XCTAssertThrowsError(try writer.apply(html: "new", to: loaded)) { error in
            XCTAssertTrue(error.localizedDescription.contains("Rollback succeeded"))
        }
        let restored = try FileSnapshot(url: original.url)
        XCTAssertEqual(restored.data, loaded.data)
        XCTAssertEqual(restored.metadata.acl, loaded.metadata.acl)
        XCTAssertTrue(restored.metadata.isLocked)
        XCTAssertEqual(try backups.list().count, 1)
    }

    func testRealMailStyleHeadersAndUnicodeRoundTrip() throws {
        let html = "<!doctype html><html><head><style>@media(max-width:400px){td{font-family:'Inter';}}</style></head><body><table><tr><td>Žofia 日本 👋</td></tr></table><a href='https://example.invalid'>Link</a><img src='https://example.invalid/a.png'></body></html>"
        for newline in ["\n", "\r\n"] {
            for transfer in ["8bit", "binary", "quoted-printable", "base64"] {
                let input = document(transfer == "base64" ? Data("old".utf8).base64EncodedString() : "old", transfer: transfer, newline: newline)
                let parsed = try SignatureDocument(data: input)
                let output = try SignatureDocument(data: parsed.replacingHTML(html))
                XCTAssertEqual(output.html, html)
                XCTAssertEqual(output.headers, parsed.headers)
                XCTAssertEqual(output.transferEncoding, transfer)
            }
        }
    }

    func testFragmentsAndWhitespaceArePreserved() throws {
        let parsed = try SignatureDocument(data: document("old", transfer: "quoted-printable"))
        let source = "<span style=\"font-family:Arial\">Ľubo</span>  \r\n\n\t"
        XCTAssertEqual(try SignatureDocument(data: parsed.replacingHTML(source)).html, source)
    }

    func testQuotedPrintableDecoding() throws {
        XCTAssertEqual(try SignatureDocument(data: document("a=3Db=\r\n=C5=BD", transfer: "quoted-printable")).html, "a=bŽ")
        XCTAssertThrowsError(try SignatureDocument(data: document("broken=XX", transfer: "quoted-printable")))
    }

    func testRejectUnknownAndLossyEncodings() throws {
        XCTAssertThrowsError(try SignatureDocument(data: document("abc", transfer: "unknown")))
        XCTAssertThrowsError(try SignatureDocument(data: document("abc", charset: "unknown")))
        XCTAssertThrowsError(try SignatureDocument(data: document("abc", transfer: "7bit")).replacingHTML("你好"))
        XCTAssertThrowsError(try SignatureDocument(data: document("abc", charset: "us-ascii")).replacingHTML("Ž"))
        XCTAssertThrowsError(try SignatureDocument(data: document("abc", transfer: "base64")))
        XCTAssertThrowsError(try SignatureDocument(data: Data("just HTML".utf8)))
        XCTAssertThrowsError(try SignatureDocument(data: Data("Mime-Version: 1.0\nContent-Type: multipart/mixed\n\nno".utf8)))
    }

    func testLegacyCharsets() throws {
        for charset in ["iso-8859-1", "windows-1252"] {
            let parsed = try SignatureDocument(data: document("plain", charset: charset))
            XCTAssertEqual(try SignatureDocument(data: parsed.replacingHTML("André")).html, "André")
            XCTAssertThrowsError(try parsed.replacingHTML("你好"))
        }
    }

    func testApplyLockedAndUnlockedAndRestoreTwoRevisions() throws {
        for locked in [true, false] {
            let (_, original, backups) = try fixture(locked: locked)
            let writer = SignatureWriter(backups: backups, requireMailClosed: {})
            let preFirst = try writer.apply(html: "<b>First Ž</b>", to: original)
            let first = try FileSnapshot(url: original.url)
            XCTAssertTrue(first.metadata.isLocked)
            XCTAssertEqual(first.metadata.mode, original.metadata.mode)
            XCTAssertEqual(first.metadata.extendedAttributes, original.metadata.extendedAttributes)
            XCTAssertEqual(first.metadata.acl, original.metadata.acl)
            XCTAssertEqual(try SignatureDocument(data: first.data).headers, try SignatureDocument(data: original.data).headers)
            let preSecond = try writer.apply(html: "<b>Second</b>", to: first)
            let second = try FileSnapshot(url: original.url)
            try writer.restore(preSecond, to: second)
            let restored = try FileSnapshot(url: original.url)
            XCTAssertEqual(restored.data, first.data)
            XCTAssertTrue(restored.metadata.isLocked)
            try writer.restore(preFirst, to: restored)
            let final = try FileSnapshot(url: original.url)
            XCTAssertEqual(final.data, original.data)
            XCTAssertEqual(final.metadata.isLocked, locked)
            XCTAssertEqual(final.metadata.modifiedSeconds, original.metadata.modifiedSeconds)
            XCTAssertEqual(final.metadata.modifiedNanos, original.metadata.modifiedNanos)
            XCTAssertEqual(final.metadata.createdSeconds, original.metadata.createdSeconds)
            XCTAssertEqual(final.metadata.createdNanos, original.metadata.createdNanos)
            XCTAssertEqual(try backups.list().count, 4)
        }
    }

    func testExternalContentAndIdentityChangesAreRejected() throws {
        let (_, original, backups) = try fixture()
        try document("External").write(to: original.url)
        XCTAssertThrowsError(try SignatureWriter(backups: backups, requireMailClosed: {}).apply(html: "New", to: original))
        XCTAssertTrue(try backups.list().isEmpty)
        let loaded = try FileSnapshot(url: original.url)
        try loaded.data.write(to: loaded.url, options: .atomic)
        XCTAssertThrowsError(try loaded.requireUnchanged())
    }

    func testFailureAtEveryCheckpointRollsBackAndKeepsBackup() throws {
        for locked in [true, false] {
            for phase in [WritePhase.backupCreated, .staged, .unlocked, .replaced, .verified, .locked] {
                let (_, original, backups) = try fixture(locked: locked)
                var writer = SignatureWriter(backups: backups, requireMailClosed: {})
                writer.checkpoint = { if $0 == phase { throw EasySignError("Injected failure") } }
                XCTAssertThrowsError(try writer.apply(html: "New", to: original))
                let final = try FileSnapshot(url: original.url)
                XCTAssertEqual(final.data, original.data, "\(phase)")
                XCTAssertEqual(final.metadata.isLocked, locked, "\(phase)")
                XCTAssertEqual(final.metadata.mode, original.metadata.mode)
                XCTAssertEqual(final.metadata.extendedAttributes, original.metadata.extendedAttributes)
                XCTAssertEqual(try backups.list().count, 1)
            }
        }
    }

    func testMailRunningBlocksWithoutBackup() throws {
        let (_, original, backups) = try fixture()
        let writer = SignatureWriter(backups: backups) { throw EasySignError("Mail running") }
        XCTAssertThrowsError(try writer.apply(html: "new", to: original))
        try original.requireUnchanged()
        XCTAssertTrue(try backups.list().isEmpty)
    }

    func testMailReopeningBeforeAndAfterSwapRollsBack() throws {
        for phase in [WritePhase.staged, .unlocked, .replaced, .locked] {
            let (_, original, backups) = try fixture(locked: true)
            var running = false
            var writer = SignatureWriter(backups: backups) { if running { throw EasySignError("Mail reopened") } }
            writer.checkpoint = { if $0 == phase { running = true } }
            XCTAssertThrowsError(try writer.apply(html: "new", to: original))
            let final = try FileSnapshot(url: original.url)
            XCTAssertEqual(final.data, original.data)
            XCTAssertTrue(final.metadata.isLocked)
        }
    }

    func testExternalChangeAfterBackupStopsWrite() throws {
        let (_, original, backups) = try fixture()
        let external = document("External editor")
        var writer = SignatureWriter(backups: backups, requireMailClosed: {})
        writer.checkpoint = { if $0 == .staged { try external.write(to: original.url) } }
        XCTAssertThrowsError(try writer.apply(html: "new", to: original))
        XCTAssertEqual(try Data(contentsOf: original.url), external)
    }

    func testRollbackDoesNotClobberExternalEdit() throws {
        let (_, original, backups) = try fixture()
        let external = document("External editor")
        var writer = SignatureWriter(backups: backups, requireMailClosed: {})
        writer.checkpoint = { if $0 == .replaced { try external.write(to: original.url); throw EasySignError("Injected") } }
        XCTAssertThrowsError(try writer.apply(html: "new", to: original)) { error in
            XCTAssertTrue(error.localizedDescription.contains("Rollback failed"))
        }
        XCTAssertEqual(try Data(contentsOf: original.url), external)
        let record = try XCTUnwrap(backups.list().first)
        XCTAssertEqual(try backups.verify(record).data, original.data)
    }

    func testCorruptBackupIsRejected() throws {
        let (_, original, backups) = try fixture()
        let record = try backups.create(from: original, reason: "Test")
        try Data("corrupt".utf8).write(to: backups.payload(for: record))
        XCTAssertThrowsError(try SignatureWriter(backups: backups, requireMailClosed: {}).restore(record, to: original))
        try original.requireUnchanged()
    }

    func testQuarantineIsPreservedByDefaultAndRestoredAfterTargetedRemoval() throws {
        let (_, original, backups) = try fixture()
        let quarantine = Data("0083;00000000;EasySignTests;".utf8)
        XCTAssertEqual(quarantine.withUnsafeBytes { setxattr(original.url.path, "com.apple.quarantine", $0.baseAddress, quarantine.count, 0, 0) }, 0)
        let loaded = try FileSnapshot(url: original.url)
        let writer = SignatureWriter(backups: backups, requireMailClosed: {})
        try writer.apply(html: "first", to: loaded)
        let first = try FileSnapshot(url: original.url)
        XCTAssertEqual(first.metadata.extendedAttributes["com.apple.quarantine"], quarantine)
        let record = try writer.apply(html: "second", to: first, removeQuarantine: true)
        let second = try FileSnapshot(url: original.url)
        XCTAssertNil(second.metadata.extendedAttributes["com.apple.quarantine"])
        try writer.restore(record, to: second)
        XCTAssertEqual(try FileSnapshot(url: original.url).metadata.extendedAttributes["com.apple.quarantine"], quarantine)
    }

    func testDiscoveryReturnsAllVersionsAndExactNamesOnly() throws {
        let (root, original, _) = try fixture()
        for version in ["V9", "V10", "V200"] {
            let directory = root.appendingPathComponent("\(version)/MailData/Signatures")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try original.data.write(to: directory.appendingPathComponent("known.mailsignature"))
            try original.data.write(to: directory.appendingPathComponent("unmapped.mailsignature"))
            let rows = [["SignatureUniqueId": "known", "SignatureName": "Exact fixture name"]]
            try PropertyListSerialization.data(fromPropertyList: rows, format: .binary, options: 0).write(to: directory.appendingPathComponent("AllSignatures.plist"))
        }
        let candidates = try SignatureDiscovery.candidates(in: root)
        XCTAssertEqual(candidates.count, 3)
        let entries = try SignatureDiscovery.signatures(in: candidates[0])
        XCTAssertTrue(entries.contains { $0.name == "Exact fixture name" })
        XCTAssertTrue(entries.contains { $0.name == "unmapped.mailsignature" })
        XCTAssertEqual(try FileSnapshot(url: original.url).data, original.data) // manual file selection
    }

    func testPermissionDenialAndRetry() throws {
        let (root, _, _) = try fixture()
        let folder = root.appendingPathComponent("Denied")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        XCTAssertEqual(chmod(folder.path, 0), 0)
        XCTAssertThrowsError(try SignatureDiscovery.signatures(in: folder))
        XCTAssertEqual(chmod(folder.path, 0o700), 0)
        XCTAssertEqual(try SignatureDiscovery.signatures(in: folder).count, 0)
    }

    func testBackupWriteFailureLeavesTargetUntouched() throws {
        let (root, original, _) = try fixture(locked: true)
        let folder = root.appendingPathComponent("Denied")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        XCTAssertEqual(chmod(folder.path, 0o500), 0)
        defer { _ = chmod(folder.path, 0o700) }
        XCTAssertThrowsError(try SignatureWriter(backups: BackupStore(directory: folder), requireMailClosed: {}).apply(html: "new", to: original))
        try original.requireUnchanged()
    }

    func testStagingWriteFailureLeavesTargetUntouched() throws {
        let (root, original, backups) = try fixture(locked: true)
        var writer = SignatureWriter(backups: backups, requireMailClosed: {})
        writer.checkpoint = { if $0 == .backupCreated { XCTAssertEqual(chmod(root.path, 0o500), 0) } }
        defer { _ = chmod(root.path, 0o700) }
        XCTAssertThrowsError(try writer.apply(html: "new", to: original))
        try original.requireUnchanged()
    }

    func testSymlinksAndHardlinksAreRejected() throws {
        let (root, original, _) = try fixture()
        let link = root.appendingPathComponent("link.mailsignature")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: original.url)
        XCTAssertThrowsError(try FileSnapshot(url: link))
        let hardlink = root.appendingPathComponent("hardlink.mailsignature")
        try FileManager.default.linkItem(at: original.url, to: hardlink)
        XCTAssertThrowsError(try FileSnapshot(url: hardlink))
    }

    func testHTMLWarnings() {
        XCTAssertFalse(SignatureDocument.warnings(for: "<img src='file:///tmp/a.png'>").isEmpty)
        XCTAssertFalse(SignatureDocument.warnings(for: "<img src='logo.png'>").isEmpty)
        XCTAssertFalse(SignatureDocument.warnings(for: "<img><img src=''>").isEmpty)
        XCTAssertTrue(SignatureDocument.warnings(for: "<img src='https://example.invalid/a.png'>").isEmpty)
    }
}

extension EasySignCoreTests {
    func testExplicitRecoveryOfPreviouslyPastedRawHTML() throws {
        let (_, original, backups) = try fixture()
        let raw = document("<span style=\"color:red\">Ž</span>", transfer: "quoted-printable")
        try raw.write(to: original.url)
        let loaded = try FileSnapshot(url: original.url)
        XCTAssertThrowsError(try SignatureDocument(data: loaded.data))
        let recovered = try SignatureDocument(data: loaded.data, allowUnencodedQuotedPrintable: true)
        XCTAssertEqual(recovered.html, "<span style=\"color:red\">Ž</span>")
        let writer = SignatureWriter(backups: backups, requireMailClosed: {})
        XCTAssertThrowsError(try writer.apply(html: recovered.html, to: loaded))
        let record = try writer.apply(html: recovered.html, to: loaded, allowUnencodedQuotedPrintable: true)
        let applied = try FileSnapshot(url: original.url)
        XCTAssertEqual(try SignatureDocument(data: applied.data).html, recovered.html)
        XCTAssertEqual(try SignatureDocument(data: applied.data).headers, recovered.headers)
        try writer.restore(record, to: applied)
        XCTAssertEqual(try FileSnapshot(url: original.url).data, raw)
    }
}

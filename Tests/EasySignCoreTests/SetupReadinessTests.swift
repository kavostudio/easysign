import XCTest
import Darwin
@testable import EasySignCore

final class SetupReadinessTests: XCTestCase {
    private func fixture(_ body: String = "", charset: String = "utf-8") throws -> (URL, FileSnapshot) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let file = root.appendingPathComponent("sample.mailsignature")
        try Data("Content-Type: text/html; charset=\(charset)\nContent-Transfer-Encoding: 8bit\nMime-Version: 1.0\n\n\(body)".utf8).write(to: file)
        addTeardownBlock {
            _ = chflags(file.path, 0)
            _ = chmod(root.path, 0o700)
            try FileManager.default.removeItem(at: root)
        }
        return (root, try FileSnapshot(url: file))
    }

    func testMissingAndAmbiguousFolderOfferSelection() {
        for ambiguous in [false, true] {
            let result = SetupReadiness.folder(nil, hasManualFile: false, ambiguous: ambiguous)
            XCTAssertEqual(result.state, .attention)
            XCTAssertEqual(result.action, .chooseFolder)
        }
        XCTAssertEqual(SetupReadiness.folder(nil, hasManualFile: true, ambiguous: false).state, .information)
    }

    func testFolderReadsOnlyAndRecognizesEmptyDirectory() throws {
        let (root, original) = try fixture()
        XCTAssertEqual(SetupReadiness.folder(root, hasManualFile: false, ambiguous: false).state, .ready)
        try original.requireUnchanged()
        try FileManager.default.removeItem(at: original.url)
        XCTAssertEqual(SetupReadiness.folder(root, hasManualFile: false, ambiguous: false).state, .information)
    }

    func testPermissionDenialAndRecovery() throws {
        let (root, _) = try fixture()
        XCTAssertEqual(chmod(root.path, 0), 0)
        XCTAssertEqual(SetupReadiness.folder(root, hasManualFile: false, ambiguous: false).state, .attention)
        XCTAssertEqual(chmod(root.path, 0o700), 0)
        XCTAssertEqual(SetupReadiness.folder(root, hasManualFile: false, ambiguous: false).state, .ready)
    }

    func testEmptyAndLockedSignatureStayUnchanged() throws {
        let (_, original) = try fixture()
        for locked in [false, true] {
            if locked { XCTAssertEqual(chflags(original.url.path, UInt32(UF_IMMUTABLE)), 0) }
            let snapshot = try FileSnapshot(url: original.url)
            let result = SetupReadiness.signature(snapshot, html: "<b>Ž 日本</b>", allowUnencoded: false)
            XCTAssertEqual(result.state, .ready)
            try snapshot.requireUnchanged()
        }
    }

    func testExternalChangesOfferReloadWithoutOverwriting() throws {
        let (_, original) = try fixture()
        let external = Data("external change".utf8)
        try external.write(to: original.url)
        let result = SetupReadiness.signature(original, html: "unsaved editor text", allowUnencoded: false)
        XCTAssertEqual(result.state, .attention)
        XCTAssertEqual(result.action, .reload)
        XCTAssertEqual(try Data(contentsOf: original.url), external)
    }

    func testMissingSelectionAndIncompatibleEdits() throws {
        XCTAssertEqual(SetupReadiness.signature(nil, html: "", allowUnencoded: false).action, .openFile)
        let (_, original) = try fixture(charset: "us-ascii")
        XCTAssertEqual(SetupReadiness.signature(original, html: "日本", allowUnencoded: false).state, .attention)
        try original.requireUnchanged()
    }

    func testUnsupportedFileAndExplicitRecovery() throws {
        let (_, original) = try fixture()
        try Data("not a MIME document".utf8).write(to: original.url)
        let unsupported = try FileSnapshot(url: original.url)
        XCTAssertEqual(SetupReadiness.signature(unsupported, html: "", allowUnencoded: false).state, .attention)
        try Data("Content-Type: text/html; charset=utf-8\nContent-Transfer-Encoding: quoted-printable\nMime-Version: 1.0\n\n<b style=\"color:red\">Hello</b>".utf8).write(to: original.url)
        let raw = try FileSnapshot(url: original.url)
        XCTAssertEqual(SetupReadiness.signature(raw, html: "<b>Hello</b>", allowUnencoded: false).state, .attention)
        XCTAssertEqual(SetupReadiness.signature(raw, html: "<b>Hello</b>", allowUnencoded: true).state, .information)
        try raw.requireUnchanged()
    }
}

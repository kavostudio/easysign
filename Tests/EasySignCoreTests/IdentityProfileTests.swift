import XCTest
@testable import EasySignCore

final class IdentityProfileTests: XCTestCase {
    func testGeneratedScriptsCompile() throws {
        let profile = IdentityProfile(label: "Work", name: "Alex \"A\" | Studio", email: "alex@example.com")
        for source in [MailDraftScript.create(.newMessage), MailDraftScript.create(.reply), MailDraftScript.selection, MailDraftScript.reply(to: 42), try MailDraftScript.apply(profile, id: 12)] {
            let script = try XCTUnwrap(NSAppleScript(source: source))
            var error: NSDictionary?
            XCTAssertTrue(script.compileAndReturnError(&error), "Script failed to compile: \(String(describing: error))")
        }
    }
    func testReplyMessagesSortNewestFirstWithStableTies() {
        let messages = [
            ReplyMessage(id: 3, sender: "A", subject: "Same", received: Date(timeIntervalSince1970: 10)),
            ReplyMessage(id: 2, sender: "A", subject: "Same", received: Date(timeIntervalSince1970: 20)),
            ReplyMessage(id: 1, sender: "A", subject: "Same", received: Date(timeIntervalSince1970: 20))
        ]
        XCTAssertEqual(ReplyMessage.newestFirst(messages).map(\.id), [1, 2, 3])
        XCTAssertEqual(ReplyMessage.newestFirst([]).count, 0)
    }

    func testUnicodeAndQuotedName() throws {
        let p = try IdentityProfile(label: " Work ", name: "Žofia \"Z\" | Studio", email: "alex@example.com").validated()
        XCTAssertEqual(p.label, "Work")
        XCTAssertEqual(p.sender, "\"Žofia \\\"Z\\\" | Studio\" <alex@example.com>")
    }
    func testRejectsHeaderInjectionAndMultipleAddresses() {
        for name in ["Alex\r\nBcc: victim@example.com", "Alex <x>", ""] {
            XCTAssertThrowsError(try IdentityProfile(label: "Test", name: name, email: "alex@example.com").validated())
        }
        for email in ["a@example.com, b@example.com", "a@example.com\nBcc:x@example.com", "not-an-address"] {
            XCTAssertThrowsError(try IdentityProfile(label: "Test", name: "Alex", email: email).validated())
        }
    }
    func testPersistenceAndCorruption() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ProfileStore(url: root.appendingPathComponent("Profiles.json"))
        XCTAssertEqual(try store.load(), [])
        let profiles = [IdentityProfile(label: "Work", name: "Alex", email: "alex@example.com")]
        try store.save(profiles)
        XCTAssertEqual(try store.load(), profiles)
        try Data("broken".utf8).write(to: store.url)
        XCTAssertThrowsError(try store.load())
    }
    func testScriptEscapesUntrustedNamesAndNeverSends() throws {
        let p = IdentityProfile(label: "Test", name: "Alex\" & do shell script \"no", email: "alex@example.com")
        let script = try MailDraftScript.apply(p, id: 12)
        XCTAssertTrue(script.contains("whose id is 12"))
        XCTAssertTrue(script.contains("\\\""))
        XCTAssertFalse(script.contains("\nsend "))
        XCTAssertTrue(MailDraftScript.create(.reply).contains("is 0 then error"))
        XCTAssertTrue(MailDraftScript.reply(to: 42).contains("if id of m is 42"))
        XCTAssertTrue(MailDraftScript.reply(to: 42).contains("Mail’s selection changed"))
        XCTAssertFalse(MailDraftScript.create(.reply).contains("make new to recipient"))
    }
}

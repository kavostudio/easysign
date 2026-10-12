import AppKit
import EasySignCore

@main @MainActor
struct SetupCheck {
    static func main() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let support = root.appendingPathComponent("Support")
        let model = AppModel(supportDirectory: support)
        model.start()
        precondition(model.showingSetup && model.entries.isEmpty && model.error == nil && !model.accessDenied)
        model.start()
        precondition(model.showingSetup)

        let signatures = root.appendingPathComponent("Signatures")
        try FileManager.default.createDirectory(at: signatures, withIntermediateDirectories: true)
        let file = signatures.appendingPathComponent("sample.mailsignature")
        try Data("Content-Type: text/html; charset=utf-8\nContent-Transfer-Encoding: 8bit\nMime-Version: 1.0\n\n<p>Fixture</p>".utf8).write(to: file)
        try model.access.remember(signatures)
        try model.discover(signatures)
        precondition(model.entries.count == 1)
        model.finishSetup()
        precondition(!model.showingSetup && model.error == nil)
        let restarted = AppModel(supportDirectory: support)
        restarted.start()
        precondition(!restarted.showingSetup && restarted.entries.count == 1)
        restarted.select(file)
        restarted.html = "Unsaved"
        restarted.discardDecision = { false }
        restarted.openSetup()
        precondition(!restarted.showingSetup && restarted.dirty)
        restarted.discardDecision = { true }
        restarted.openSetup()
        precondition(restarted.showingSetup && !restarted.dirty)
        restarted.error = "Previous failure"
        try restarted.discover(signatures)
        precondition(restarted.error == nil)

        let blocked = root.appendingPathComponent("NotAFolder")
        try Data().write(to: blocked)
        let failure = AppModel(supportDirectory: blocked)
        failure.showingSetup = true
        failure.finishSetup()
        precondition(failure.showingSetup && failure.error != nil)
        print("Setup checks passed: first run, persistence, saved access, discard protection, retry, and save failure.")
    }
}

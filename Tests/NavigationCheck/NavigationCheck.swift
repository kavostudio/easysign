import AppKit
import EasySignCore

/// Runs against temporary signatures only; no Mail discovery, automation, or writes.
@main @MainActor
struct NavigationCheck {
    static func main() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("EasySignNavigation-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let first = root.appendingPathComponent("first.mailsignature")
        let second = root.appendingPathComponent("second.mailsignature")
        for (url, body) in [(first, "<p>First · Žofia</p>"), (second, "<p>Second</p>")] {
            try Data(("Content-Type: text/html; charset=utf-8\nContent-Transfer-Encoding: 8bit\nMime-Version: 1.0\n\n" + body).utf8).write(to: url)
        }
        let model = AppModel()
        model.select(first)
        precondition(!model.showingProfiles && model.html.contains("First"))
        let original = model.html
        let oldRevision = model.editorRevision
        model.html = "Unsaved"
        model.discardDecision = { false }
        model.select(second)
        precondition(model.selected?.url == first && model.html == "Unsaved")
        precondition(!model.showProfiles() && !model.showingProfiles)
        precondition(!model.closeEditor() && model.dirty)
        model.discardDecision = { true }
        precondition(model.showProfiles() && !model.dirty && model.html == original)
        model.select(first)
        precondition(!model.showingProfiles && model.html == original)
        model.html = "Another edit"
        precondition(model.closeEditor() && model.html == original && !model.dirty)
        model.select(second)
        precondition(model.html == "<p>Second</p>")
        model.editHTML("Stale editor event", revision: oldRevision)
        precondition(model.html == "<p>Second</p>")
        model.html = "Keep after failed load"
        model.select(root.appendingPathComponent("missing.mailsignature"))
        precondition(model.selected?.url == second && model.html == "Keep after failed load" && model.dirty)
        model.busy = true
        model.select(first)
        precondition(model.selected?.url == second && !model.closeEditor())
        model.busy = false
        model.select(first)
        precondition(model.html == original && !model.dirty)
        let unchanged = try String(contentsOf: first, encoding: .utf8)
        precondition(unchanged.hasSuffix(original))
        print("Navigation checks passed: selection, cancel/discard, profiles, close, stale edits, failed load, busy state; fixture files unchanged.")
    }
}

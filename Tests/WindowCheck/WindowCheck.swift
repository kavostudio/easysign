import AppKit
import SwiftUI
import EasySignCore

/// Development-only UI fixture. Never discovers or modifies the real Mail store.
@main @MainActor
struct FixtureWindow {
    static func main() throws {
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        let arguments = Set(CommandLine.arguments)
        let project = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("EasySignWindowCheck-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let isScreenshot = arguments.contains("--screenshot")
        let source = try String(contentsOf: project.appendingPathComponent(isScreenshot ? "Examples/studio-signature.html" : "Examples/revision-one.html"), encoding: .utf8)
        let mime = "Content-Type: text/html; charset=utf-8\nContent-Transfer-Encoding: 8bit\nMime-Version: 1.0\n\n" + source
        var entries: [SignatureEntry] = []
        let names = isScreenshot ? ["Studio", "Personal"] : ["Work signature", "Personal · Žofia", "A very long signature name for international partnerships and correspondence"]
        for (index, name) in names.enumerated() {
            let file = root.appendingPathComponent("fixture-\(index).mailsignature")
            try Data(mime.utf8).write(to: file)
            entries.append(SignatureEntry(url: file, name: name, excerpt: isScreenshot ? "Alex Morgan · Designer" : "Žofia · Example Studio"))
        }
        let fixtureProfiles = ProfileModel(supportDirectory: root)
        fixtureProfiles.save(IdentityProfile(label: "Studio", name: "Alex Morgan | Studio", email: "alex@example.com"))
        fixtureProfiles.save(IdentityProfile(label: "Personal", name: "Alex Morgan", email: "alex@example.com"))
        let model = AppModel(supportDirectory: root)
        if !arguments.contains("--empty") {
            model.entries = entries
            model.select(entries[arguments.contains("--long-title") ? 2 : 0].url)
        } else { model.accessDenied = true }
        if arguments.contains("--check-setup") { model.showingSetupCheck = true }
        if arguments.contains("--setup") { model.showingSetup = true }
        let window = NSWindow(contentRect: NSRect(x: 80, y: 80, width: arguments.contains("--compact") ? 920 : 1240, height: arguments.contains("--compact") ? 620 : 790), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "EasySign — temporary UI fixture"
        window.appearance = NSAppearance(named: arguments.contains("--dark") ? .darkAqua : .aqua)
        if arguments.contains("--menu") {
            window.setContentSize(NSSize(width: 390, height: 240))
            window.contentView = NSHostingView(rootView: ProfileMenu(model: fixtureProfiles))
        } else {
            window.contentView = NSHostingView(rootView: ContentView(model: model, profiles: fixtureProfiles))
        }
        window.makeKeyAndOrderFront(nil)
        app.activate(ignoringOtherApps: true)
        app.run()
    }
}

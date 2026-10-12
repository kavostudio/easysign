import SwiftUI
import EasySignCore

@main @MainActor
struct ReplyPickerCheck {
    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        let now = Date()
        let messages = ReplyMessage.newestFirst([
            ReplyMessage(id: 1, sender: "Maya Chen <maya@example.com>", subject: "Re: Project handover", received: now.addingTimeInterval(-86400)),
            ReplyMessage(id: 2, sender: "Žofia Nováková <zofia@example.com>", subject: "Re: Project handover — final notes and next steps", received: now),
            ReplyMessage(id: 3, sender: "A very long sender name at Example International <partnerships@example.com>", subject: "A longer subject that should wrap cleanly when a conversation contains a detailed description of the upcoming project milestones and launch schedule", received: now.addingTimeInterval(-172800))
        ])
        let choice = ProfileModel.ReplyChoice(profile: IdentityProfile(label: "Test", name: "Test", email: "test@example.com"), messages: messages)
        let window = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 640, height: 460), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "EasySign — Reply picker fixture"
        window.contentView = NSHostingView(rootView: ReplyMessagePicker(choice: choice) { _ in print("Fixture reply selected; no Mail action") })
        window.makeKeyAndOrderFront(nil)
        app.activate(ignoringOtherApps: true)
        app.run()
    }
}

import SwiftUI

/// Isolated update UI: no Mail access, signatures, profiles, or application data.
@main
struct UpdaterCheck: App {
    @StateObject private var updates = AppUpdates()
    var body: some Scene {
        Window("EasySign — updater check", id: "updater-check") {
            VStack(alignment: .leading, spacing: 16) {
                Text("EasySign updater fixture").font(.headline)
                Button("Check for Updates…", action: updates.checkForUpdates)
                    .disabled(!updates.canCheckForUpdates)
                Toggle("Check automatically", isOn: Binding(
                    get: { updates.automaticallyChecksForUpdates },
                    set: { updates.setAutomaticChecks($0) }
                ))
            }.padding(24).frame(width: 320)
        }
    }
}

import SwiftUI

@main
struct EasySignApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var model = AppModel()
    @State private var profiles = ProfileModel()
    @StateObject private var updates = AppUpdates()
    var body: some Scene {
        Window("EasySign", id: "main") {
            ContentView(model: model, profiles: profiles)
                .background(WindowObserver(model: model))
                .task { delegate.model = model; model.start(); profiles.load() }
        }
        .defaultSize(width: 1240, height: 790)
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…", action: updates.checkForUpdates)
                    .disabled(!updates.canCheckForUpdates || model.busy || profiles.busy)
                Toggle("Check for Updates Automatically", isOn: Binding(
                    get: { updates.automaticallyChecksForUpdates },
                    set: { updates.setAutomaticChecks($0) }
                ))
                Divider()
            }
            CommandGroup(after: .help) {
                Button("Set Up EasySign…") { model.openSetup() }
                    .disabled(model.busy || profiles.busy || model.showingSetup)
            }
            CommandGroup(replacing: .newItem) { }
            CommandGroup(replacing: .saveItem) {
                Button("Apply to Mail") { Task { await model.apply() } }
                    .keyboardShortcut("s").disabled(model.showingProfiles || model.selected == nil || model.busy || model.mailRunning)
            }
        }
        MenuBarExtra("EasySign", systemImage: "signature") {
            ProfileMenu(model: profiles, checkForUpdates: updates.checkForUpdates, canCheckForUpdates: updates.canCheckForUpdates && !model.busy)
        }.menuBarExtraStyle(.window)
    }
}

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
    var model: AppModel?
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let model else { return .terminateNow }
        if model.busy { return .terminateCancel }
        return model.confirmDiscard() ? .terminateNow : .terminateCancel
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}

private struct WindowObserver: NSViewRepresentable {
    let model: AppModel
    func makeCoordinator() -> Coordinator { Coordinator(model: model) }
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { view.window?.delegate = context.coordinator }
        return view
    }
    func updateNSView(_ view: NSView, context: Context) { }
    @MainActor final class Coordinator: NSObject, NSWindowDelegate {
        let model: AppModel
        init(model: AppModel) { self.model = model }
        func windowShouldClose(_ sender: NSWindow) -> Bool {
            model.closeEditor()
        }
    }
}

import Combine
import Sparkle

/// One updater for both the application menu and the menu-bar panel.
@MainActor final class AppUpdates: ObservableObject {
    @Published private(set) var canCheckForUpdates = false
    @Published private(set) var automaticallyChecksForUpdates = false
    private let controller: SPUStandardUpdaterController

    init() {
        controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
        controller.updater.publisher(for: \.canCheckForUpdates)
            .assign(to: &$canCheckForUpdates)
        controller.updater.publisher(for: \.automaticallyChecksForUpdates)
            .assign(to: &$automaticallyChecksForUpdates)
        // Signature HTML, profiles, and system profiling are never included in update checks.
        controller.updater.sendsSystemProfile = false
    }

    func checkForUpdates() { controller.checkForUpdates(nil) }
    func setAutomaticChecks(_ enabled: Bool) {
        controller.updater.automaticallyChecksForUpdates = enabled
    }
}

import AppKit
import Sparkle

/// Sparkle self-updates. The feed is `SUFeedURL` in Info.plist (the appcast attached to the latest
/// GitHub release), and updates must be signed with the key whose public half is `SUPublicEDKey`.
@MainActor
final class UpdaterService: ObservableObject {
    static let shared = UpdaterService()

    private let controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: nil, userDriverDelegate: nil)

    /// Local builds have no signing key, so they never check for updates.
    let isAvailable: Bool = {
        let key = Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String ?? ""
        return !key.isEmpty
    }()

    var automaticallyChecks: Bool {
        get { controller.updater.automaticallyChecksForUpdates }
        set {
            objectWillChange.send()
            controller.updater.automaticallyChecksForUpdates = newValue
        }
    }

    func start() {
        guard isAvailable else { return }
        controller.startUpdater()
    }

    func checkForUpdates() {
        guard isAvailable else { return }
        // NotchDeck has no Dock icon, so bring it forward for Sparkle's window.
        NSApp.activate()
        controller.checkForUpdates(nil)
    }
}

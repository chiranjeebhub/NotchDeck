import Foundation

/// UserDefaults keys shared by `@AppStorage` in the settings UI and by the services.
enum AppSettings {
    static let preferredPlayerKey = "preferredPlayer"
    static let showOnAllDisplaysKey = "showOnAllDisplays"
    static let hapticFeedbackKey = "hapticFeedback"

    static func registerDefaults() {
        UserDefaults.standard.register(defaults: [
            preferredPlayerKey: "auto",
            showOnAllDisplaysKey: true,
            hapticFeedbackKey: true,
        ])
    }

    static var showOnAllDisplays: Bool { UserDefaults.standard.bool(forKey: showOnAllDisplaysKey) }
    static var hapticFeedback: Bool { UserDefaults.standard.bool(forKey: hapticFeedbackKey) }
    static var preferredPlayer: String { UserDefaults.standard.string(forKey: preferredPlayerKey) ?? "auto" }
}

extension Notification.Name {
    static let openSettings = Notification.Name("NotchUtility.openSettings")
}

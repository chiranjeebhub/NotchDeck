import Foundation

/// UserDefaults keys shared by `@AppStorage` in the settings UI and by the services.
enum AppSettings {
    static let preferredPlayerKey = "preferredPlayer"
    static let showOnAllDisplaysKey = "showOnAllDisplays"
    static let hapticFeedbackKey = "hapticFeedback"
    static let openOnClickKey = "openOnClick"
    static let hoverDelayKey = "hoverDelay"
    static let devShowAllPortsKey = "devShowAllPorts"

    static func registerDefaults() {
        UserDefaults.standard.register(defaults: [
            preferredPlayerKey: "auto",
            showOnAllDisplaysKey: true,
            hapticFeedbackKey: true,
            openOnClickKey: false,
            hoverDelayKey: 0.15,
            devShowAllPortsKey: false,
        ])
    }

    static var showOnAllDisplays: Bool { UserDefaults.standard.bool(forKey: showOnAllDisplaysKey) }
    static var hapticFeedback: Bool { UserDefaults.standard.bool(forKey: hapticFeedbackKey) }
    static var openOnClick: Bool { UserDefaults.standard.bool(forKey: openOnClickKey) }
    /// Seconds the cursor must rest on the notch before it opens (hover mode).
    static var hoverDelay: Double { UserDefaults.standard.double(forKey: hoverDelayKey) }
    static var preferredPlayer: String { UserDefaults.standard.string(forKey: preferredPlayerKey) ?? "auto" }
}

extension Notification.Name {
    static let openSettings = Notification.Name("NotchUtility.openSettings")
}

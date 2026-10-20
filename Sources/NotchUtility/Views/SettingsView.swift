import ServiceManagement
import SwiftUI

struct SettingsView: View {
    @AppStorage(AppSettings.preferredPlayerKey) private var preferredPlayer = "auto"
    @AppStorage(AppSettings.showOnAllDisplaysKey) private var showOnAllDisplays = true
    @AppStorage(AppSettings.hapticFeedbackKey) private var hapticFeedback = true
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled

    var body: some View {
        Form {
            Section("General") {
                Toggle("Launch at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, enabled in
                        do {
                            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                        } catch {
                            NSLog("NotchUtility: launch at login failed: \(error)")
                            launchAtLogin = SMAppService.mainApp.status == .enabled
                        }
                    }
                Toggle("Show on all displays", isOn: $showOnAllDisplays)
                Toggle("Haptic feedback when opening", isOn: $hapticFeedback)
            }

            Section("Media") {
                Picker("Follow player", selection: $preferredPlayer) {
                    Text("Automatic").tag("auto")
                    ForEach(MediaPlayer.allCases) { player in
                        Text(player.displayName).tag(player.rawValue)
                    }
                }
                Text("Automatic follows whichever app started playing most recently.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Permissions") {
                LabeledContent("Calendar") {
                    Button("Open Settings") { CalendarService.openPrivacySettings() }
                }
                LabeledContent("Automation (music control)") {
                    Button("Open Settings") {
                        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 440)
        .fixedSize(horizontal: false, vertical: true)
    }
}

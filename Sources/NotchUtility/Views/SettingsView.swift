import ServiceManagement
import SwiftUI

struct SettingsView: View {
    @AppStorage(AppSettings.preferredPlayerKey) private var preferredPlayer = "auto"
    @AppStorage(AppSettings.showOnAllDisplaysKey) private var showOnAllDisplays = true
    @AppStorage(AppSettings.hapticFeedbackKey) private var hapticFeedback = true
    @AppStorage(AppSettings.openOnClickKey) private var openOnClick = false
    @AppStorage(AppSettings.hoverDelayKey) private var hoverDelay = 0.15
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

            Section("Opening") {
                Picker("Open the notch", selection: $openOnClick) {
                    Text("On hover").tag(false)
                    Text("On click").tag(true)
                }
                .pickerStyle(.segmented)
                if !openOnClick {
                    LabeledContent("Hover delay") {
                        HStack {
                            Slider(value: $hoverDelay, in: 0...1, step: 0.05)
                                .frame(width: 160)
                            Text(hoverDelay, format: .number.precision(.fractionLength(2)))
                                .monospacedDigit()
                                .frame(width: 34, alignment: .trailing)
                            Text("s")
                        }
                    }
                }
                Text("Dragging a file onto the notch always opens it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Media") {
                Picker("Fallback player", selection: $preferredPlayer) {
                    Text("Automatic").tag("auto")
                    ForEach(MediaPlayer.allCases) { player in
                        Text(player.displayName).tag(player.rawValue)
                    }
                }
                Text("The notch follows whatever macOS shows as Now Playing, including browsers and Podcasts. If that isn't available, it falls back to Spotify and Apple Music: Automatic follows whichever started playing most recently.")
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

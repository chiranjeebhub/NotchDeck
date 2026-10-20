import AppKit

/// Apps with an AppleScript fallback, used when the system-wide adapter is unavailable.
enum MediaPlayer: String, CaseIterable, Identifiable {
    case spotify, music

    var id: String { rawValue }
    var bundleIdentifier: String { self == .spotify ? "com.spotify.client" : "com.apple.Music" }
    /// Name used in `tell application "…"`.
    var scriptName: String { self == .spotify ? "Spotify" : "Music" }
    var displayName: String { self == .spotify ? "Spotify" : "Apple Music" }
    /// Distributed notification each app posts when playback changes.
    var notificationName: Notification.Name {
        Notification.Name(self == .spotify ? "com.spotify.client.PlaybackStateChanged" : "com.apple.Music.playerInfo")
    }

    init?(bundleIdentifier: String) {
        guard let player = Self.allCases.first(where: { $0.bundleIdentifier == bundleIdentifier }) else { return nil }
        self = player
    }
}

struct NowPlaying: Equatable {
    /// The app playing the media; for a browser tab this is the browser.
    var bundleIdentifier: String
    var title: String
    var artist: String
    var album: String
    var duration: TimeInterval
    /// Playback position at `positionDate`; later positions are extrapolated while playing.
    var position: TimeInterval
    var positionDate: Date
    var isPlaying: Bool

    func elapsed(at date: Date = .now) -> TimeInterval {
        guard isPlaying else { return position }
        let value = position + date.timeIntervalSince(positionDate)
        return duration > 0 ? min(value, duration) : value
    }

    var appName: String {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) else {
            return MediaPlayer(bundleIdentifier: bundleIdentifier)?.displayName ?? "the app"
        }
        return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
    }
}

/// Tracks what is playing and sends playback commands.
///
/// The primary source is the system Now Playing state (any app, including browsers and
/// Podcasts), read through `MediaRemoteAdapter`. If that is unavailable, it falls back to
/// Spotify and Apple Music via distributed notifications and AppleScript, which needs the
/// Automation permission.
@MainActor
final class NowPlayingService: NSObject, ObservableObject {
    static let shared = NowPlayingService()

    @Published private(set) var nowPlaying: NowPlaying?
    @Published private(set) var artwork: NSImage?

    private let adapter = MediaRemoteAdapter()
    /// True once the adapter has delivered an update; AppleScript is then not used.
    private var usesAdapter = false
    private var adapterState: NowPlaying?

    private var states: [MediaPlayer: NowPlaying] = [:]
    private var lastChange: [MediaPlayer: Date] = [:]
    private var artworkKey: String?

    func start() {
        adapter.onUpdate = { [weak self] update in self?.handleAdapterUpdate(update) }
        adapter.onUnavailable = { [weak self] in
            guard let self else { return }
            self.usesAdapter = false
            self.adapterState = nil
            self.refreshAll()
        }
        let adapterStarted = adapter.start()

        let distributed = DistributedNotificationCenter.default()
        distributed.addObserver(self, selector: #selector(spotifyChanged), name: MediaPlayer.spotify.notificationName, object: nil)
        distributed.addObserver(self, selector: #selector(musicChanged), name: MediaPlayer.music.notificationName, object: nil)

        let workspace = NSWorkspace.shared.notificationCenter
        workspace.addObserver(self, selector: #selector(appTerminated(_:)), name: NSWorkspace.didTerminateApplicationNotification, object: nil)

        if adapterStarted {
            // Only fall back to AppleScript (and its permission prompt) if the adapter stays silent.
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(2))
                guard let self, !self.usesAdapter else { return }
                self.refreshAll()
            }
        } else {
            refreshAll()
        }
    }

    // MARK: - System Now Playing (adapter)

    private func handleAdapterUpdate(_ update: [String: Any]) {
        usesAdapter = true
        if let encoded = update["artwork"] as? String {
            artwork = Data(base64Encoded: encoded).flatMap(NSImage.init(data:))
        }
        if update["empty"] as? Bool == true {
            adapterState = nil
            artwork = nil
        } else {
            let timestamp = (update["timestamp"] as? Double).map(Date.init(timeIntervalSince1970:)) ?? .now
            adapterState = NowPlaying(
                bundleIdentifier: update["bundleIdentifier"] as? String ?? "",
                title: update["title"] as? String ?? "",
                artist: update["artist"] as? String ?? "",
                album: update["album"] as? String ?? "",
                duration: update["duration"] as? Double ?? 0,
                position: update["elapsed"] as? Double ?? 0,
                positionDate: timestamp,
                isPlaying: update["playing"] as? Bool ?? false
            )
        }
        updateActivePlayer()
    }

    // MARK: - AppleScript fallback

    @objc private func spotifyChanged() { refresh(.spotify) }
    @objc private func musicChanged() { refresh(.music) }

    @objc private func appTerminated(_ notification: Notification) {
        let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
        guard let player = app?.bundleIdentifier.flatMap(MediaPlayer.init(bundleIdentifier:)) else { return }
        states[player] = nil
        updateActivePlayer()
    }

    func refreshAll() {
        for player in MediaPlayer.allCases { refresh(player) }
    }

    func refresh(_ player: MediaPlayer) {
        guard !usesAdapter else { return }
        // Never script an app that isn't running: `tell application` would launch it.
        guard isRunning(player) else {
            states[player] = nil
            updateActivePlayer()
            return
        }
        let source = """
        tell application "\(player.scriptName)"
            set s to player state as string
            if s is "stopped" then return {s}
            set t to current track
            return {s, name of t, artist of t, album of t, duration of t, player position}
        end tell
        """
        guard let result = run(source) else { return }
        let state = result.atIndex(1)?.stringValue ?? "stopped"
        guard state != "stopped", result.numberOfItems >= 6 else {
            states[player] = nil
            updateActivePlayer()
            return
        }

        var duration = result.atIndex(5)?.doubleValue ?? 0
        if player == .spotify { duration /= 1000 } // Spotify reports milliseconds.

        let next = NowPlaying(
            bundleIdentifier: player.bundleIdentifier,
            title: result.atIndex(2)?.stringValue ?? "",
            artist: result.atIndex(3)?.stringValue ?? "",
            album: result.atIndex(4)?.stringValue ?? "",
            duration: duration,
            position: result.atIndex(6)?.doubleValue ?? 0,
            positionDate: .now,
            isPlaying: state == "playing"
        )
        let previous = states[player]
        if previous?.isPlaying != next.isPlaying || previous?.title != next.title {
            lastChange[player] = .now
        }
        states[player] = next
        updateActivePlayer()
    }

    /// Publishes the current track. With the adapter, macOS decides which app is "now playing";
    /// otherwise the preferred player wins, then whichever started playing most recently.
    func updateActivePlayer() {
        let next: NowPlaying?
        if usesAdapter {
            next = adapterState
        } else {
            let chosen: MediaPlayer?
            if let preferred = MediaPlayer(rawValue: AppSettings.preferredPlayer), states[preferred] != nil {
                chosen = preferred
            } else {
                chosen = states.keys.max { a, b in
                    let pa = states[a]?.isPlaying == true, pb = states[b]?.isPlaying == true
                    if pa != pb { return !pa }
                    return (lastChange[a] ?? .distantPast) < (lastChange[b] ?? .distantPast)
                }
            }
            next = chosen.flatMap { states[$0] }
        }
        if next != nowPlaying { nowPlaying = next }
        if !usesAdapter { loadScriptedArtworkIfNeeded() }
    }

    private func loadScriptedArtworkIfNeeded() {
        guard let current = nowPlaying, let player = MediaPlayer(bundleIdentifier: current.bundleIdentifier) else {
            artwork = nil
            artworkKey = nil
            return
        }
        let key = "\(player.rawValue)|\(current.title)|\(current.album)"
        guard key != artworkKey else { return }
        artworkKey = key
        artwork = nil

        switch player {
        case .music:
            if let data = run("tell application \"Music\" to return raw data of artwork 1 of current track")?.data {
                artwork = NSImage(data: data)
            }
        case .spotify:
            guard let string = run("tell application \"Spotify\" to return artwork url of current track")?.stringValue,
                  let url = URL(string: string) else { return }
            Task { [weak self] in
                guard let response = try? await URLSession.shared.data(from: url) else { return }
                guard let self, self.artworkKey == key else { return }
                self.artwork = NSImage(data: response.0)
            }
        }
    }

    // MARK: - Commands

    func togglePlayPause() {
        guard var current = nowPlaying else { return }
        send(adapter: "toggle", script: "playpause")
        // Update optimistically so the UI responds before the next update arrives.
        current.position = current.elapsed()
        current.positionDate = .now
        current.isPlaying.toggle()
        apply(current)
    }

    func nextTrack() {
        send(adapter: "next", script: "next track")
    }

    func previousTrack() {
        send(adapter: "previous", script: "previous track")
    }

    func seek(to time: TimeInterval) {
        guard var current = nowPlaying else { return }
        let target = max(0, time)
        send(adapter: "seek \(target)", script: "set player position to \(target)")
        current.position = target
        current.positionDate = .now
        apply(current)
    }

    func openActivePlayer() {
        guard let identifier = nowPlaying?.bundleIdentifier,
              let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: identifier) else { return }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
    }

    private func apply(_ state: NowPlaying) {
        if usesAdapter {
            adapterState = state
        } else if let player = MediaPlayer(bundleIdentifier: state.bundleIdentifier) {
            states[player] = state
            lastChange[player] = .now
        }
        updateActivePlayer()
    }

    private func send(adapter command: String, script: String) {
        if usesAdapter {
            adapter.send(command)
            return
        }
        guard let identifier = nowPlaying?.bundleIdentifier,
              let player = MediaPlayer(bundleIdentifier: identifier),
              isRunning(player) else { return }
        run("tell application \"\(player.scriptName)\" to \(script)")
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            self?.refresh(player)
        }
    }

    // MARK: - Helpers

    private func isRunning(_ player: MediaPlayer) -> Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: player.bundleIdentifier).isEmpty
    }

    @discardableResult
    private func run(_ source: String) -> NSAppleEventDescriptor? {
        guard let script = NSAppleScript(source: source) else { return nil }
        var error: NSDictionary?
        let result = script.executeAndReturnError(&error)
        if let error {
            NSLog("NotchUtility AppleScript error: \(error)")
            return nil
        }
        return result
    }
}

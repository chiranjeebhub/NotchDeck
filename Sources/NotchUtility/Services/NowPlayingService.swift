import AppKit

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
}

struct NowPlaying: Equatable {
    var player: MediaPlayer
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
}

/// Tracks what Spotify and Apple Music are playing and sends them playback commands.
///
/// State changes arrive as distributed notifications; details and commands go through
/// AppleScript, which needs the Automation permission (prompted on first use).
@MainActor
final class NowPlayingService: NSObject, ObservableObject {
    static let shared = NowPlayingService()

    @Published private(set) var nowPlaying: NowPlaying?
    @Published private(set) var artwork: NSImage?

    private var states: [MediaPlayer: NowPlaying] = [:]
    private var lastChange: [MediaPlayer: Date] = [:]
    private var artworkKey: String?

    func start() {
        let distributed = DistributedNotificationCenter.default()
        distributed.addObserver(self, selector: #selector(spotifyChanged), name: MediaPlayer.spotify.notificationName, object: nil)
        distributed.addObserver(self, selector: #selector(musicChanged), name: MediaPlayer.music.notificationName, object: nil)

        let workspace = NSWorkspace.shared.notificationCenter
        workspace.addObserver(self, selector: #selector(appTerminated(_:)), name: NSWorkspace.didTerminateApplicationNotification, object: nil)

        refreshAll()
    }

    @objc private func spotifyChanged() { refresh(.spotify) }
    @objc private func musicChanged() { refresh(.music) }

    @objc private func appTerminated(_ notification: Notification) {
        let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
        guard let player = MediaPlayer.allCases.first(where: { $0.bundleIdentifier == app?.bundleIdentifier }) else { return }
        states[player] = nil
        updateActivePlayer()
    }

    // MARK: - Reading state

    func refreshAll() {
        for player in MediaPlayer.allCases { refresh(player) }
    }

    func refresh(_ player: MediaPlayer) {
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
            player: player,
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

    /// Picks which player the notch follows: the preferred one if set, otherwise
    /// whichever is playing, breaking ties by the most recent change.
    func updateActivePlayer() {
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
        let next = chosen.flatMap { states[$0] }
        if next != nowPlaying { nowPlaying = next }
        loadArtworkIfNeeded()
    }

    private func loadArtworkIfNeeded() {
        guard let current = nowPlaying else {
            artwork = nil
            artworkKey = nil
            return
        }
        let key = "\(current.player.rawValue)|\(current.title)|\(current.album)"
        guard key != artworkKey else { return }
        artworkKey = key
        artwork = nil

        switch current.player {
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
        send("playpause", to: current.player)
        // Update optimistically so the UI responds before the app's notification arrives.
        current.position = current.elapsed()
        current.positionDate = .now
        current.isPlaying.toggle()
        states[current.player] = current
        lastChange[current.player] = .now
        updateActivePlayer()
    }

    func nextTrack() {
        guard let player = nowPlaying?.player else { return }
        send("next track", to: player)
    }

    func previousTrack() {
        guard let player = nowPlaying?.player else { return }
        send("previous track", to: player)
    }

    func seek(to time: TimeInterval) {
        guard var current = nowPlaying else { return }
        send("set player position to \(max(0, time))", to: current.player)
        current.position = time
        current.positionDate = .now
        states[current.player] = current
        updateActivePlayer()
    }

    func openActivePlayer() {
        guard let player = nowPlaying?.player,
              let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: player.bundleIdentifier) else { return }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
    }

    private func send(_ command: String, to player: MediaPlayer) {
        guard isRunning(player) else { return }
        run("tell application \"\(player.scriptName)\" to \(command)")
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

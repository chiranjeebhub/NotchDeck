import SwiftUI

struct MediaPlayerView: View {
    @ObservedObject private var media = NowPlayingService.shared

    var body: some View {
        if let nowPlaying = media.nowPlaying {
            HStack(spacing: 14) {
                ArtworkView(image: media.artwork, cornerRadius: 12)
                    .frame(width: 104, height: 104)
                    .onTapGesture { media.openActivePlayer() }
                    .help("Open \(nowPlaying.appName)")

                VStack(alignment: .leading, spacing: 6) {
                    Text(nowPlaying.title)
                        .font(.system(size: 14, weight: .semibold))
                        .lineLimit(1)
                    Text(nowPlaying.artist)
                        .font(.system(size: 12))
                        .foregroundStyle(Color.white.opacity(0.6))
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    PlaybackProgressView(nowPlaying: nowPlaying) { media.seek(to: $0) }
                    HStack(spacing: 26) {
                        ControlButton(systemImage: "backward.fill", size: 16) { media.previousTrack() }
                        ControlButton(systemImage: nowPlaying.isPlaying ? "pause.fill" : "play.fill", size: 22) {
                            media.togglePlayPause()
                        }
                        ControlButton(systemImage: "forward.fill", size: 16) { media.nextTrack() }
                    }
                    .frame(maxWidth: .infinity)
                }
                .frame(maxHeight: 104)
            }
            .frame(maxHeight: .infinity)
        } else {
            VStack(spacing: 6) {
                Image(systemName: "music.note")
                    .font(.system(size: 26))
                    .foregroundStyle(Color.white.opacity(0.4))
                Text("Nothing playing")
                    .font(.system(size: 13, weight: .medium))
                Text("Play something in Spotify or Apple Music.")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.white.opacity(0.5))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

struct ControlButton: View {
    let systemImage: String
    let size: CGFloat
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: size))
                .frame(width: 30, height: 28)
                .contentShape(Rectangle())
                .scaleEffect(isHovering ? 1.12 : 1)
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .animation(.easeOut(duration: 0.12), value: isHovering)
    }
}

struct PlaybackProgressView: View {
    let nowPlaying: NowPlaying
    let onSeek: (TimeInterval) -> Void
    @State private var dragFraction: Double?

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.5)) { context in
            let elapsed = nowPlaying.elapsed(at: context.date)
            let fraction = dragFraction ?? (nowPlaying.duration > 0 ? elapsed / nowPlaying.duration : 0)
            VStack(spacing: 3) {
                GeometryReader { geometry in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.white.opacity(0.2))
                        Capsule().fill(Color.white)
                            .frame(width: geometry.size.width * min(max(fraction, 0), 1))
                    }
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { value in
                                dragFraction = min(max(value.location.x / geometry.size.width, 0), 1)
                            }
                            .onEnded { value in
                                let target = min(max(value.location.x / geometry.size.width, 0), 1)
                                dragFraction = nil
                                onSeek(target * nowPlaying.duration)
                            }
                    )
                }
                .frame(height: 4)

                HStack {
                    Text(Self.format(dragFraction.map { $0 * nowPlaying.duration } ?? elapsed))
                    Spacer()
                    Text("-" + Self.format(nowPlaying.duration - elapsed))
                }
                .font(.system(size: 10).monospacedDigit())
                .foregroundStyle(Color.white.opacity(0.5))
            }
        }
    }

    static func format(_ time: TimeInterval) -> String {
        guard time.isFinite, time > 0 else { return "0:00" }
        let seconds = Int(time)
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}

struct ArtworkView: View {
    let image: NSImage?
    let cornerRadius: CGFloat

    var body: some View {
        ZStack {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                Color.white.opacity(0.1)
                Image(systemName: "music.note")
                    .foregroundStyle(Color.white.opacity(0.5))
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }
}

/// Animated level meter shown while music plays.
struct EqualizerBars: View {
    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 24)) { context in
            let time = context.date.timeIntervalSinceReferenceDate
            GeometryReader { geometry in
                HStack(alignment: .center, spacing: 2) {
                    ForEach(0..<4, id: \.self) { index in
                        let level = abs(sin(time * (2.6 + Double(index) * 0.9) + Double(index) * 1.3))
                        Capsule()
                            .fill(Color.green)
                            .frame(width: 3, height: max(3, geometry.size.height * (0.3 + 0.7 * level)))
                    }
                }
                .frame(width: geometry.size.width, height: geometry.size.height)
            }
        }
    }
}

import QuickLookThumbnailing
import SwiftUI
import UniformTypeIdentifiers

struct TrayView: View {
    let isDropTargeted: Bool
    @ObservedObject private var tray = TrayStore.shared
    @AppStorage(AppSettings.trayShowAirDropKey) private var showAirDrop = true

    var body: some View {
        HStack(spacing: 12) {
            if showAirDrop {
                AirDropTile(urls: tray.urls)
                    .frame(width: 96)
            }

            if tray.items.isEmpty {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(Color.white.opacity(isDropTargeted ? 0.6 : 0.2), style: StrokeStyle(lineWidth: 1.5, dash: [6, 4]))
                    .overlay {
                        VStack(spacing: 6) {
                            Image(systemName: "tray.and.arrow.down")
                                .font(.system(size: 22))
                            Text("Drop files here to keep them handy")
                                .font(.system(size: 12))
                        }
                        .foregroundStyle(Color.white.opacity(0.6))
                    }
            } else {
                VStack(alignment: .trailing, spacing: 4) {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 10) {
                            ForEach(tray.items) { item in
                                TrayItemView(item: item)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                    .frame(maxHeight: .infinity)
                    .background(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(Color.white.opacity(isDropTargeted ? 0.12 : 0.05))
                    )
                    Button("Clear All") { tray.removeAll() }
                        .buttonStyle(.plain)
                        .font(.system(size: 11))
                        .foregroundStyle(Color.white.opacity(0.5))
                }
            }
        }
    }
}

/// Drop files here to AirDrop them; click to AirDrop everything in the tray.
struct AirDropTile: View {
    let urls: [URL]
    @State private var isTargeted = false

    var body: some View {
        Button {
            TrayStore.airDrop(urls)
        } label: {
            VStack(spacing: 6) {
                Image(systemName: "airplayaudio")
                    .font(.system(size: 24))
                Text("AirDrop")
                    .font(.system(size: 11, weight: .medium))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .foregroundStyle(isTargeted ? Color.white : Color.blue)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color.blue.opacity(isTargeted ? 0.8 : 0.15))
            )
            .contentShape(RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(.plain)
        .help(urls.isEmpty ? "Drop files to AirDrop them" : "AirDrop everything in the tray")
        .onDrop(of: [UTType.fileURL], isTargeted: $isTargeted) { providers in
            TrayStore.fileURLs(from: providers) { TrayStore.airDrop($0) }
        }
    }
}

struct TrayItemView: View {
    let item: TrayItem
    @State private var thumbnail: NSImage?
    @State private var isHovering = false

    var body: some View {
        VStack(spacing: 4) {
            Group {
                if let thumbnail {
                    Image(nsImage: thumbnail)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                } else {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: item.url.path))
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                }
            }
            .frame(width: 52, height: 52)

            Text(item.url.lastPathComponent)
                .font(.system(size: 10))
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(width: 72)
        }
        .padding(6)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.white.opacity(isHovering ? 0.1 : 0))
        )
        .overlay(alignment: .topTrailing) {
            if isHovering {
                Button {
                    TrayStore.shared.remove(item)
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 14))
                        .foregroundStyle(Color.white, Color.gray)
                }
                .buttonStyle(.plain)
                .offset(x: 2, y: -2)
            }
        }
        .onHover { isHovering = $0 }
        .onTapGesture(count: 2) { TrayStore.open(item.url) }
        .onDrag { NSItemProvider(contentsOf: item.url) ?? NSItemProvider() }
        .contextMenu {
            Button("Open") { TrayStore.open(item.url) }
            Button("Show in Finder") { TrayStore.revealInFinder(item.url) }
            Button("AirDrop") { TrayStore.airDrop([item.url]) }
            Divider()
            Button("Remove from Tray") { TrayStore.shared.remove(item) }
        }
        .help(item.url.path)
        .task(id: item.url) {
            thumbnail = await Self.loadThumbnail(for: item.url)
        }
    }

    private static func loadThumbnail(for url: URL) async -> NSImage? {
        let request = QLThumbnailGenerator.Request(
            fileAt: url,
            size: CGSize(width: 104, height: 104),
            scale: 2,
            representationTypes: .all
        )
        return try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request).nsImage
    }
}

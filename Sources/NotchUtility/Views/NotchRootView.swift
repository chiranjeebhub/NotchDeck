import SwiftUI
import UniformTypeIdentifiers

struct NotchRootView: View {
    @ObservedObject var viewModel: NotchViewModel
    @ObservedObject private var media = NowPlayingService.shared

    private var isOpen: Bool { viewModel.status == .open }
    private var isPlaying: Bool { media.nowPlaying?.isPlaying ?? false }
    private var showsLive: Bool { viewModel.showsLiveActivity(isPlaying: isPlaying) }
    private var size: CGSize { isOpen ? viewModel.openSize : viewModel.closedSize(isPlaying: isPlaying) }
    private var ear: CGFloat { viewModel.earRadius(isOpen: isOpen) }
    private var bottomRadius: CGFloat { isOpen ? 28 : (viewModel.hasNotch ? 10 : 3) }

    var body: some View {
        content
            .frame(width: size.width, height: size.height, alignment: .top)
            .padding(.horizontal, ear)
            .background(NotchShape(topRadius: ear, bottomRadius: bottomRadius).fill(Color.black))
            .clipShape(NotchShape(topRadius: ear, bottomRadius: bottomRadius))
            .shadow(color: .black.opacity(isOpen ? 0.45 : 0), radius: 10, y: 4)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .animation(.spring(response: 0.38, dampingFraction: 0.8), value: isOpen)
            .animation(.spring(response: 0.38, dampingFraction: 0.8), value: showsLive)
            .animation(.spring(response: 0.38, dampingFraction: 0.85), value: viewModel.openSize.height)
            .preferredColorScheme(.dark)
    }

    @ViewBuilder
    private var content: some View {
        if isOpen {
            OpenNotchView(viewModel: viewModel)
                .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .top)))
        } else if showsLive {
            LiveActivityView(artwork: media.artwork, height: viewModel.notchSize.height)
                .transition(.opacity)
        }
    }
}

/// Compact view shown in the closed notch while music plays.
struct LiveActivityView: View {
    let artwork: NSImage?
    let height: CGFloat

    var body: some View {
        HStack(spacing: 0) {
            ArtworkView(image: artwork, cornerRadius: 4)
                .frame(width: height - 12, height: height - 12)
            Spacer(minLength: 0)
            EqualizerBars()
                .frame(width: height - 12, height: height - 16)
        }
        .padding(.horizontal, 6)
        .frame(maxHeight: .infinity)
    }
}

struct OpenNotchView: View {
    @ObservedObject var viewModel: NotchViewModel
    @ObservedObject private var tray = TrayStore.shared
    private static let contentTopPadding: CGFloat = 8
    private static let contentBottomPadding: CGFloat = 16

    var body: some View {
        VStack(spacing: 0) {
            header
                .frame(height: viewModel.headerHeight)
            Group {
                switch viewModel.tab {
                case .home: HomeView()
                case .tray: TrayView(isDropTargeted: viewModel.isDropTargeted)
                case .dev:
                    DevView { contentHeight in
                        let height = viewModel.headerHeight + Self.contentTopPadding + contentHeight + Self.contentBottomPadding
                        if abs((viewModel.preferredHeight ?? 0) - height) > 1 { viewModel.preferredHeight = height }
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.horizontal, 18)
            .padding(.top, Self.contentTopPadding)
            .padding(.bottom, Self.contentBottomPadding)
        }
        .foregroundStyle(Color.white)
        .onDrop(of: [UTType.fileURL], isTargeted: $viewModel.isDropTargeted) { providers in
            viewModel.tab = .tray
            return tray.handleDrop(providers)
        }
        .onChange(of: viewModel.isDropTargeted) { _, targeted in
            if targeted { viewModel.tab = .tray }
        }
        .onChange(of: viewModel.tab) { _, tab in
            if tab != .dev { viewModel.preferredHeight = nil }
        }
        .onDisappear { viewModel.preferredHeight = nil }
    }

    private static let headerPadding: CGFloat = 16

    /// Width on each side of the camera housing, so nothing in the header sits under it.
    private var headerSideWidth: CGFloat {
        (viewModel.openSize.width - Self.headerPadding * 2 - viewModel.notchSize.width - 16) / 2
    }

    private var header: some View {
        HStack(spacing: 0) {
            HStack(spacing: 2) {
                ForEach(NotchViewModel.Tab.allCases, id: \.self) { tab in
                    TabButton(
                        title: tab.title,
                        systemImage: tab.systemImage,
                        badge: tab == .tray && !tray.items.isEmpty ? tray.items.count : nil,
                        isSelected: viewModel.tab == tab
                    ) {
                        viewModel.tab = tab
                    }
                }
            }
            .frame(width: headerSideWidth, alignment: .leading)

            Spacer(minLength: 0)

            Button {
                NotificationCenter.default.post(name: .openSettings, object: nil)
            } label: {
                Image(systemName: "gearshape.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(Color.white.opacity(0.6))
                    .frame(width: 26, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .frame(width: headerSideWidth, alignment: .trailing)
        }
        .padding(.horizontal, Self.headerPadding)
    }
}

struct TabButton: View {
    let title: String
    let systemImage: String
    var badge: Int?
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: systemImage)
                Text(title)
                if let badge {
                    Text("\(badge)")
                        .font(.system(size: 9, weight: .bold).monospacedDigit())
                        .padding(.horizontal, 4)
                        .background(Capsule().fill(Color.white.opacity(0.25)))
                }
            }
            .font(.system(size: 11, weight: .medium))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Capsule().fill(Color.white.opacity(isSelected ? 0.16 : 0)))
            .foregroundStyle(Color.white.opacity(isSelected ? 1 : 0.55))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

/// Default tab: media player next to the calendar.
struct HomeView: View {
    var body: some View {
        HStack(spacing: 16) {
            MediaPlayerView()
                .frame(width: 300)
            Rectangle()
                .fill(Color.white.opacity(0.12))
                .frame(width: 1)
            CalendarWidgetView()
        }
    }
}

import SwiftUI

/// Dev tab: local servers listening on TCP ports, with Open, Copy URL and Stop.
struct DevView: View {
    @ObservedObject private var service = PortsService.shared
    @AppStorage(AppSettings.devShowAllPortsKey) private var showAll = false

    private var ports: [ListeningPort] { service.visiblePorts(showAll: showAll) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text("Local servers")
                    .font(.system(size: 13, weight: .semibold))
                Text(String(ports.count))
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Color.white.opacity(0.75))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Color.white.opacity(0.12)))
                Spacer()
                SegmentedToggle(options: ["Dev", "All ports"], selection: Binding(
                    get: { showAll ? 1 : 0 },
                    set: { showAll = $0 == 1 }
                ))
                RowIconButton(systemImage: "arrow.clockwise", help: "Refresh") {
                    Task { await service.refresh() }
                }
            }

            if ports.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "network.slash")
                        .font(.system(size: 22))
                        .foregroundStyle(Color.white.opacity(0.4))
                    Text(service.hasLoaded ? "No local servers running" : "Looking for local servers…")
                        .font(.system(size: 12))
                        .foregroundStyle(Color.white.opacity(0.6))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView(showsIndicators: false) {
                    VStack(spacing: 0) {
                        ForEach(Array(ports.enumerated()), id: \.element.id) { index, port in
                            PortRow(port: port, showsDivider: index > 0)
                        }
                    }
                }
            }
        }
        .onAppear { service.startMonitoring() }
        .onDisappear { service.stopMonitoring() }
    }
}

struct PortRow: View {
    let port: ListeningPort
    let showsDivider: Bool
    @State private var isHovering = false
    /// Stop takes two clicks, so a list that shifts while refreshing can't stop the wrong server.
    @State private var isConfirmingStop = false
    @State private var copied = false

    private var dotColor: Color {
        switch port.kind {
        case .web: Color(red: 0.20, green: 0.83, blue: 0.60)
        case .database: Color(red: 0.38, green: 0.65, blue: 0.98)
        case .other: Color(white: 0.45)
        }
    }

    private var title: String { port.projectName ?? port.command }

    private var tag: String? {
        switch port.kind {
        case .database: "database"
        case .web: port.projectName == nil ? nil : port.command
        case .other: nil
        }
    }

    private var details: String {
        var parts = [port.command, "pid \(port.pid)"]
        if port.kind == .web, let directory = port.shortDirectory {
            parts.append(directory)
        } else if port.isLocalOnly {
            parts.append("localhost only")
        }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        HStack(spacing: 14) {
            HStack(spacing: 8) {
                Circle()
                    .fill(dotColor)
                    .frame(width: 7, height: 7)
                    .shadow(color: port.kind == .other ? .clear : dotColor, radius: 4)
                Text(String(port.port))
                    .font(.system(size: 16, weight: .medium).monospacedDigit())
                    .foregroundStyle(Color.white.opacity(port.kind == .other ? 0.8 : 1))
            }
            .frame(width: 74, alignment: .leading)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(title)
                        .font(.system(size: 12.5, weight: .semibold))
                        .lineLimit(1)
                    if let tag {
                        Text(tag)
                            .font(.system(size: 9.5, weight: .medium))
                            .foregroundStyle(Color.white.opacity(0.6))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .background(RoundedRectangle(cornerRadius: 5).fill(Color.white.opacity(0.08)))
                    }
                }
                Text(details)
                    .font(.system(size: 10.5))
                    .foregroundStyle(Color.white.opacity(0.45))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .help(port.directory ?? port.command)

            Spacer(minLength: 8)

            HStack(spacing: 6) {
                if port.kind == .web {
                    RowButton(title: "Open", systemImage: "arrow.up.right.square",
                              foreground: Color(red: 0.75, green: 0.86, blue: 1), background: Color.blue.opacity(0.22)) {
                        PortsService.shared.open(port)
                    }
                    .help("Open \(port.url.absoluteString)")
                }
                RowIconButton(systemImage: copied ? "checkmark" : "doc.on.doc", help: "Copy \(port.url.absoluteString)") {
                    PortsService.shared.copyURL(port)
                    copied = true
                }
                RowButton(
                    title: isConfirmingStop ? "Stop server?" : "Stop",
                    systemImage: "stop.fill",
                    foreground: isConfirmingStop ? .white : Color(red: 0.99, green: 0.65, blue: 0.65),
                    background: isConfirmingStop ? Color.red : Color.white.opacity(0.07)
                ) {
                    if isConfirmingStop {
                        PortsService.shared.kill(port)
                    } else {
                        isConfirmingStop = true
                    }
                }
                .help("Quit \(port.command) (pid \(port.pid))")
            }
            .animation(.easeOut(duration: 0.15), value: isConfirmingStop)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.white.opacity(isHovering ? 0.07 : 0))
        )
        .overlay(alignment: .top) {
            if showsDivider && !isHovering {
                Rectangle()
                    .fill(Color.white.opacity(0.06))
                    .frame(height: 1)
                    .padding(.horizontal, 10)
            }
        }
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .task(id: isConfirmingStop) {
            guard isConfirmingStop else { return }
            try? await Task.sleep(for: .seconds(3))
            isConfirmingStop = false
        }
        .task(id: copied) {
            guard copied else { return }
            try? await Task.sleep(for: .seconds(1.2))
            copied = false
        }
    }
}

/// Small labelled pill button used in the Dev rows.
struct RowButton: View {
    let title: String
    let systemImage: String
    let foreground: Color
    let background: Color
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: systemImage)
                    .font(.system(size: 10, weight: .semibold))
                Text(title)
                    .font(.system(size: 11, weight: .semibold))
            }
            .foregroundStyle(foreground)
            .padding(.horizontal, 9)
            .frame(height: 26)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(background)
                    .brightness(isHovering ? 0.08 : 0)
            )
            .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
    }
}

/// Square icon-only button matching `RowButton`.
struct RowIconButton: View {
    let systemImage: String
    let help: String
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color.white.opacity(0.75))
                .frame(width: 26, height: 26)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.white.opacity(isHovering ? 0.14 : 0.07))
                )
                .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .help(help)
    }
}

/// Compact segmented control styled for the black notch.
struct SegmentedToggle: View {
    let options: [String]
    @Binding var selection: Int

    var body: some View {
        HStack(spacing: 0) {
            ForEach(options.indices, id: \.self) { index in
                Button {
                    selection = index
                } label: {
                    Text(options[index])
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(Color.white.opacity(selection == index ? 1 : 0.6))
                        .padding(.horizontal, 9)
                        .padding(.vertical, 3)
                        .background(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(Color.white.opacity(selection == index ? 0.18 : 0))
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.white.opacity(0.08)))
    }
}

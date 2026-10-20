import SwiftUI

/// Dev tab: local servers listening on TCP ports, with Open and Kill buttons.
struct DevView: View {
    @ObservedObject private var service = PortsService.shared
    @AppStorage(AppSettings.devShowAllPortsKey) private var showAll = false

    private var ports: [ListeningPort] { service.visiblePorts(showAll: showAll) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Text("Local servers")
                    .font(.system(size: 13, weight: .semibold))
                Text("\(ports.count)")
                    .font(.system(size: 11, weight: .medium).monospacedDigit())
                    .foregroundStyle(Color.white.opacity(0.5))
                Spacer()
                Toggle("Show all ports", isOn: $showAll)
                    .toggleStyle(.checkbox)
                    .controlSize(.small)
                    .font(.system(size: 11))
                Button {
                    Task { await service.refresh() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Color.white.opacity(0.7))
                }
                .buttonStyle(.plain)
                .help("Refresh")
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
                    VStack(spacing: 4) {
                        ForEach(ports) { port in
                            PortRow(port: port)
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
    @State private var isHovering = false
    /// Kill takes two clicks, so a list that shifts while refreshing can't cause a wrong kill.
    @State private var isConfirmingKill = false

    var body: some View {
        HStack(spacing: 10) {
            // String(_:) avoids the locale grouping Text applies to integers (":8,080").
            Text(":" + String(port.port))
                .font(.system(size: 13, weight: .bold, design: .monospaced))
                .foregroundStyle(Color.green)
                .frame(width: 64, alignment: .leading)

            VStack(alignment: .leading, spacing: 1) {
                Text(port.projectName ?? port.command)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                Text("\(port.command) · pid \(port.pid)" + (port.address == "*" ? "" : " · \(port.address)"))
                    .font(.system(size: 10))
                    .foregroundStyle(Color.white.opacity(0.5))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .help(port.directory ?? port.command)

            Spacer(minLength: 8)

            Button {
                PortsService.shared.open(port)
            } label: {
                Label("Open", systemImage: "arrow.up.right.square")
                    .font(.system(size: 10, weight: .semibold))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(Color.blue))
            }
            .buttonStyle(.plain)
            .help("Open \(port.url.absoluteString)")

            Button {
                if isConfirmingKill {
                    PortsService.shared.kill(port)
                } else {
                    isConfirmingKill = true
                }
            } label: {
                Label(isConfirmingKill ? "Confirm" : "Kill", systemImage: "xmark.octagon.fill")
                    .font(.system(size: 10, weight: .semibold))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(Color.red.opacity(isConfirmingKill ? 1 : 0.6)))
            }
            .buttonStyle(.plain)
            .help("Quit \(port.command) (pid \(port.pid))")
            .task(id: isConfirmingKill) {
                guard isConfirmingKill else { return }
                try? await Task.sleep(for: .seconds(3))
                isConfirmingKill = false
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.white.opacity(isHovering ? 0.08 : 0.03))
        )
        .onHover { isHovering = $0 }
    }
}

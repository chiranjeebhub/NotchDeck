import AppKit
import UniformTypeIdentifiers

struct TrayItem: Identifiable, Codable, Equatable {
    var id = UUID()
    var url: URL
}

/// Files dropped on the notch. Items are references to the original files and persist across launches.
@MainActor
final class TrayStore: ObservableObject {
    static let shared = TrayStore()

    @Published private(set) var items: [TrayItem] = [] {
        didSet { save() }
    }

    private let defaultsKey = "trayItems"

    private init() {
        if let data = UserDefaults.standard.data(forKey: defaultsKey),
           let saved = try? JSONDecoder().decode([TrayItem].self, from: data) {
            items = saved.filter { FileManager.default.fileExists(atPath: $0.url.path) }
        }
    }

    var urls: [URL] { items.map(\.url) }

    func add(_ urls: [URL]) {
        let existing = Set(items.map(\.url))
        items.append(contentsOf: urls.filter { !existing.contains($0) }.map { TrayItem(url: $0) })
    }

    func remove(_ item: TrayItem) {
        items.removeAll { $0.id == item.id }
    }

    func removeAll() {
        items.removeAll()
    }

    /// Loads file URLs from a SwiftUI drop. Returns whether any provider carried a file.
    static func fileURLs(from providers: [NSItemProvider], completion: @escaping @MainActor ([URL]) -> Void) -> Bool {
        let fileProviders = providers.filter { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }
        for provider in fileProviders {
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url else { return }
                Task { @MainActor in completion([url]) }
            }
        }
        return !fileProviders.isEmpty
    }

    func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        Self.fileURLs(from: providers) { [weak self] urls in self?.add(urls) }
    }

    // MARK: - Actions

    static func airDrop(_ urls: [URL]) {
        guard !urls.isEmpty, let service = NSSharingService(named: .sendViaAirDrop) else { return }
        if service.canPerform(withItems: urls) {
            service.perform(withItems: urls)
        }
    }

    static func open(_ url: URL) {
        NSWorkspace.shared.open(url)
    }

    static func revealInFinder(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    private func save() {
        if let data = try? JSONEncoder().encode(items) {
            UserDefaults.standard.set(data, forKey: defaultsKey)
        }
    }
}

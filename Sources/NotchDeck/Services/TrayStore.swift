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

    /// Where dropped files are copied when "Copy dropped files" is on.
    nonisolated static let copiesDirectory: URL = {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support.appendingPathComponent("NotchDeck/Tray", isDirectory: true)
    }()

    func add(_ urls: [URL]) {
        guard AppSettings.trayCopyFiles else {
            append(urls)
            return
        }
        Task { [weak self] in
            let copies = await Task.detached(priority: .userInitiated) { urls.compactMap { TrayStore.makeCopy(of: $0) } }.value
            self?.append(copies)
        }
    }

    private func append(_ urls: [URL]) {
        let existing = Set(items.map(\.url))
        items.append(contentsOf: urls.filter { !existing.contains($0) }.map { TrayItem(url: $0) })
    }

    /// Copies the file into its own folder (so names never clash), keeping its name.
    nonisolated private static func makeCopy(of url: URL) -> URL? {
        let folder = copiesDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let destination = folder.appendingPathComponent(url.lastPathComponent)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: url, to: destination)
            return destination
        } catch {
            NSLog("NotchDeck: couldn't copy \(url.path) into the tray: \(error)")
            return url
        }
    }

    func remove(_ item: TrayItem) {
        items.removeAll { $0.id == item.id }
        deleteCopy(of: item.url)
    }

    func removeAll() {
        let urls = items.map(\.url)
        items.removeAll()
        urls.forEach(deleteCopy)
    }

    /// Copies made by the tray are deleted when they leave it; originals never are.
    private func deleteCopy(of url: URL) {
        let folder = url.deletingLastPathComponent()
        guard folder.deletingLastPathComponent().standardizedFileURL == Self.copiesDirectory.standardizedFileURL else { return }
        try? FileManager.default.removeItem(at: folder)
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

import Foundation

/// Runs the bundled MediaRemote helper under /usr/bin/perl and relays its JSON updates.
///
/// See `Adapter/MediaRemoteAdapter.m` for why the helper runs inside perl.
@MainActor
final class MediaRemoteAdapter {
    /// Called on the main actor with each decoded update from the helper.
    var onUpdate: (([String: Any]) -> Void)?
    /// Called when the helper exits and will not be restarted.
    var onUnavailable: (() -> Void)?

    private var process: Process?
    private var input: FileHandle?
    private var buffer = Data()
    private var restarts = 0
    private var startedAt = Date()

    private static let maxQuickRestarts = 3

    /// Starts the helper. Returns false when it isn't bundled (e.g. when run with `swift run`).
    @discardableResult
    func start() -> Bool {
        guard let resources = Bundle.main.resourceURL else { return false }
        let script = resources.appendingPathComponent("MediaRemoteAdapter.pl")
        let library = resources.appendingPathComponent("MediaRemoteAdapter.dylib")
        guard FileManager.default.fileExists(atPath: script.path),
              FileManager.default.fileExists(atPath: library.path) else { return false }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        process.arguments = [script.path, library.path]
        let output = Pipe()
        let input = Pipe()
        process.standardOutput = output
        process.standardInput = input
        process.standardError = FileHandle.nullDevice

        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil }
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.consume(data) }
            }
        }
        process.terminationHandler = { [weak self] _ in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.handleExit() }
            }
        }

        do {
            try process.run()
        } catch {
            NSLog("NotchUtility: could not start MediaRemote adapter: \(error)")
            return false
        }
        self.process = process
        self.input = input.fileHandleForWriting
        buffer.removeAll()
        startedAt = .now
        return true
    }

    func stop() {
        process?.terminationHandler = nil
        process?.terminate()
        process = nil
        input = nil
    }

    /// Sends a command line such as "toggle", "next", "previous" or "seek 42.5".
    func send(_ command: String) {
        guard let input, process?.isRunning == true, let data = (command + "\n").data(using: .utf8) else { return }
        try? input.write(contentsOf: data)
    }

    private func consume(_ data: Data) {
        buffer.append(data)
        while let newline = buffer.firstIndex(of: UInt8(ascii: "\n")) {
            let line = buffer[buffer.startIndex..<newline]
            buffer.removeSubrange(buffer.startIndex...newline)
            if let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any] {
                onUpdate?(object)
            }
        }
    }

    private func handleExit() {
        process = nil
        input = nil
        // Restart after crashes, but give up if the helper keeps dying straight away
        // (for example if a future macOS blocks this approach).
        if Date.now.timeIntervalSince(startedAt) > 30 { restarts = 0 }
        restarts += 1
        if restarts <= Self.maxQuickRestarts, start() { return }
        onUnavailable?()
    }
}

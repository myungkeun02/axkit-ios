import AxKitCore
import Foundation

/// The chat history file(s), written one at a time and off the main thread. Each save carries the file key it was
/// asked for; `forget` drops saves still queued for that key (unpair, switching Macs) so an old save never
/// writes a file back after it was deleted.
actor TimelineStore {
    private let dir: URL
    private var generation = 0

    init(dir: URL) { self.dir = dir }

    nonisolated func url(_ key: String) -> URL { dir.appendingPathComponent("timeline-\(key).json") }

    /// The generation a save must carry; bumped by `forget`.
    func current() -> Int { generation }

    func save(_ snapshot: Timeline.Snapshot, key: String, generation: Int) {
        guard generation == self.generation, let data = try? JSONEncoder().encode(snapshot) else { return }
        try? data.write(to: url(key), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    func load(key: String) -> Timeline.Snapshot? {
        guard let data = try? Data(contentsOf: url(key)) else { return nil }
        return try? JSONDecoder().decode(Timeline.Snapshot.self, from: data)
    }

    /// Cancels queued saves and removes the files: one Mac's (`key`) or every Mac's (nil).
    func forget(key: String?) {
        generation += 1
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        for name in names where name.hasPrefix("timeline-") && name.hasSuffix(".json") {
            if let key, name != "timeline-\(key).json" { continue }
            try? FileManager.default.removeItem(at: dir.appendingPathComponent(name))
        }
    }

    /// Switching Macs: cancel queued saves of the old one but keep its file.
    func cancelPending() { generation += 1 }

    /// Stable file key: the Mac's own id when it gives one, else its address.
    nonisolated static func key(_ text: String) -> String {
        let hash = text.utf8.reduce(UInt64(14695981039346656037)) { ($0 ^ UInt64($1)) &* 1099511628211 }
        return String(hash, radix: 16)
    }
}

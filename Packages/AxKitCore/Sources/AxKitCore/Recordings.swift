import Foundation

/// A recording on this phone that has not fully reached the Mac yet (PROTOCOL-REQUESTS.md R14).
public struct PendingRecording: Codable, Identifiable, Hashable, Sendable {
    public var id: String
    /// File name inside the recordings folder (never a full path, the app folder moves between installs).
    public var fileName: String
    public var startedAt: Date
    public var durationSec: Double
    public var size: Int
    /// Chunks the Mac confirmed, in order; upload resumes from here.
    public var sentChunks: Int

    public init(id: String = "r_" + UUID().uuidString.prefix(12).lowercased(), fileName: String, startedAt: Date, durationSec: Double, size: Int, sentChunks: Int = 0) {
        self.id = id; self.fileName = fileName; self.startedAt = startedAt; self.durationSec = durationSec; self.size = size; self.sentChunks = sentChunks
    }

    public var totalChunks: Int { RecordingChunks.count(size: size) }
    public var progress: Double { totalChunks == 0 ? 1 : Double(sentChunks) / Double(totalChunks) }
}

public enum RecordingChunks {
    /// 4 MB stays well under the Mac's 12 MB upload limit and is quick to retry on a bad connection.
    public static let size = 4 * 1024 * 1024

    public static func count(size total: Int, chunk: Int = size) -> Int { max(1, (total + chunk - 1) / chunk) }

    public static func range(_ index: Int, size total: Int, chunk: Int = size) -> Range<Int> {
        let start = index * chunk
        return start..<min(total, start + chunk)
    }
}

public struct ChunkResult: Decodable, Sendable {
    public var received: Int
    public var complete: Bool
}

extension APIClient {
    /// `POST recordings/<id>/chunks/<index>`: raw audio bytes. Re-sending a chunk the Mac already has is harmless.
    public func uploadRecordingChunk(_ recording: PendingRecording, index: Int, bytes: Data) async throws -> ChunkResult {
        var request = request("recordings/\(recording.id)/chunks/\(index)", method: "POST")
        request.setValue("audio/mp4", forHTTPHeaderField: "Content-Type")
        request.setValue(String(recording.totalChunks), forHTTPHeaderField: "X-Chunk-Total")
        request.setValue(ISO8601DateFormatter().string(from: recording.startedAt), forHTTPHeaderField: "X-Started-At")
        request.setValue(String(Int(recording.durationSec.rounded())), forHTTPHeaderField: "X-Duration-Sec")
        request.httpBody = bytes
        request.timeoutInterval = 120
        let data = try await send(request)
        do { return try JSONDecoder().decode(ChunkResult.self, from: data) } catch { throw APIError.decoding }
    }
}

/// Recordings waiting to reach the Mac. The list is kept on disk; the audio files sit next to it until the Mac has
/// every chunk, then they are deleted from the phone.
public actor RecordingQueue {
    public let folder: URL
    private var items: [PendingRecording] = []
    private var listURL: URL { folder.appendingPathComponent("queue.json") }

    public init(folder: URL) {
        self.folder = folder
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        if let data = try? Data(contentsOf: folder.appendingPathComponent("queue.json")),
           let saved = try? JSONDecoder().decode([PendingRecording].self, from: data) {
            items = saved
        }
    }

    public var pending: [PendingRecording] { items }

    public func fileURL(_ recording: PendingRecording) -> URL { folder.appendingPathComponent(recording.fileName) }

    public func add(_ recording: PendingRecording) {
        items.append(recording)
        persist()
    }

    /// Sends what is left, oldest first. Stops at the first network problem and keeps its place.
    public func upload(using send: @Sendable (PendingRecording, Int, Data) async throws -> ChunkResult) async -> [String] {
        var finished: [String] = []
        while let recording = items.first {
            guard let data = try? Data(contentsOf: fileURL(recording), options: .mappedIfSafe) else {
                // The file is gone (cleared storage): nothing left to send.
                items.removeAll { $0.id == recording.id }; persist(); continue
            }
            var current = recording
            current.size = data.count
            do {
                while current.sentChunks < current.totalChunks {
                    let range = RecordingChunks.range(current.sentChunks, size: data.count)
                    let result = try await send(current, current.sentChunks, data.subdata(in: range))
                    current.sentChunks = max(current.sentChunks + 1, min(result.received, current.totalChunks))
                    guard let i = items.firstIndex(where: { $0.id == current.id }) else { return finished }
                    items[i] = current
                    persist()
                    if result.complete { break }
                }
                try? FileManager.default.removeItem(at: fileURL(current))
                items.removeAll { $0.id == current.id }
                persist()
                finished.append(current.id)
            } catch let error as APIError where !error.isTransient {
                // The Mac refused it for good (too big, not supported): don't loop on it forever.
                items.removeAll { $0.id == current.id }
                persist()
            } catch {
                break
            }
        }
        return finished
    }

    /// Pairing with another Mac: these were for the old one. Removed by id, so an upload in flight stops cleanly.
    public func clear() {
        for recording in items { try? FileManager.default.removeItem(at: fileURL(recording)) }
        items = []
        persist()
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(items) { try? data.write(to: listURL, options: .atomic) }
    }
}

// MARK: views/recordings (R14)

public struct RecordingsView: Decodable, Sendable {
    public struct Item: Decodable, Hashable, Sendable, Identifiable {
        public var id: String
        public var title: String?
        public var startedAt: Date?
        public var durationSec: Double?
        /// `receiving` · `transcribing` · `summarizing` · `done` · `failed`
        public var status: String
        public var statusText: String?
        public var documentId: String?
        public var driveUrl: String?
    }
    public var recordings: [Item]
}

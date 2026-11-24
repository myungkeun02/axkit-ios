import Foundation

public struct SSEMessage: Equatable, Sendable {
    public var event: String
    public var id: String?
    public var data: String
}

/// Server-sent events, line by line: `event`, `id`, `data`, `: comment`.
public struct SSEParser: Sendable {
    private var event = ""
    private var id: String?
    private var data: [String] = []

    public init() {}

    /// One line without its newline; returns a message when a blank line ends one.
    public mutating func feed(_ rawLine: String) -> SSEMessage? {
        let line = rawLine.hasSuffix("\r") ? String(rawLine.dropLast()) : rawLine
        if line.isEmpty {
            defer { event = ""; id = nil; data = [] }
            guard !data.isEmpty else { return nil }
            return SSEMessage(event: event.isEmpty ? "message" : event, id: id, data: data.joined(separator: "\n"))
        }
        if line.hasPrefix(":") { return nil }
        let field: Substring
        var value: Substring
        if let colon = line.firstIndex(of: ":") {
            field = line[..<colon]
            value = line[line.index(after: colon)...]
            if value.hasPrefix(" ") { value = value.dropFirst() }
        } else {
            field = Substring(line)
            value = ""
        }
        switch field {
        case "event": event = String(value)
        case "id": id = String(value)
        case "data": data.append(String(value))
        default: break
        }
        return nil
    }
}

/// Splits bytes into lines and keeps blank ones (SSE needs them; `AsyncBytes.lines` drops them).
public struct LineSplitter: Sendable {
    private var buffer = Data()
    public init() {}

    public mutating func feed(_ byte: UInt8) -> String? {
        if byte == 0x0A {
            defer { buffer.removeAll(keepingCapacity: true) }
            return String(decoding: buffer, as: UTF8.self)
        }
        buffer.append(byte)
        return nil
    }
}

/// Reconnect delays: 2 s doubling up to 60 s; back to 2 s after a connection that delivered something.
public struct Backoff: Sendable {
    public private(set) var next: TimeInterval = 2
    public init() {}
    public mutating func fail() -> TimeInterval {
        defer { next = min(next * 2, 60) }
        return next
    }
    public mutating func reset() { next = 2 }
}

public enum StreamState: Equatable, Sendable {
    case connecting
    case live
    case waiting(retryIn: TimeInterval)
    /// The token no longer works; pair again.
    case unauthorized
}

/// One SSE connection to `GET stream` while the app is in front; replays from the last seq after a drop.
public final class EventStreamClient: @unchecked Sendable {
    private let client: APIClient
    private var task: Task<Void, Never>?

    public init(client: APIClient) { self.client = client }

    deinit { task?.cancel() }

    public func start(lastSeq: @escaping @Sendable () async -> Int,
                      onState: @escaping @Sendable (StreamState) async -> Void,
                      onEvent: @escaping @Sendable (AppEvent) async -> Void,
                      onActivity: @escaping @Sendable (ActivityEvent) async -> Void = { _ in }) {
        task?.cancel()
        let client = client
        task = Task {
            var backoff = Backoff()
            while !Task.isCancelled {
                await onState(.connecting)
                var delivered = false
                do {
                    let (bytes, response) = try await client.session.bytes(for: client.streamRequest(lastSeq: await lastSeq()))
                    let http = response as? HTTPURLResponse
                    let status = http?.statusCode ?? 0
                    if status == 401, APIClient.isOwnJSON(http) {
                        await onState(.unauthorized)
                        return
                    }
                    guard status == 200 else { throw APIError.server(status: status, error: nil) }
                    // Connected: the next drop starts again from 2 s, even on a quiet line that delivered nothing.
                    backoff.reset()
                    await onState(.live)
                    var splitter = LineSplitter()
                    var parser = SSEParser()
                    for try await byte in bytes {
                        guard let line = splitter.feed(byte), let message = parser.feed(line) else { continue }
                        let data = Data(message.data.utf8)
                        // `activity` has no seq: it never touches the timeline or the replay cursor.
                        if let activity = ActivityEvent.from(data) {
                            await onActivity(activity)
                        } else if let event = EventDecoding.event(from: data) {
                            delivered = true
                            await onEvent(event)
                        }
                    }
                } catch {
                    if Task.isCancelled { return }
                }
                if delivered { backoff.reset() }
                let wait = backoff.fail()
                await onState(.waiting(retryIn: wait))
                try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
            }
        }
    }

    public func stop() {
        task?.cancel()
        task = nil
    }
}

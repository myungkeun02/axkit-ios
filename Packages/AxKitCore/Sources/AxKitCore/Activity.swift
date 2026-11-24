import Foundation

// §4 `activity` (feature `activity`): the assistant is working on what the owner said. Outside the log — no seq, never
// replayed — so it only ever arrives on the live stream and is kept apart from the timeline.

public struct ActivityEvent: Decodable, Equatable, Sendable {
    public enum State: String, Decodable, Sendable { case thinking, working, idle }
    public var channel: String?
    public var state: State
    /// Plain words for the step ("메일 보는 중"), only with `working`.
    public var step: String?
    public var at: Date?

    public init(channel: String? = nil, state: State, step: String? = nil, at: Date? = nil) {
        self.channel = channel; self.state = state; self.step = step; self.at = at
    }

    private struct Head: Decodable { var type: String }

    /// One stream message → an activity (nil for anything else, including a shape this app does not know).
    public static func from(_ data: Data) -> ActivityEvent? {
        guard let head = try? EventDecoding.decoder.decode(Head.self, from: data), head.type == "activity" else { return nil }
        return try? EventDecoding.decoder.decode(ActivityEvent.self, from: data)
    }
}

/// Which rooms the assistant is busy in right now. "" is the main chat.
public struct ActivityBoard: Equatable, Sendable {
    public struct Busy: Equatable, Sendable {
        public var state: ActivityEvent.State
        public var step: String?
        public var seen: Date
        /// The server's time on the newest activity word for this room.
        public var at: Date? = nil

        /// "생각하는 중" or the step ("메일 보는 중"), without the trailing dots.
        public var words: String {
            if state == .working, let step = step?.trimmingCharacters(in: .whitespacesAndNewlines), !step.isEmpty {
                return step.hasSuffix("…") ? String(step.dropLast()) : step
            }
            return "생각하는 중"
        }
    }

    /// No word for this long and the server has forgotten it too.
    public static let forgetAfter: TimeInterval = 180

    public private(set) var rooms: [String: Busy] = [:]

    public init() {}

    public subscript(room: String) -> Busy? { rooms[room] }

    public mutating func apply(_ event: ActivityEvent, now: Date = Date()) {
        let room = event.channel ?? ""
        if event.state == .idle { rooms[room] = nil } else { rooms[room] = Busy(state: event.state, step: event.step, seen: now, at: event.at) }
    }

    /// The assistant answered in this room: the dots go — unless the answer is older than the activity word (a reconnect
    /// replays earlier messages right after the server's fresh "still thinking").
    public mutating func answered(in room: String, at messageAt: Date? = nil) {
        if let busyAt = rooms[room]?.at, let messageAt, messageAt < busyAt { return }
        rooms[room] = nil
    }

    public mutating func forgetStale(now: Date = Date()) {
        rooms = rooms.filter { now.timeIntervalSince($0.value.seen) < Self.forgetAfter }
    }

    public mutating func clear() { rooms = [:] }
}

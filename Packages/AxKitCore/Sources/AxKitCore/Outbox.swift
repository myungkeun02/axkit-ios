import Foundation

/// A chat message waiting to reach the Mac. `id` is also the protocol `clientId`, so a retry is stored once.
/// A message is never thrown away by the app: when it can't go, it stays with `failed` set until the owner
/// sends it again or deletes it.
public struct PendingMessage: Codable, Identifiable, Hashable, Sendable {
    public var id: String
    public var text: String
    public var channel: String
    public var createdAt: Date
    public var attempts: Int
    /// Why it won't go by itself (the Mac said no, or a one-time code went stale). nil = still trying.
    public var failed: String?
    /// A 선택지 button's id (sent as `choice`), not typed text.
    public var choice: String?
    /// The line whose 선택지 was tapped (kept so the buttons stay marked after a restart).
    public var choiceSeq: Int?

    public init(id: String = UUID().uuidString, text: String, channel: String, createdAt: Date = Date(), attempts: Int = 0,
                failed: String? = nil, choice: String? = nil, choiceSeq: Int? = nil) {
        self.id = id; self.text = text; self.channel = channel; self.createdAt = createdAt; self.attempts = attempts
        self.failed = failed; self.choice = choice; self.choiceSeq = choiceSeq
    }

    /// After this many tries in a row the chat says "보내지 못했어요 · 다시 보내기" (the app still keeps trying).
    public static let showFailedAfter = 3
    public var showsFailed: Bool { failed != nil || attempts >= Self.showFailedAfter }
}

public struct FlushResult: Equatable, Sendable {
    public var sent: [String] = []
    /// Stopped trying by itself: the Mac refused it, or it was a one-time code that went stale. Still in the queue.
    public var failed: [String] = []
    /// The Mac said this phone is no longer paired: nothing was sent, everything is kept.
    public var unauthorized = false
    /// Messages still waiting that the app will try again by itself (not `failed`).
    public var retrying = 0
    public var remaining = 0
}

/// Messages typed while offline, kept on disk (not secret; no tokens) and sent in order once the Mac is back.
public actor Outbox {
    private var queue: [PendingMessage] = []
    private let fileURL: URL?
    private let now: @Sendable () -> Date

    /// One-time codes go stale; don't deliver them late (docs/APP-PROTOCOL.md §6).
    public static let codeLifetime: TimeInterval = 10 * 60

    public init(fileURL: URL?, now: @escaping @Sendable () -> Date = { Date() }) {
        self.fileURL = fileURL
        self.now = now
        if let fileURL, let data = try? Data(contentsOf: fileURL),
           let saved = try? JSONDecoder().decode([PendingMessage].self, from: data) {
            queue = saved
        }
    }

    public var pending: [PendingMessage] { queue }

    @discardableResult
    public func enqueue(text: String, channel: String, choice: String? = nil, choiceSeq: Int? = nil) -> PendingMessage {
        let message = PendingMessage(text: text, channel: channel, createdAt: now(), choice: choice, choiceSeq: choiceSeq)
        queue.append(message)
        persist()
        return message
    }

    public func remove(_ id: String) {
        queue.removeAll { $0.id == id }
        persist()
    }

    /// The owner tapped 다시 보내기: try it again from scratch (a stale code too — they chose to).
    public func retry(_ id: String) {
        guard let i = queue.firstIndex(where: { $0.id == id }) else { return }
        queue[i].failed = nil
        queue[i].attempts = 0
        queue[i].createdAt = now()
        persist()
    }

    public func clear() {
        queue = []
        persist()
    }

    /// True while a flush is sending. The actor gives up its lock at each `await`, so without this two flushes
    /// (two quick sends) ran together, sent the same message twice and both removed "the first" one — the
    /// second removal hit an empty queue and crashed the app.
    private var flushing = false

    /// Sends oldest first, skipping ones marked failed. A transient failure stops the run (order matters); the Mac's
    /// own "no" marks that message failed and goes on. Only one flush runs at a time: a call made while one is running
    /// returns at once, and the running one keeps going until the queue is done, so messages added meanwhile go too.
    public func flush(using send: @Sendable (PendingMessage) async throws -> Void) async -> FlushResult {
        var result = FlushResult()
        guard !flushing else { return summary(result) }
        flushing = true
        defer { flushing = false }
        var tried = Set<String>()
        while let message = queue.first(where: { $0.failed == nil && !tried.contains($0.id) }) {
            tried.insert(message.id)
            if message.choice == nil, Self.looksLikeCode(message.text), now().timeIntervalSince(message.createdAt) > Self.codeLifetime {
                mark(message.id, failed: "인증번호는 시간이 지나 보내지 않았어요")
                result.failed.append(message.id)
                continue
            }
            do {
                try await send(message)
                drop(message.id)
                result.sent.append(message.id)
            } catch let error as APIError where error.isFinalRefusal {
                mark(message.id, failed: error.friendlyMessage)
                result.failed.append(message.id)
            } catch APIError.unauthorized {
                result.unauthorized = true
                break
            } catch {
                if let i = queue.firstIndex(where: { $0.id == message.id }) { queue[i].attempts += 1 }
                break
            }
        }
        persist()
        return summary(result)
    }

    private func summary(_ result: FlushResult) -> FlushResult {
        var result = result
        result.remaining = queue.count
        result.retrying = queue.filter { $0.failed == nil }.count
        return result
    }

    private func mark(_ id: String, failed: String) {
        guard let i = queue.firstIndex(where: { $0.id == id }) else { return }
        queue[i].failed = failed
    }

    /// By id, never "the first": the queue may have changed while a send was awaited (remove, clear).
    private func drop(_ id: String) {
        queue.removeAll { $0.id == id }
    }

    /// "인증번호 482913", "code: 1234" …
    public static func looksLikeCode(_ text: String) -> Bool {
        let lower = text.lowercased()
        let hasWord = ["인증", "otp", "code", "코드", "verification"].contains { lower.contains($0) }
        let hasDigits = text.range(of: #"(?<![0-9])[0-9]{4,8}(?![0-9])"#, options: .regularExpression) != nil
        return hasWord && hasDigits
    }

    private func persist() {
        guard let fileURL else { return }
        if queue.isEmpty {
            try? FileManager.default.removeItem(at: fileURL)
            return
        }
        if let data = try? JSONEncoder().encode(queue) {
            try? data.write(to: fileURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        }
    }
}

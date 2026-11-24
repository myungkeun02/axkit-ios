import CoreGraphics
import Foundation

// §22 브라우저 화면 넘겨받기: when a browser errand stops at a login, captcha, consent or final button, the owner sees
// that page on the phone, taps and types to finish it, then says "다 했어요" so the assistant carries on.

/// `GET views/browser-live` and the stream's `state` event.
public struct BrowserLiveState: Decodable, Equatable, Sendable {
    public struct Pending: Decodable, Equatable, Sendable {
        public var url: String?
        public var reason: String?
        public var at: Date?
    }

    public var live: Bool
    public var url: String?
    public var title: String?
    /// `login` · `payment` · `consent` · `captcha` · `other`
    public var reason: String?
    public var startedAt: Date?
    public var idleClosesAt: Date?
    public var pending: Pending?
    /// Why the last page closed: `done` · `idle` · `stopped` · `error` · `shutdown`.
    public var closed: String?
    /// Only in the answer to `done`.
    public var resumed: Bool?
    /// Only in the answer to `done`: `app` (carry on in the app's chat or `channel`) or `elsewhere` (Discord and the like).
    public var continuedIn: String?
    /// Only in the answer to `done`: the bot or team room the errand came from.
    public var channel: String?

    public init(live: Bool, url: String? = nil, title: String? = nil, reason: String? = nil, pending: Pending? = nil, closed: String? = nil) {
        self.live = live; self.url = url; self.title = title; self.reason = reason; self.pending = pending; self.closed = closed
    }

    /// The site's name for the owner: "shop.example.com".
    public var host: String? { (url ?? pending?.url).flatMap { URL(string: $0)?.host } }

    /// Why the assistant handed the page over, in plain words.
    public var reasonWords: String {
        switch reason ?? pending?.reason {
        case "login": "로그인이 필요해요"
        case "payment": "마지막 결제 버튼은 직접 눌러 주세요"
        case "consent": "약관 동의가 필요해요"
        case "captcha": "사람인지 확인하는 단계예요"
        default: "직접 해 주셔야 하는 단계예요"
        }
    }

    /// Why the page closed, in plain words (nil when it is still open or closed because the owner finished).
    /// After `done`: the room to go back to (nil = stay put, the errand carries on outside the app).
    public var returnRoom: String? {
        if continuedIn == "elsewhere" { return nil }
        return channel ?? ""
    }

    /// After `done`, in plain words.
    public var doneWords: String {
        guard resumed == true else { return "브라우저 화면을 닫았어요." }
        return continuedIn == "elsewhere" ? "브라우저 화면에서 마친 일은 디스코드 대화에서 이어 갈게요." : "비서에게 이어서 하라고 했어요."
    }

    public var closedWords: String? {
        switch closed {
        case "idle": "한동안 아무것도 하지 않아서 브라우저 화면을 닫았어요."
        case "stopped": "비상 정지로 브라우저 화면을 닫았어요."
        case "shutdown": "맥의 비서가 다시 시작해서 브라우저 화면이 닫혔어요."
        case "error": "브라우저 화면에 문제가 생겨 닫혔어요."
        default: nil
        }
    }
}

/// One picture of the page (`event: frame`). `width`·`height` are the JPEG's pixels; taps are sent in these pixels.
public struct BrowserLiveFrame: Decodable, Equatable, Sendable {
    public var seq: Int
    public var url: String?
    public var title: String?
    public var width: Int
    public var height: Int
    public var jpeg: Data

    private enum CodingKeys: String, CodingKey { case seq, url, title, width, height, jpeg }

    public init(seq: Int, url: String?, title: String?, width: Int, height: Int, jpeg: Data) {
        self.seq = seq; self.url = url; self.title = title; self.width = width; self.height = height; self.jpeg = jpeg
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        seq = try c.decodeIfPresent(Int.self, forKey: .seq) ?? 0
        url = try c.decodeIfPresent(String.self, forKey: .url)
        title = try c.decodeIfPresent(String.self, forKey: .title)
        width = try c.decode(Int.self, forKey: .width)
        height = try c.decode(Int.self, forKey: .height)
        guard let bytes = Data(base64Encoded: try c.decode(String.self, forKey: .jpeg), options: .ignoreUnknownCharacters) else {
            throw DecodingError.dataCorruptedError(forKey: .jpeg, in: c, debugDescription: "base64")
        }
        jpeg = bytes
    }
}

public enum BrowserLiveUpdate: Equatable, Sendable {
    case state(BrowserLiveState)
    case frame(BrowserLiveFrame)

    /// One SSE message → an update (nil for anything else).
    public static func from(_ message: SSEMessage) -> BrowserLiveUpdate? {
        let data = Data(message.data.utf8)
        switch message.event {
        case "state": return (try? EventDecoding.decoder.decode(BrowserLiveState.self, from: data)).map { .state($0) }
        case "frame": return (try? EventDecoding.decoder.decode(BrowserLiveFrame.self, from: data)).map { .frame($0) }
        default: return nil
        }
    }
}

/// What the app can ask the page to do (`POST views/browser-live/<action>`).
public enum BrowserLiveAction: Equatable, Sendable {
    case tap(x: Int, y: Int)
    case type(String)
    case key(String)
    case scroll(dy: Int)
    case back

    public static let keys = ["Enter", "Backspace", "Tab", "Escape", "ArrowUp", "ArrowDown", "ArrowLeft", "ArrowRight"]

    public var name: String {
        switch self {
        case .tap: "tap"
        case .type: "type"
        case .key: "key"
        case .scroll: "scroll"
        case .back: "back"
        }
    }

    public var body: [String: Any] {
        switch self {
        case .tap(let x, let y): ["x": x, "y": y]
        case .type(let text): ["text": String(text.prefix(1000))]
        case .key(let name): ["name": name]
        case .scroll(let dy): ["dy": max(-4000, min(4000, dy))]
        case .back: [:]
        }
    }
}

public enum BrowserLiveGeometry {
    /// A point on the picture as drawn (`shown` size, aspect-fit inside it) → the JPEG pixel the server wants.
    /// nil when the point is outside the picture.
    public static func pixel(at point: CGPoint, shown: CGSize, image: CGSize) -> (x: Int, y: Int)? {
        guard image.width > 0, image.height > 0, shown.width > 0, shown.height > 0 else { return nil }
        let scale = min(shown.width / image.width, shown.height / image.height)
        let drawn = CGSize(width: image.width * scale, height: image.height * scale)
        let origin = CGPoint(x: (shown.width - drawn.width) / 2, y: (shown.height - drawn.height) / 2)
        let x = (point.x - origin.x) / scale, y = (point.y - origin.y) / scale
        guard x >= 0, y >= 0, x <= image.width, y <= image.height else { return nil }
        return (min(Int(x.rounded()), Int(image.width) - 1), min(Int(y.rounded()), Int(image.height) - 1))
    }
}

/// The chat line that says the page is waiting in the app (§22).
public enum BrowserLiveHint {
    /// The `live` field decides; the sentence is only looked for when there is none (older servers, team-lead replies).
    public static func offers(_ message: MessageEvent) -> Bool {
        guard message.role == .assistant else { return false }
        if let live = message.live { return live.view == "browser-live" }
        return mentions(message.text)
    }

    /// §28: a browser errand's result notice that stopped at a step the owner finishes in the app.
    public static func offers(_ notice: NoticeEvent) -> Bool {
        if let live = notice.live { return live.view == "browser-live" }
        // A server that does not send `live`/`kind` yet: the sentence decides, as for replies.
        return mentions(notice.text)
    }

    public static func mentions(_ text: String) -> Bool {
        // "앱의 브라우저 화면에서 직접 하실 수 있어요…" and "앱의 브라우저 화면에 준비해 뒀어요…" (the server's two wordings).
        text.contains("앱의 브라우저 화면") && !text.contains("직접 마쳤어요")
    }
}

public extension APIClient {
    func browserLive() async throws -> BrowserLiveState { try await view(BrowserLiveState.self, "browser-live") }

    /// `start` opens the page the assistant handed over (400 with words when there is none).
    func browserLiveStart() async throws -> BrowserLiveState {
        try await viewAction(BrowserLiveState.self, "browser-live", "start", json: [:])
    }

    /// `done`: the owner finished; the server closes the page and tells the assistant to carry on.
    func browserLiveDone() async throws -> BrowserLiveState {
        try await viewAction(BrowserLiveState.self, "browser-live", "done", json: [:])
    }

    struct BrowserLiveAccepted: Decodable, Sendable {
        public var accepted: Bool?
        public var retryAfterMs: Int?
    }

    @discardableResult
    func browserLive(_ action: BrowserLiveAction) async throws -> BrowserLiveAccepted {
        try await viewAction(BrowserLiveAccepted.self, "browser-live", action.name, json: action.body)
    }

    /// `GET browser-live/frame`: one JPEG (when the stream cannot be used). nil when no page is open (404).
    func browserLiveFrame() async throws -> Data? {
        do { return try await file("browser-live/frame") } catch APIError.notFound { return nil }
    }

    /// `GET browser-live/stream`: `state` and `frame` events until the task is cancelled or the connection drops.
    func browserLiveStream() -> AsyncThrowingStream<BrowserLiveUpdate, Error> {
        var request = request("browser-live/stream")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 90
        let session = session
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let (bytes, response) = try await session.bytes(for: request)
                    let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                    guard status == 200 else { throw APIError.server(status: status, error: nil) }
                    var splitter = LineSplitter()
                    var parser = SSEParser()
                    for try await byte in bytes {
                        guard let line = splitter.feed(byte), let message = parser.feed(line) else { continue }
                        if let update = BrowserLiveUpdate.from(message) { continuation.yield(update) }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

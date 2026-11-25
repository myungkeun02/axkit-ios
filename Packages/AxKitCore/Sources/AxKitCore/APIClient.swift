import Foundation

public enum APIError: Error, Equatable, Sendable {
    /// The Mac no longer knows this phone (401 JSON from the Mac itself).
    case unauthorized
    /// A card someone already answered (410 gone).
    case gone
    case rateLimited
    case wrongCode(attemptsLeft: Int?)
    case pairingExpired
    case notFound
    case badRequest(String?)
    /// The Mac said why in plain words (e.g. an API key it could not use).
    case refused(String)
    case server(status: Int, error: String?)
    case offline
    case decoding

    /// Very plain Korean for the screen.
    public var friendlyMessage: String {
        switch self {
        case .unauthorized: "맥과의 연결이 끊겼어요. 설정에서 다시 연결해 주세요."
        case .gone: "이미 처리된 카드예요."
        case .rateLimited: "잠깐 너무 많이 보냈어요. 조금 뒤에 다시 해 주세요."
        case .wrongCode(let left): left.map { "번호가 맞지 않아요. \($0)번 더 해 볼 수 있어요." } ?? "번호가 맞지 않아요."
        case .pairingExpired: "연결 QR이 만료됐어요. 맥에서 새 QR을 띄워 주세요."
        case .notFound: "맥에 아직 이 기능이 없어요."
        case .badRequest: "보낸 내용을 맥이 이해하지 못했어요."
        case .refused(let message): message
        case .server: "맥이 잠깐 대답을 못 해요. 조금 뒤에 다시 해 볼게요."
        case .offline: "맥에 닿지 않아요. 인터넷이나 Tailscale을 확인해 주세요."
        case .decoding: "맥이 보낸 내용을 읽지 못했어요."
        }
    }

    /// Worth retrying later (outbox keeps the message).
    public var isTransient: Bool {
        switch self {
        case .offline, .rateLimited, .server: true
        default: false
        }
    }

    /// The Mac itself answered "no" to this exact request: sending it again unchanged won't help. Anything else —
    /// unreachable, a proxy page, a body the app could not read, the token refused — may work later.
    public var isFinalRefusal: Bool {
        switch self {
        case .refused, .badRequest, .notFound, .gone: true
        default: false
        }
    }
}

/// How a card is answered (§4, §7.3).
public enum CardAnswer: Equatable, Sendable {
    case decision(String)
    case option(String)
    case text(String)
    case select(id: String, values: [String])
    case form(id: String, fields: [String: String])

    var body: [String: Any] {
        switch self {
        case .decision(let d): ["decision": d]
        case .option(let o): ["option": o]
        case .text(let t): ["text": t]
        case .select(let id, let values): ["select": ["id": id, "values": values]]
        case .form(let id, let fields): ["form": ["id": id, "fields": fields]]
        }
    }
}

public struct CardResult: Decodable, Sendable {
    public var state: String
    public var reply: String?
    /// R3: the chosen option's name or the words written, as the Mac recorded it.
    public var answer: String?
}
public struct SendResult: Decodable, Sendable { public var seq: Int; public var duplicate: Bool? }

public struct EventsPage: Sendable {
    public var events: [AppEvent]
    public var lastSeq: Int
    public var oldestSeq: Int
}

/// Talks to `{baseUrl}/m/v1/app/*` with the device token. Stateless apart from the credentials.
public final class APIClient: @unchecked Sendable {
    public let credentials: ServerCredentials
    let session: URLSession

    public init(credentials: ServerCredentials, session: URLSession = .shared) {
        self.credentials = credentials
        self.session = session
    }

    public var baseURL: URL { credentials.baseURL }

    // MARK: pairing

    private struct PairResponse: Decodable {
        var ok: Bool
        var deviceId: String?
        var deviceName: String?
        var baseUrl: String?
        var token: String?
        var error: String?
        var attemptsLeft: Int?
    }

    /// `POST {u}/m/p/<nonce>/app {code}` — no auth header.
    public static func pair(_ link: PairingLink, session: URLSession = .shared) async throws -> ServerCredentials {
        var request = URLRequest(url: link.baseURL.appendingPathComponent("m/p/\(link.nonce)/app"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let id = link.accessClientId, let secret = link.accessClientSecret {
            request.setValue(id, forHTTPHeaderField: "CF-Access-Client-Id")
            request.setValue(secret, forHTTPHeaderField: "CF-Access-Client-Secret")
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: ["code": link.code])
        request.timeoutInterval = 20
        let (data, response) = try await load(session, request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let body = try? JSONDecoder().decode(PairResponse.self, from: data)
        switch status {
        case 200:
            guard let body, body.ok, let token = body.token, let deviceId = body.deviceId else { throw APIError.decoding }
            // The Mac may name its own public address; only take it if it passes the same rule.
            var base = link.baseURL
            if let returned = body.baseUrl.flatMap(URL.init(string:)), AddressPolicy.isAllowed(returned) {
                base = AddressPolicy.normalized(returned)
            }
            return ServerCredentials(baseURL: base, token: token, deviceId: deviceId, deviceName: body.deviceName ?? "아이폰",
                                     accessClientId: link.accessClientId, accessClientSecret: link.accessClientSecret)
        case 403: throw APIError.wrongCode(attemptsLeft: body?.attemptsLeft)
        case 410: throw APIError.pairingExpired
        case 429: throw APIError.rateLimited
        default: throw APIError.server(status: status, error: body?.error)
        }
    }

    // MARK: requests

    func request(_ path: String, method: String = "GET", query: [String: String] = [:], json: Any? = nil) -> URLRequest {
        var components = URLComponents(url: baseURL.appendingPathComponent("m/v1/app/" + path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty {
            components.queryItems = query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        }
        var request = URLRequest(url: components.url!)
        request.httpMethod = method
        request.timeoutInterval = 25
        authorize(&request)
        if let json {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try? JSONSerialization.data(withJSONObject: json)
        }
        return request
    }

    func authorize(_ request: inout URLRequest) {
        request.setValue("Bearer \(credentials.token)", forHTTPHeaderField: "Authorization")
        if let id = credentials.accessClientId, let secret = credentials.accessClientSecret {
            request.setValue(id, forHTTPHeaderField: "CF-Access-Client-Id")
            request.setValue(secret, forHTTPHeaderField: "CF-Access-Client-Secret")
        }
    }

    /// Only the Mac's own JSON answer counts; a proxy's HTML 401/403 must never be taken as "unpaired".
    static func isOwnJSON(_ response: HTTPURLResponse?) -> Bool {
        (response?.value(forHTTPHeaderField: "Content-Type") ?? "").lowercased().contains("application/json")
    }

    private static func load(_ session: URLSession, _ request: URLRequest) async throws -> (Data, URLResponse) {
        do { return try await session.data(for: request) } catch is CancellationError { throw CancellationError() }
        catch let error as URLError where error.code == .cancelled { throw CancellationError() }
        catch { throw APIError.offline }
    }

    private struct ErrorBody: Decodable { var error: String?; var message: String? }

    /// Sends and checks the status; returns the raw JSON body.
    public func send(_ request: URLRequest) async throws -> Data {
        let (data, response) = try await Self.load(session, request)
        let http = response as? HTTPURLResponse
        let status = http?.statusCode ?? 0
        if (200..<300).contains(status) { return data }
        // Only the Mac's own JSON answer is a real "no". A proxy's or captive portal's HTML 404/400/500 says nothing
        // about the request: treat it as "could not reach the Mac" so the outbox keeps the message and tries again.
        guard Self.isOwnJSON(http) else { throw APIError.server(status: status, error: nil) }
        let errorBody = try? JSONDecoder().decode(ErrorBody.self, from: data)
        let error = errorBody?.error
        if status == 400, let message = errorBody?.message, !message.isEmpty { throw APIError.refused(String(message.prefix(200))) }
        switch status {
        case 401: throw APIError.unauthorized
        case 404: throw APIError.notFound
        case 410: throw APIError.gone
        case 429: throw APIError.rateLimited
        case 400, 413: throw APIError.badRequest(error)
        default: throw APIError.server(status: status, error: error)
        }
    }

    public func get<T: Decodable>(_ type: T.Type, _ path: String, query: [String: String] = [:]) async throws -> T {
        let data = try await send(request(path, query: query))
        do { return try EventDecoding.decoder.decode(T.self, from: data) } catch { throw APIError.decoding }
    }

    public func post<T: Decodable>(_ type: T.Type, _ path: String, json: Any) async throws -> T {
        let data = try await send(request(path, method: "POST", json: json))
        do { return try EventDecoding.decoder.decode(T.self, from: data) } catch { throw APIError.decoding }
    }

    // MARK: protocol calls

    public func capabilities() async throws -> Capabilities { try await get(Capabilities.self, "capabilities") }
    public func status() async throws -> ServerStatus { try await get(ServerStatus.self, "status") }

    public func events(after: Int, limit: Int = 200, channel: String? = nil) async throws -> EventsPage {
        var query = ["after": String(after), "limit": String(limit)]
        if let channel { query["channel"] = channel }
        let data = try await send(request("events", query: query))
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw APIError.decoding }
        let rawEvents = (object["events"] as? [Any]) ?? []
        let events = (try? JSONSerialization.data(withJSONObject: rawEvents)).map(EventDecoding.events(fromArray:)) ?? []
        return EventsPage(events: events, lastSeq: object["lastSeq"] as? Int ?? 0, oldestSeq: object["oldestSeq"] as? Int ?? 0)
    }

    public func sendMessage(text: String? = nil, choice: String? = nil, channel: String? = nil, clientId: String? = nil) async throws -> SendResult {
        var body: [String: Any] = [:]
        if let text { body["text"] = text }
        if let choice { body["choice"] = choice }
        if let channel, !channel.isEmpty { body["channel"] = channel }
        if let clientId { body["clientId"] = clientId }
        return try await post(SendResult.self, "messages", json: body)
    }

    /// `remember`: R11 — also make this a standing rule so the Mac stops asking about the same kind of thing.
    public func answerCard(_ cardId: String, _ answer: CardAnswer, remember: Bool = false) async throws -> CardResult {
        // Card ids are `[A-Za-z0-9_:.-]` (ax-hq: `org:d:<id>`, `p0:<id>`). `:` is valid in a path segment and the
        // URL builder escapes anything else once; escaping here too would double it (`%253A`).
        let id = cardId.replacingOccurrences(of: "/", with: "")
        var body = answer.body
        if remember { body["remember"] = true }
        return try await post(CardResult.self, "cards/\(id)", json: body)
    }

    /// `GET views/<name>` → `data`.
    public func view<T: Decodable>(_ type: T.Type, _ name: String, query: [String: String] = [:]) async throws -> T {
        try await get(ViewEnvelope<T>.self, "views/\(name)", query: query).data
    }

    public func viewAction<T: Decodable>(_ type: T.Type, _ name: String, _ action: String, json: [String: Any]) async throws -> T {
        try await post(ViewEnvelope<T>.self, "views/\(name)/\(action)", json: json).data
    }

    /// A raw view as JSON, for server-driven screens the app has no model for.
    public func rawView(_ name: String) async throws -> Any {
        let data = try await send(request("views/\(name)"))
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let inner = object["data"] else {
            throw APIError.decoding
        }
        return inner
    }

    /// `channel`: a team or bot room (§37 `x-channel`, only when `features` lists `share-rooms`); nil = the main chat.
    public func share(_ bytes: Data, name: String, contentType: String, channel: String? = nil) async throws -> SendResult {
        var request = request("share", method: "POST")
        request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        if let channel, !channel.isEmpty { request.setValue(channel, forHTTPHeaderField: "x-channel") }
        request.setValue(name.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "shared", forHTTPHeaderField: "X-File-Name")
        request.httpBody = bytes
        let data = try await send(request)
        do { return try JSONDecoder().decode(SendResult.self, from: data) } catch { throw APIError.decoding }
    }

    /// 휴대폰 신호: `POST {base}/m/v1/ingest` (not under `app/`), same token. Items from `PhoneSignals`.
    public func ingest(_ items: [[String: Any]]) async throws {
        var request = URLRequest(url: baseURL.appendingPathComponent("m/v1/ingest"))
        request.httpMethod = "POST"
        request.timeoutInterval = 25
        authorize(&request)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: PhoneSignals.body(items))
        _ = try await send(request)
    }

    /// `POST location {lat, lng, accuracyM?}`: where the phone is now (only when `features` lists `location`).
    public func reportLocation(lat: Double, lng: Double, accuracyM: Double?) async throws {
        var body: [String: Any] = ["lat": lat, "lng": lng]
        if let accuracyM, accuracyM.isFinite, accuracyM >= 0 { body["accuracyM"] = (accuracyM * 10).rounded() / 10 }
        _ = try await send(request("location", method: "POST", json: body))
    }

    /// §30 `POST dictation`: raw audio in, `{text, message?}` out. The Mac's own words for a "no" (400 too_short,
    /// 413 too_long, 503 no_transcriber, 500 failed) come back as `.refused(message)` so the screen can show them.
    public func dictate(_ bytes: Data, contentType: String = "audio/mp4") async throws -> DictationAnswer {
        var request = request("dictation", method: "POST")
        request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 120 // §30: the same in all three apps
        request.httpBody = bytes
        let (data, response) = try await Self.load(session, request)
        let http = response as? HTTPURLResponse
        let status = http?.statusCode ?? 0
        if (200..<300).contains(status) { return DictationAnswer.decode(data) }
        guard Self.isOwnJSON(http) else { throw APIError.server(status: status, error: nil) }
        if status == 401 { throw APIError.unauthorized }
        if let message = DictationAnswer.decode(data).message { throw APIError.refused(message) }
        if status == 404 { throw APIError.notFound }
        throw APIError.server(status: status, error: nil)
    }

    /// §21.4 `POST read {channel, upTo}`: the owner read a room (other devices clear it too).
    public func markRead(channel: String, upTo: Int) async throws {
        _ = try await send(request("read", method: "POST", json: ["channel": channel, "upTo": upTo]))
    }

    /// `POST messages/<seq>/react`: thumbs up / down on a bot's message ("more like this" / "less").
    public func react(seq: Int, emoji: String) async throws {
        _ = try await send(request("messages/\(seq)/react", method: "POST", json: ["emoji": emoji]))
    }

    /// PROTOCOL-REQUESTS.md R7: the key goes straight to the Mac's Keychain and is never sent back.
    public func connectProvider(_ id: String, apiKey: String) async throws {
        _ = try await send(request("providers/\(id)/key", method: "POST", json: ["apiKey": apiKey]))
    }

    public func disconnectProvider(_ id: String) async throws {
        _ = try await send(request("providers/\(id)/disconnect", method: "POST", json: [String: String]()))
    }

    public func unpair() async throws { _ = try await send(request("unpair", method: "POST", json: [String: String]())) }

    public func file(_ relativeURL: String) async throws -> Data {
        var request = URLRequest(url: baseURL.appendingPathComponent("m/v1/app/" + relativeURL))
        authorize(&request)
        return try await send(request)
    }

    func streamRequest(lastSeq: Int) -> URLRequest {
        var request = request("stream")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.setValue(String(lastSeq), forHTTPHeaderField: "Last-Event-ID")
        request.timeoutInterval = 90 // keepalive every 25 s
        return request
    }
}

public struct ViewEnvelope<T: Decodable>: Decodable {
    public var view: String?
    public var version: Int?
    public var data: T
}

public struct ViewInfo: Decodable, Hashable, Sendable {
    public var name: String
    public var version: Int
    public var actions: [String]?
    /// PROTOCOL-REQUESTS.md R9: server-drawn screens. Shown under 더보기 › 새 기능.
    public var title: String?
    public var icon: String?
    public var ui: String?
}

public struct Capabilities: Decodable, Sendable {
    public var protocolVersion: Int
    public var features: [String]
    public var views: [ViewInfo]

    enum CodingKeys: String, CodingKey { case protocolVersion = "protocol", features, views }

    public init(protocolVersion: Int = 1, features: [String] = [], views: [ViewInfo] = []) {
        self.protocolVersion = protocolVersion; self.features = features; self.views = views
    }

    public func has(_ feature: String) -> Bool { features.contains(feature) }
    public func hasView(_ name: String) -> Bool { views.contains { $0.name == name } }
    public func hasAction(_ view: String, _ action: String) -> Bool { views.first { $0.name == view }?.actions?.contains(action) == true }
    public func view(_ name: String) -> ViewInfo? { views.first { $0.name == name } }
}

public struct ServerStatus: Decodable, Sendable {
    public struct Assistant: Decodable, Sendable { public var name: String; public var language: String?; public var timezone: String? }
    public var assistant: Assistant
    public var lastSeq: Int
    public var serverTime: Date?
    /// A stable id of this Mac's install (when the server sends one), so the same Mac reached by IP or by name is one Mac.
    public var serverId: String?
    /// PROTOCOL-REQUESTS.md R10: the global stop switch.
    public var stopped: Bool?
}

extension APIClient {
    /// §7.7: one APNs token per device; the Mac sends cards and messages while no stream is open.
    public func registerPush(token: String, production: Bool, topic: String) async throws {
        _ = try await send(request("push/register", method: "POST", json: ["token": token, "environment": production ? "production" : "development", "topic": topic]))
    }
}

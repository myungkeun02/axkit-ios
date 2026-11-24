import Foundation

// App protocol v1 events (docs/APP-PROTOCOL.md §4, §7). Every field the server may leave out is optional, and unknown
// fields are ignored, so a newer server keeps working with this app.

public struct Choice: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var label: String
    public init(id: String, label: String) { self.id = id; self.label = label }
}

public struct Author: Codable, Hashable, Sendable {
    public var id: String
    public var name: String
    public var avatar: String?
    public init(id: String, name: String, avatar: String? = nil) { self.id = id; self.name = name; self.avatar = avatar }
}

public struct Attachment: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var contentType: String
    public var size: Int?
    /// Relative to the app base (`files/<id>`), fetched with the same token.
    public var url: String
}

public struct EventLink: Codable, Hashable, Sendable {
    public var label: String
    public var url: String
}

public struct CardOption: Codable, Hashable, Sendable, Identifiable {
    public enum Tone: String, Codable, Sendable { case primary, danger, neutral }
    public var id: String
    public var label: String
    public var tone: Tone?
    /// R3: one plain line on what this choice will do ("견적서_11월.pdf를 지금 메일로 보내요").
    public var detail: String?
    public init(id: String, label: String, tone: Tone? = nil, detail: String? = nil) {
        self.id = id; self.label = label; self.tone = tone; self.detail = detail
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        label = try c.decode(String.self, forKey: .label)
        detail = try c.decodeIfPresent(String.self, forKey: .detail)
        let raw: String? = (try? c.decodeIfPresent(String.self, forKey: .tone)) ?? nil
        tone = raw.flatMap { Tone(rawValue: $0) }
    }
}

public struct RememberOffer: Codable, Hashable, Sendable {
    public var label: String
    public var detail: String?
    public init(label: String, detail: String? = nil) { self.label = label; self.detail = detail }
}

/// A money amount on a payment card (PROTOCOL-REQUESTS.md R3).
public struct Money: Codable, Hashable, Sendable {
    public var value: Double
    public var currency: String
    public init(value: Double, currency: String) { self.value = value; self.currency = currency }
}

/// §21.3: a piece of work, a pipeline step or a meeting; its lines share the id and the first one has `start`.
public struct EventThread: Codable, Hashable, Sendable {
    public var id: String
    public var title: String?
    public var start: Bool?
    public init(id: String, title: String? = nil, start: Bool? = nil) { self.id = id; self.title = title; self.start = start }
}

/// §21.4: someone reacted to a line.
public struct ReactionEvent: Codable, Hashable, Sendable {
    public var seq: Int
    public var at: Date?
    public var target: Int
    public var emoji: String
    public var by: Author?
    public var channel: String?
}

/// §21.4: a room was read up to `upTo` (on another device too).
public struct ReadEvent: Codable, Hashable, Sendable {
    public var seq: Int
    public var channel: String?
    public var upTo: Int
}

public struct MessageEvent: Codable, Hashable, Sendable {
    public enum Role: String, Codable, Sendable { case assistant, owner }
    public var seq: Int
    public var at: Date
    public var role: Role
    public var text: String
    public var choices: [Choice]?
    public var channel: String?
    public var author: Author?
    /// R17: who a bot was talking to (bot-to-bot lines in team and meeting rooms).
    public var to: Author?
    public var thread: EventThread?
    public var attachments: [Attachment]?
    public var imageUrl: String?
    public var links: [EventLink]?
    /// §22: this reply handed a browser page over to the app (`view` is `browser-live`).
    public var live: LiveHandoff?
}

/// §22: `{view:"browser-live", reason, url?}` on the assistant's reply.
public struct LiveHandoff: Codable, Hashable, Sendable {
    public var view: String
    public var reason: String?
    public var url: String?
    public init(view: String, reason: String? = nil, url: String? = nil) { self.view = view; self.reason = reason; self.url = url }
}

public struct NoticeEvent: Codable, Hashable, Sendable {
    public var seq: Int
    public var at: Date
    public var text: String
    public var choices: [Choice]?
    public var channel: String?
    public var author: Author?
    public var attachments: [Attachment]?
    public var imageUrl: String?
    public var links: [EventLink]?
    public var thread: EventThread?
    /// What the notice is about (`dev.job`, `browser.task`, `errands.task`, `work.interrupted`, `errands.seat` …).
    public var kind: String? = nil
    /// §28: a browser errand stopped at a step for the owner — same as a reply's `live` (§22).
    public var live: LiveHandoff? = nil
}

public struct CardEvent: Codable, Hashable, Sendable, Identifiable {
    public var id: String { cardId }
    public var seq: Int
    public var at: Date
    public var cardId: String
    public var summary: String
    public var effects: [String]
    public var effectLabels: [String]
    public var note: String?
    public var expiresAt: Date?
    public var options: [CardOption]?
    public var selects: [CardSelect]?
    public var form: CardForm?
    /// `false` = buttons only (§7.3). Missing means a free-text answer is allowed when the server has `card-reply`.
    public var freeText: Bool?
    public var amount: Money?
    public var merchant: String?
    /// §7.3: an input window on a card (Discord modal). `secret` fields (a P0 PIN) are typed hidden.
public struct CardForm: Codable, Hashable, Sendable {
    public struct Field: Codable, Hashable, Sendable, Identifiable {
        public var id: String
        public var label: String
        public var value: String?
        public var multiline: Bool?
        public var required: Bool?
        public var secret: Bool?
    }
    public var id: String
    public var title: String?
    public var fields: [Field]
}

/// §7.3: a pick-from-list menu on a card.
public struct CardSelect: Codable, Hashable, Sendable, Identifiable {
    public struct Choice: Codable, Hashable, Sendable, Identifiable {
        public var id: String
        public var label: String
        public var description: String?
    }
    public var id: String
    public var placeholder: String?
    public var min: Int?
    public var max: Int?
    public var choices: [Choice]
}

/// R11: the Mac offers to stop asking about this kind of thing ("앞으로 15만원 이하 원두 주문은 알아서 할게요").
    public var remember: RememberOffer?
    /// R15: what the question is about. Two cards with the same topic are the same question; only the newest shows.
    public var topic: String?
    public var channel: String?
    public var author: Author?
    public var attachments: [Attachment]?
    public var imageUrl: String?

    public init(seq: Int, at: Date, cardId: String, summary: String, effects: [String], effectLabels: [String], note: String? = nil,
                expiresAt: Date? = nil, options: [CardOption]? = nil, freeText: Bool? = nil, amount: Money? = nil, merchant: String? = nil,
                channel: String? = nil, author: Author? = nil) {
        self.seq = seq; self.at = at; self.cardId = cardId; self.summary = summary; self.effects = effects
        self.effectLabels = effectLabels; self.note = note; self.expiresAt = expiresAt; self.options = options
        self.freeText = freeText; self.amount = amount; self.merchant = merchant; self.channel = channel; self.author = author
    }

    public var isPayment: Bool { effects.contains("pay") || amount != nil }

    /// Same question = same topic, or (without one) the same context and question text.
    public var questionKey: String { topic ?? "\(note ?? "")\u{1F}\(summary)" }
}

public struct CardClosedEvent: Codable, Hashable, Sendable {
    public var seq: Int
    public var at: Date
    public var cardId: String
    public var state: String
    public var answer: String?
    public var channel: String?
}

/// The main chat handed work to a specialist bot (PROTOCOL-REQUESTS.md R2).
public struct DelegationEvent: Codable, Hashable, Sendable {
    public enum State: String, Codable, Sendable { case started, done, failed }
    public var seq: Int
    public var at: Date
    public var bot: Author
    /// The bot's own room, opened when the owner taps the line.
    public var botChannel: String
    public var task: String
    public var state: State
    public var summary: String?
    /// Where the line is shown; missing = the main chat.
    public var channel: String?

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        seq = try c.decode(Int.self, forKey: .seq)
        at = try c.decode(Date.self, forKey: .at)
        bot = try c.decode(Author.self, forKey: .bot)
        botChannel = try c.decode(String.self, forKey: .botChannel)
        task = try c.decode(String.self, forKey: .task)
        state = (try? c.decode(State.self, forKey: .state)) ?? .started
        summary = try c.decodeIfPresent(String.self, forKey: .summary)
        channel = try c.decodeIfPresent(String.self, forKey: .channel)
    }
}

public enum AppEvent: Hashable, Sendable {
    case message(MessageEvent)
    case notice(NoticeEvent)
    case card(CardEvent)
    case cardClosed(CardClosedEvent)
    case delegation(DelegationEvent)
    case reaction(ReactionEvent)
    case read(ReadEvent)
    /// A type this app does not know yet (newer server). Kept only for its seq.
    case unknown(type: String, seq: Int)

    public var seq: Int {
        switch self {
        case .message(let e): e.seq
        case .notice(let e): e.seq
        case .card(let e): e.seq
        case .cardClosed(let e): e.seq
        case .delegation(let e): e.seq
        case .reaction(let e): e.seq
        case .read(let e): e.seq
        case .unknown(_, let seq): seq
        }
    }

    /// Room id; "" is the main chat.
    public var channel: String {
        let raw: String? = switch self {
        case .message(let e): e.channel
        case .notice(let e): e.channel
        case .card(let e): e.channel
        case .cardClosed(let e): e.channel
        case .delegation(let e): e.channel
        case .reaction(let e): e.channel
        case .read(let e): e.channel
        case .unknown: nil
        }
        return raw ?? ""
    }
}

public enum EventDecoding {
    public static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .custom { decoder in
            let text = try decoder.singleValueContainer().decode(String.self)
            if let date = ISODates.parse(text) { return date }
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "date \(text)"))
        }
        return d
    }()

    private struct Head: Decodable { var type: String; var seq: Int }

    /// One event, or nil when it is not an event at all. Unknown types decode to `.unknown`; a known type with a broken
    /// shape also becomes `.unknown` so one bad event never stops the stream.
    public static func event(from data: Data) -> AppEvent? {
        guard let head = try? decoder.decode(Head.self, from: data) else { return nil }
        func decode<T: Decodable>(_ type: T.Type) -> T? { try? decoder.decode(type, from: data) }
        switch head.type {
        case "message": if let e = decode(MessageEvent.self) { return .message(e) }
        case "notice": if let e = decode(NoticeEvent.self) { return .notice(e) }
        case "card": if let e = decode(CardEvent.self) { return .card(e) }
        case "card_closed": if let e = decode(CardClosedEvent.self) { return .cardClosed(e) }
        case "delegation": if let e = decode(DelegationEvent.self) { return .delegation(e) }
        case "reaction": if let e = decode(ReactionEvent.self) { return .reaction(e) }
        case "read": if let e = decode(ReadEvent.self) { return .read(e) }
        default: break
        }
        return .unknown(type: head.type, seq: head.seq)
    }

    /// `events` responses: decodes each element on its own.
    public static func events(fromArray data: Data) -> [AppEvent] {
        guard let array = try? JSONSerialization.jsonObject(with: data) as? [Any] else { return [] }
        return array.compactMap { item in
            guard item is [String: Any], let bytes = try? JSONSerialization.data(withJSONObject: item) else { return nil }
            return event(from: bytes)
        }
    }
}

public enum ISODates {
    // Made once: building an ISO8601DateFormatter costs more than parsing (ISO8601DateFormatter is thread-safe).
    nonisolated(unsafe) private static let withFraction: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    nonisolated(unsafe) private static let plain: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    public static func parse(_ text: String) -> Date? {
        withFraction.date(from: text) ?? plain.date(from: text)
    }
}

public typealias CardForm = CardEvent.CardForm
public typealias CardSelect = CardEvent.CardSelect

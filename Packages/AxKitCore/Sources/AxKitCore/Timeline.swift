import Foundation

/// The ordered event log split into rooms. "" is the main chat. Pure value logic, so it is easy to test.
public struct Timeline: Sendable {
    public enum Item: Identifiable, Hashable, Sendable, Codable {
        case message(MessageEvent)
        case notice(NoticeEvent)
        /// Cards are looked up by id; a re-sent card (same id, new buttons) moves down to where it was sent again.
        case card(id: String, seq: Int)
        case delegation(DelegationEvent)

        public var id: Int { seq }
        public var seq: Int {
            switch self {
            case .message(let e): e.seq
            case .notice(let e): e.seq
            case .card(_, let seq): seq
            case .delegation(let e): e.seq
            }
        }
    }

    public static let maxPerRoom = 1000

    public private(set) var lastSeq = 0
    private var seen = Set<Int>()
    private var rooms: [String: [Item]] = [:]
    public private(set) var cards: [String: CardEvent] = [:]
    public private(set) var closed: [String: CardClosedEvent] = [:]
    /// §21.4: reactions under a line (target seq → emoji → count).
    public private(set) var reactions: [Int: [String: Int]] = [:]
    /// The newest seq the owner has looked at, per room.
    public private(set) var readUpTo: [String: Int] = [:]

    public init() {}

    /// Returns true when the event was new.
    @discardableResult
    public mutating func apply(_ event: AppEvent) -> Bool {
        guard !seen.contains(event.seq) else { return false }
        seen.insert(event.seq)
        lastSeq = max(lastSeq, event.seq)
        let room = event.channel
        switch event {
        case .message(let e): append(.message(e), to: room)
        case .notice(let e): append(.notice(e), to: room)
        case .delegation(let e): append(.delegation(e), to: room)
        case .card(let e):
            let previous = cards[e.cardId]
            // An older copy arriving late (catch-up after the stream) never replaces the newer one.
            if let previous, e.seq <= previous.seq { break }
            cards[e.cardId] = e
            if let previous {
                // Asked again (more to fill in, new buttons): show it at the bottom, where the owner is looking.
                rooms[previous.channel ?? ""]?.removeAll { if case .card(let id, _) = $0 { id == e.cardId } else { false } }
                // A fresh ask reopens it, even if the app had closed it locally.
                if closed[e.cardId]?.seq == 0 { closed[e.cardId] = nil }
            }
            append(.card(id: e.cardId, seq: e.seq), to: room)
        case .cardClosed(let e): closed[e.cardId] = e
        case .reaction(let e): reactions[e.target, default: [:]][e.emoji, default: 0] += 1
        case .read(let e): readUpTo[e.channel ?? ""] = max(readUpTo[e.channel ?? ""] ?? 0, e.upTo)
        case .unknown: break
        }
        return true
    }

    public mutating func apply(_ events: [AppEvent]) {
        for event in events.sorted(by: { $0.seq < $1.seq }) { apply(event) }
    }

    /// Changes the room's list in place (no copy of the whole room per event).
    private mutating func append(_ item: Item, to room: String) {
        rooms[room, default: []].insertInOrder(item)
        if let count = rooms[room]?.count, count > Self.maxPerRoom {
            rooms[room]?.removeFirst(count - Self.maxPerRoom)
        }
    }

    public func items(in room: String) -> [Item] { rooms[room] ?? [] }
    /// The event with this seq has been applied.
    public func has(seq: Int) -> Bool { seen.contains(seq) }
    public var roomIds: [String] { Array(rooms.keys) }

    public func card(_ id: String) -> CardEvent? { cards[id] }
    public func closure(of id: String) -> CardClosedEvent? { closed[id] }

    public func isOpen(_ id: String, now: Date = Date()) -> Bool {
        guard let card = cards[id], closed[id] == nil else { return false }
        if let expires = card.expiresAt, expires < now { return false }
        return true
    }

    /// Open cards, newest first. The same question never shows twice: older open cards with the same key are hidden.
    public func openCards(now: Date = Date()) -> [CardEvent] {
        var seenKeys = Set<String>()
        return cards.values.filter { isOpen($0.cardId, now: now) }.sorted { $0.seq > $1.seq }
            .filter { seenKeys.insert($0.questionKey).inserted }
    }

    /// An older copy of a question that is asked again in a newer open card (hidden in lists and the chat).
    public func isDuplicate(_ id: String, now: Date = Date()) -> Bool {
        guard let card = cards[id], isOpen(id, now: now) else { return false }
        // openCards keeps the newest open card per question, so an older one is a duplicate. No sort needed.
        return cards.values.contains { other in
            other.cardId != id && other.questionKey == card.questionKey && other.seq > card.seq && isOpen(other.cardId, now: now)
        }
    }

    /// Closed (or expired) cards, newest first.
    public func finishedCards(now: Date = Date(), limit: Int = 20) -> [CardEvent] {
        Array(cards.values.filter { !isOpen($0.cardId, now: now) }.sorted { $0.seq > $1.seq }.prefix(limit))
    }

    /// After the owner answers, before `card_closed` arrives on the stream (or when the stream is down).
    public mutating func closeLocally(_ cardId: String, state: String, answer: String? = nil) {
        guard closed[cardId] == nil, let card = cards[cardId] else { return }
        closed[cardId] = CardClosedEvent(seq: 0, at: Date(), cardId: cardId, state: state, answer: answer, channel: card.channel)
    }

    // MARK: kept on the phone

    /// What the phone keeps between launches: the newest lines of each room, their cards and what was read.
    public struct Snapshot: Codable, Sendable {
        /// Bumped when the shape changes; a file of another version is not read (catch-up fills the chat again).
        public static let currentVersion = 1
        public var version = Snapshot.currentVersion
        public var lastSeq: Int
        public var rooms: [String: [Item]]
        public var cards: [String: CardEvent]
        public var closed: [String: CardClosedEvent]
        public var reactions: [Int: [String: Int]]
        public var readUpTo: [String: Int]

        init(lastSeq: Int, rooms: [String: [Item]], cards: [String: CardEvent], closed: [String: CardClosedEvent],
             reactions: [Int: [String: Int]], readUpTo: [String: Int]) {
            self.lastSeq = lastSeq; self.rooms = rooms; self.cards = cards; self.closed = closed
            self.reactions = reactions; self.readUpTo = readUpTo
        }

        enum CodingKeys: String, CodingKey { case version, lastSeq, rooms, cards, closed, reactions, readUpTo }

        /// One line or card this app can no longer read is skipped; the rest of the history stays.
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            version = try c.decode(Int.self, forKey: .version)
            guard version == Self.currentVersion else {
                throw DecodingError.dataCorruptedError(forKey: .version, in: c, debugDescription: "snapshot version \(version)")
            }
            lastSeq = try c.decode(Int.self, forKey: .lastSeq)
            rooms = ((try? c.decode([String: [Lossy<Item>]].self, forKey: .rooms)) ?? [:]).mapValues { $0.compactMap(\.value) }
            cards = ((try? c.decode([String: Lossy<CardEvent>].self, forKey: .cards)) ?? [:]).compactMapValues(\.value)
            closed = ((try? c.decode([String: Lossy<CardClosedEvent>].self, forKey: .closed)) ?? [:]).compactMapValues(\.value)
            reactions = (try? c.decode([Int: [String: Int]].self, forKey: .reactions)) ?? [:]
            readUpTo = (try? c.decode([String: Int].self, forKey: .readUpTo)) ?? [:]
        }
    }

    /// Lines per room kept on the phone.
    public static let keptPerRoom = 200

    public func snapshot(perRoom: Int = Timeline.keptPerRoom) -> Snapshot {
        let kept = rooms.mapValues { Array($0.suffix(perRoom)) }
        var cardIds = Set<String>()
        for items in kept.values { for item in items { if case .card(let id, _) = item { cardIds.insert(id) } } }
        // Open cards stay even when their line scrolled out (결재 tab).
        for (id, _) in cards where isOpen(id) { cardIds.insert(id) }
        let seqs = Set(kept.values.flatMap { $0.map(\.seq) })
        return Snapshot(lastSeq: lastSeq, rooms: kept, cards: cards.filter { cardIds.contains($0.key) },
                        closed: closed.filter { cardIds.contains($0.key) }, reactions: reactions.filter { seqs.contains($0.key) },
                        readUpTo: readUpTo)
    }

    public init(_ snapshot: Snapshot) {
        lastSeq = snapshot.lastSeq
        rooms = snapshot.rooms
        cards = snapshot.cards
        closed = snapshot.closed
        reactions = snapshot.reactions
        readUpTo = snapshot.readUpTo
        seen = Set(snapshot.rooms.values.flatMap { $0.map(\.seq) })
    }

    /// Only what was read (a server that started over keeps nothing else).
    public mutating func restoreRead(_ readUpTo: [String: Int]) {
        for (room, seq) in readUpTo { self.readUpTo[room] = max(self.readUpTo[room] ?? 0, seq) }
    }

    /// The newest line with 선택지 in a room that the owner has not answered yet (nothing of theirs after it).
    public func openQuestion(in room: String) -> Int? { Self.openQuestion(items(in: room)) }

    public static func openQuestion(_ items: [Item]) -> Int? {
        for item in items.reversed() {
            switch item {
            case .message(let m):
                if m.role == .owner { return nil }
                if !(m.choices ?? []).isEmpty { return m.seq }
            case .notice(let n):
                if !(n.choices ?? []).isEmpty { return n.seq }
            default: continue
            }
        }
        return nil
    }

    public mutating func markRead(_ room: String) {
        readUpTo[room] = items(in: room).last?.seq ?? readUpTo[room] ?? 0
    }

    public func unreadCount(in room: String) -> Int {
        let after = readUpTo[room] ?? 0
        // Items are in seq order: walk back from the newest and stop at what was read.
        var count = 0
        for item in items(in: room).reversed() {
            guard item.seq > after else { break }
            if case .message(let m) = item, m.role != .assistant { continue }
            count += 1
        }
        return count
    }

    /// Short line for the bot list.
    public func preview(of room: String) -> (text: String, at: Date)? {
        for item in items(in: room).reversed() {
            switch item {
            case .message(let m): return (ChatText.preview(m.text), m.at)
            case .notice(let n): return (ChatText.preview(n.text), n.at)
            case .delegation(let d): return (ChatText.preview(d.task), d.at)
            case .card(let id, _): if let c = cards[id] { return (ChatText.preview(ChatText.cardTitle(summary: c.summary, note: c.note)), c.at) }
            }
        }
        return nil
    }
}

extension Array where Element == Timeline.Item {
    /// Appends, or inserts in seq order when an older event arrives late.
    mutating func insertInOrder(_ item: Element) {
        if let last, last.seq > item.seq {
            insert(item, at: firstIndex { $0.seq > item.seq } ?? endIndex)
        } else {
            append(item)
        }
    }
}

/// Plain Korean for card states.
public enum CardWords {
    public static func closedLabel(_ closure: CardClosedEvent?, expired: Bool) -> String {
        if let answer = closure?.answer, !answer.isEmpty { return "답함: \(answer)" }
        switch closure?.state {
        case "approved": return "승인했어요"
        case "denied": return "안 하기로 했어요"
        case "edit": return "고쳐 달라고 했어요"
        case "closed": return "다른 곳에서 처리했어요"
        case "expired": return "시간이 지나 닫혔어요"
        default: return expired ? "시간이 지나 닫혔어요" : "끝났어요"
        }
    }

    /// A 결재 in the chat: the question, then why (cleaned, never raw context).
    public static func chatLine(_ card: CardEvent) -> String {
        let title = ChatText.cardTitle(summary: card.summary, note: card.note)
        let note = ChatText.clean(card.note ?? "")
        if note.isEmpty || note.hasPrefix(title) { return note.isEmpty ? title : note }
        return title + "\n" + note
    }

    /// Buttons when the server sends none (today's ax-kit cards): the three classic decisions in easy words.
    public static func defaultOptions(for card: CardEvent) -> [CardOption] {
        let yes = card.isPayment ? "네, 결제해요" : card.effects.contains("send") ? "네, 보내요" : card.effects.contains("delete") ? "네, 지워요" : "네, 해 주세요"
        return [
            CardOption(id: "decision:approve", label: yes, tone: .primary),
            CardOption(id: "decision:edit", label: "고쳐서 다시", tone: .neutral),
            CardOption(id: "decision:deny", label: "아니요", tone: .danger),
        ]
    }

    /// Turns a button id from `defaultOptions` back into a protocol answer.
    public static func answer(for option: CardOption) -> CardAnswer {
        if option.id.hasPrefix("decision:") { return .decision(String(option.id.dropFirst("decision:".count))) }
        return .option(option.id)
    }
}

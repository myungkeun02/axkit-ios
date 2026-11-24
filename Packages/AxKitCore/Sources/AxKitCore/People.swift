import Foundation

// MARK: §29 사람

/// `GET views/people`: the person cards, most recently changed first.
public struct PeopleView: Decodable, Sendable {
    public var title: String?
    public var people: [Person]

    enum CodingKeys: String, CodingKey { case title, people }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        title = try? c.decode(String.self, forKey: .title)
        people = (try? c.decode([Lossy<Person>].self, forKey: .people))?.compactMap(\.value) ?? []
    }
    public init(title: String? = nil, people: [Person]) { self.title = title; self.people = people }
}

public struct Person: Decodable, Hashable, Sendable, Identifiable {
    public var key: String
    public var name: String
    public var names: [String]
    public var title: String?
    public var company: String?
    public var relation: String?
    public var note: String?
    public var emails: Int
    public var lastSeen: Date?
    public var openCommitments: Int
    public var updatedAt: Date?

    public var id: String { key }

    enum CodingKeys: String, CodingKey { case key, name, names, title, company, relation, note, emails, lastSeen, openCommitments, updatedAt }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        key = try c.decode(String.self, forKey: .key)
        name = (try? c.decode(String.self, forKey: .name)) ?? key
        names = (try? c.decode([String].self, forKey: .names)) ?? []
        func text(_ k: CodingKeys) -> String? {
            guard let s = try? c.decode(String.self, forKey: k), !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            return s
        }
        title = text(.title)
        company = text(.company)
        relation = text(.relation)
        note = text(.note)
        emails = (try? c.decode(Int.self, forKey: .emails)) ?? 0
        lastSeen = try? c.decode(Date.self, forKey: .lastSeen)
        openCommitments = (try? c.decode(Int.self, forKey: .openCommitments)) ?? 0
        updatedAt = try? c.decode(Date.self, forKey: .updatedAt)
    }

    public init(key: String, name: String, names: [String] = [], title: String? = nil, company: String? = nil,
                relation: String? = nil, note: String? = nil, emails: Int = 0, lastSeen: Date? = nil,
                openCommitments: Int = 0, updatedAt: Date? = nil) {
        self.key = key; self.name = name; self.names = names; self.title = title; self.company = company
        self.relation = relation; self.note = note; self.emails = emails; self.lastSeen = lastSeen
        self.openCommitments = openCommitments; self.updatedAt = updatedAt
    }

    /// "대표 · 에이컴퍼니"
    public var roleLine: String { [title, company].compactMap { $0 }.joined(separator: " · ") }
    /// Other names the same person goes by.
    public var otherNames: [String] { names.filter { $0 != name } }
    public var noteLines: [String] {
        (note ?? "").split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    /// Search across name, other names, title, company, relation and note (case and spacing ignored).
    public func matches(_ query: String) -> Bool {
        let words = query.lowercased().split(whereSeparator: \.isWhitespace)
        guard !words.isEmpty else { return true }
        let hay = ([name] + names + [title, company, relation, note].compactMap { $0 }).joined(separator: " ").lowercased()
        return words.allSatisfy { hay.contains($0) }
    }
}

/// The four fields the owner can fix in the app.
public struct PersonForm: Equatable, Sendable {
    public var title: String
    public var company: String
    public var relation: String
    public var note: String

    /// §29: what the Mac accepts for each field (the edit sheet never lets more in).
    public static let limits = (title: 40, company: 60, relation: 80, note: 400)

    /// Cuts each field to its limit.
    public mutating func clamp() {
        if title.count > Self.limits.title { title = String(title.prefix(Self.limits.title)) }
        if company.count > Self.limits.company { company = String(company.prefix(Self.limits.company)) }
        if relation.count > Self.limits.relation { relation = String(relation.prefix(Self.limits.relation)) }
        if note.count > Self.limits.note { note = String(note.prefix(Self.limits.note)) }
    }

    public init(_ person: Person) {
        title = person.title ?? ""; company = person.company ?? ""; relation = person.relation ?? ""; note = person.note ?? ""
    }

    /// `POST views/people/edit` body: the key plus only the fields that changed; an emptied field is sent as "" (removes it).
    public func editBody(for person: Person) -> [String: String] {
        var body = ["key": person.key]
        func put(_ name: String, _ value: String, _ old: String?) {
            let v = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if v != (old ?? "") { body[name] = v }
        }
        put("title", title, person.title)
        put("company", company, person.company)
        put("relation", relation, person.relation)
        put("note", note, person.note)
        return body
    }

    /// The card as it should look after a save, when the Mac's answer carries no full card.
    public func applied(to person: Person) -> Person {
        var p = person
        func v(_ s: String) -> String? { let t = s.trimmingCharacters(in: .whitespacesAndNewlines); return t.isEmpty ? nil : t }
        p.title = v(title); p.company = v(company); p.relation = v(relation); p.note = v(note)
        p.updatedAt = Date()
        return p
    }
}

public enum PeopleWords {
    public static let empty = "대화에서 사람을 소개하면 여기에 카드가 생겨요."
    public static let deleteByTalking = "카드를 지우거나 두 사람을 합치려면 대화로 말해 주세요. 예: \"김민수 카드 지워 줘\""
}

struct PersonEditAnswer: Decodable { var person: Lossy<Person>? }

extension APIClient {
    public func people() async throws -> PeopleView { try await view(PeopleView.self, "people") }

    /// Returns the saved card when the Mac sends a full one back.
    public func editPerson(_ body: [String: String]) async throws -> Person? {
        try await viewAction(PersonEditAnswer.self, "people", "edit", json: body).person?.value
    }
}

// MARK: §30 받아쓰기

public enum DictationRules {
    /// Recording stops by itself after 3 minutes (longer talks belong in 회의 녹음).
    public static let maxSeconds: TimeInterval = 180
    /// Under this a recording is just a tap (the real Mac heard nothing in ~2 s quiet clips).
    public static let minSeconds: TimeInterval = 1
    /// Below this the loudest moment of the whole recording was silence: don't send it.
    public static let silentDb: Float = -55

    public static let tooShort = "너무 짧아요. 말한 뒤에 다시 눌러 주세요."
    public static let silent = "마이크 소리가 들어오지 않아요. 마이크를 가리지 않았는지 보고, 조금 더 가까이에서 말해 주세요."
    public static let denied = "마이크를 쓸 수 없어요. 설정 › ax-kit에서 마이크를 켜 주세요."
    public static let nothingHeard = "말소리를 찾지 못했어요. 조금 더 크게 말해 주세요."
    public static let failed = "받아쓰지 못했어요. 다시 해 주세요."

    /// dBFS → 0...1 for the level bars (-60 dB and below is empty).
    public static func meter(_ db: Float) -> Double {
        guard db.isFinite else { return 0 }
        return Double(max(0, min(1, (db + 60) / 60)))
    }

    /// 0:07, 1:42
    public static func clock(_ seconds: TimeInterval) -> String {
        let s = max(0, Int(seconds))
        return "\(s / 60):" + String(format: "%02d", s % 60)
    }

    /// Adds the spoken words to what is typed, with one space between them.
    public static func insert(_ words: String, into value: String) -> String {
        let text = words.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return value }
        if value.isEmpty { return text }
        return value.last!.isWhitespace ? value + text : value + " " + text
    }
}

public struct DictationAnswer: Equatable, Sendable {
    public var text: String
    public var message: String?
    public init(text: String, message: String? = nil) { self.text = text; self.message = message }

    /// `{text, message?}`
    public static func decode(_ data: Data) -> DictationAnswer {
        let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        let text = (object["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let message = (object["message"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return DictationAnswer(text: text, message: message.flatMap { $0.isEmpty ? nil : String($0.prefix(300)) })
    }
}

import Foundation

// `GET views/<name>` payloads (docs/APP-PROTOCOL.md §5, §7 and ios/PROTOCOL-REQUESTS.md). Fields the screens can live
// without are optional so a smaller or newer server still decodes.

// MARK: today (§5.1)

public struct TodayView: Decodable, Sendable {
    public struct Event: Decodable, Hashable, Sendable { public var title: String; public var start: String; public var end: String?; public var allDay: Bool? }
    public struct Todo: Decodable, Hashable, Sendable { public var text: String; public var due: String?; public var source: String? }
    public var date: String
    public var events: [Event]?
    public var todos: [Todo]?
    public var pendingCards: Int?
}

// MARK: bots (R1)

public struct BotsView: Decodable, Sendable {
    public struct Bot: Decodable, Hashable, Sendable, Identifiable {
        public var id: String
        public var name: String
        public var role: String?
        public var icon: String?
        /// R1: the bot's character picture (https, or `files/<id>` with the device token). Made on the Mac.
        public var avatar: String?
        /// Room id used in events and `POST messages {channel}`.
        public var channel: String
        public var status: String?
        public var statusText: String?
        public var isNew: Bool?
        /// R16: `lead` · `staff` · `reviewer`, the team it belongs to, and its AI grade (S/A/B/C).
        public var rank: String?
        public var team: String?
        public var tier: String?
        /// §16: how this bot works (its role prompt, ≤1500 chars) and who wrote it: `default` · `ai` · `owner`.
        public var instructions: String?
        public var instructionsBy: String?
    }
    public struct Team: Decodable, Hashable, Sendable, Identifiable {
        public var id: String
        public var name: String
        public var purpose: String?
        public var channel: String
        public var kind: String?
        public var members: [String]
        /// `owner` = the owner set it up; `ai` = the assistant chose size and grades (with `reason`).
        public var decidedBy: String?
        public var reason: String?
    }
    public struct Group: Decodable, Hashable, Sendable, Identifiable {
        public var id: String
        public var label: String
        public var summary: String?
        public var icon: String?
        public var bots: [Bot]
        /// R17: the room where this company's team leads meet.
        public var meetingChannel: String?
        public var teams: [Team]?
    }
    public struct Main: Decodable, Hashable, Sendable { public var name: String; public var subtitle: String? }
    public var main: Main?
    public var groups: [Group]

    public var allBots: [Bot] { groups.flatMap(\.bots) }
    public var allTeams: [Team] { groups.flatMap { $0.teams ?? [] } }
    /// The bot that speaks for a room: its lead when the room is a team's.
    public func bot(forChannel channel: String) -> Bot? {
        allBots.first { $0.channel == channel && $0.rank == "lead" } ?? allBots.first { $0.channel == channel }
    }
    public func team(forChannel channel: String) -> Team? { allTeams.first { $0.channel == channel } }
    public func group(forMeeting channel: String) -> Group? { groups.first { $0.meetingChannel == channel } }
    public func bot(id: String) -> Bot? { allBots.first { $0.id == id } }
    public func members(of team: Team) -> [Bot] { team.members.compactMap { bot(id: $0) } }
}

// MARK: docgraph (R4)

public struct DocGraphView: Decodable, Sendable {
    public struct Layer: Decodable, Hashable, Sendable, Identifiable { public var id: String; public var label: String; public var summary: String? }
    public struct Node: Decodable, Hashable, Sendable, Identifiable {
        public var id: String
        public var title: String
        public var layer: String
        public var group: String?
        public var summary: String?
        public var updatedAt: Date?
        public var weight: Double?
    }
    public struct Link: Decodable, Hashable, Sendable { public var from: String; public var to: String; public var label: String? }
    /// §21.7: the same documents as a list — layer → item → related items.
    public struct TreeLayer: Decodable, Hashable, Sendable, Identifiable {
        public struct Item: Decodable, Hashable, Sendable, Identifiable {
            public struct Related: Decodable, Hashable, Sendable, Identifiable { public var id: String; public var title: String; public var label: String? }
            public var id: String
            public var title: String
            public var summary: String?
            public var updatedAt: Date?
            public var related: [Related]?
        }
        public var id: String
        public var label: String
        public var summary: String?
        public var items: [Item]
    }
    public var layers: [Layer]
    public var nodes: [Node]
    public var links: [Link]
    public var tree: [TreeLayer]?
}

public struct DocumentDetail: Decodable, Sendable {
    public struct Related: Decodable, Hashable, Sendable, Identifiable { public var id: String; public var title: String }
    public var id: String
    public var title: String
    public var layer: String?
    public var markdown: String
    public var updatedAt: Date?
    public var related: [Related]?

    public init(id: String, title: String, layer: String? = nil, markdown: String, updatedAt: Date? = nil, related: [Related]? = nil) {
        self.id = id; self.title = title; self.layer = layer; self.markdown = markdown; self.updatedAt = updatedAt; self.related = related
    }

    /// The knowledge view answers with `name` instead of `id` (and `kind` instead of `layer`).
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let name = try c.decodeIfPresent(String.self, forKey: .name)
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? name ?? ""
        markdown = try c.decodeIfPresent(String.self, forKey: .markdown) ?? ""
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? name ?? "문서"
        layer = try c.decodeIfPresent(String.self, forKey: .layer) ?? c.decodeIfPresent(String.self, forKey: .kind)
        updatedAt = try? c.decodeIfPresent(Date.self, forKey: .updatedAt)
        related = try? c.decodeIfPresent([Related].self, forKey: .related)
    }
    private enum CodingKeys: String, CodingKey { case id, name, title, layer, kind, markdown, updatedAt, related }
}

public struct DocumentEnvelope: Decodable, Sendable { public var document: DocumentDetail? }

// MARK: calendar (R5)

public struct CalendarView: Decodable, Sendable {
    public struct Event: Decodable, Hashable, Sendable, Identifiable {
        public var id: String
        public var title: String
        public var start: Date
        public var end: Date?
        public var allDay: Bool?
        public var place: String?
    }
    public struct Done: Decodable, Hashable, Sendable, Identifiable {
        public var id: String
        public var title: String
        public var at: Date
        public var bot: Author?
        public var detail: String?
    }
    public struct Day: Decodable, Hashable, Sendable, Identifiable {
        public var id: String { date }
        public var date: String
        public var events: [Event]
        public var done: [Done]
    }
    public var month: String
    public var days: [Day]

    public func day(_ ymd: String) -> Day? { days.first { $0.date == ymd } }
}

// MARK: jobs (§7.8; toggle = R6)

public struct JobsView: Decodable, Sendable {
    public struct LastRun: Decodable, Hashable, Sendable { public var startedAt: Date?; public var ok: Bool?; public var error: String? }
    public struct Job: Decodable, Hashable, Sendable, Identifiable {
        public var id: String
        public var name: String
        public var detail: String?
        public var scheduleLabel: String?
        public var enabled: Bool
        public var running: Bool?
        public var lastRun: LastRun?
        public var nextRunAt: Date?
        public var source: String?
        /// R6: whether the app may switch it (missing = yes for `source: "ax"`).
        public var toggleable: Bool?
        public var canToggle: Bool { toggleable ?? (source == nil || source == "ax") }
    }
    public struct Group: Decodable, Hashable, Sendable, Identifiable { public var id: String; public var label: String; public var jobs: [Job] }
    public var groups: [Group]
}

// MARK: spending (§5.7)

public struct SpendingView: Decodable, Sendable {
    public struct Category: Decodable, Hashable, Sendable { public var category: String; public var label: String; public var amount: Double; public var count: Int }
    public struct Entry: Decodable, Hashable, Sendable, Identifiable {
        public var id: String
        public var at: Date?
        public var date: String
        public var merchant: String
        public var amount: Double
        public var category: String?
        public var categoryLabel: String?
        public var note: String?
        public var source: String?
    }
    public struct CategoryChoice: Decodable, Hashable, Sendable, Identifiable { public var id: String; public var label: String }
    public struct Subscription: Decodable, Hashable, Sendable { public var key: String; public var merchant: String; public var cadence: String; public var amount: Double; public var nextDate: String? }
    public var month: String
    public var currency: String
    public var total: Double
    public var count: Int
    public var byCategory: [Category]
    public var previousTotal: Double?
    public var budget: Double?
    public var entries: [Entry]?
    public var categories: [CategoryChoice]?
    public var subscriptions: [Subscription]?
}

// MARK: usage (§5.2; byBot = R8)

public struct UsageView: Decodable, Sendable {
    public struct Totals: Decodable, Hashable, Sendable {
        public var calls: Int
        public var failures: Int
        public var costUsd: Double
        public var inputTokens: Int?
        public var outputTokens: Int?
    }
    public struct ModelRow: Decodable, Hashable, Sendable { public var providerId: String; public var model: String; public var calls: Int; public var failures: Int; public var costUsd: Double }
    public struct PurposeRow: Decodable, Hashable, Sendable { public var purpose: String; public var calls: Int; public var costUsd: Double }
    public struct BotRow: Decodable, Hashable, Sendable { public var botId: String; public var name: String; public var calls: Int; public var costUsd: Double }
    public struct Point: Decodable, Hashable, Sendable { public var date: String; public var calls: Int; public var costUsd: Double }
    public struct Budget: Decodable, Hashable, Sendable { public var dailyUsd: Double; public var monthlyUsd: Double }
    public var period: String
    public var totals: Totals
    public var byModel: [ModelRow]
    public var byPurpose: [PurposeRow]?
    public var byBot: [BotRow]?
    public var daily: [Point]?
    public var budget: Budget?
}

// MARK: providers (R7)

public struct ProvidersView: Decodable, Sendable {
    public struct Provider: Decodable, Hashable, Sendable, Identifiable {
        public var id: String
        public var label: String
        /// `api_key`: paste a key · `subscription`: log in on the Mac · `local`: runs on the Mac.
        public var kind: String
        public var connected: Bool
        public var status: String?
        public var detail: String?
        public var keyHint: String?
        public var help: String?
        public var signupUrl: String?
        public var models: [String]?
    }
    public var providers: [Provider]
}

// MARK: hardware (R8b)

public struct HardwareView: Decodable, Sendable {
    public struct Machine: Decodable, Hashable, Sendable { public var name: String; public var model: String?; public var os: String?; public var uptimeSec: Double? }
    public struct Meter: Decodable, Hashable, Sendable { public var used: Double; public var total: Double; public var unit: String }
    public var checkedAt: Date?
    public var machine: Machine
    public var cpuPercent: Double?
    public var memory: Meter?
    public var disk: Meter?
    /// `nominal` · `fair` · `serious` · `critical` (ProcessInfo.thermalState).
    public var thermal: String?
    public var power: String?
    public var network: [String: String]?
    public var server: [String: String]?
    public var summary: String?
}

// MARK: server-drawn screens (R9)

public struct BlocksView: Decodable, Sendable {
    public struct Row: Decodable, Hashable, Sendable {
        public var title: String
        public var detail: String?
        public var trailing: String?
        /// §34: when present, tapping the row sends this sentence to the main chat (like an `ask` block).
        public var message: String?
        public init(title: String, detail: String? = nil, trailing: String? = nil, message: String? = nil) {
            self.title = title; self.detail = detail; self.trailing = trailing; self.message = message
        }
        /// The sentence to send, or nil when the row is not tappable (missing or only spaces).
        public var tapMessage: String? {
            guard let m = message?.trimmingCharacters(in: .whitespacesAndNewlines), !m.isEmpty else { return nil }
            return m
        }
    }
    public struct Block: Decodable, Hashable, Sendable {
        /// `text` · `stat` · `list` · `note` · `ask` (a button that sends `message` to the main chat)
        public var kind: String
        public var title: String?
        public var text: String?
        public var value: String?
        public var rows: [Row]?
        public var message: String?
    }
    public var title: String
    public var blocks: [Block]
}

// MARK: autonomy (R11)

/// Standing rules: things the assistant now does without asking.
public struct AutonomyView: Decodable, Sendable {
    public struct Rule: Decodable, Hashable, Sendable, Identifiable {
        public var id: String
        public var label: String
        public var detail: String?
        public var since: Date?
        public var uses: Int?
    }
    public var rules: [Rule]
    /// Plain words on what never runs without asking (sending to new people, payments over the limit, deleting…).
    public var alwaysAsk: [String]?
}

// MARK: model tiers and purposes (R12)

public struct ModelTiersView: Decodable, Sendable {
    public struct Model: Decodable, Hashable, Sendable, Identifiable {
        public var id: String
        public var label: String
        public var provider: String
        public var note: String?
        public var available: Bool?
    }
    public struct Tier: Decodable, Hashable, Sendable, Identifiable {
        public var id: String
        public var label: String
        public var summary: String?
        /// Best first; the assistant tries them in this order.
        public var models: [Model]
    }
    public struct Purpose: Decodable, Hashable, Sendable, Identifiable {
        public var id: String
        public var label: String
        public var detail: String?
        public var tier: String
        public var calls7d: Int?
    }
    public struct Change: Decodable, Hashable, Sendable, Identifiable {
        public var id: String { text }
        public var text: String
        public var at: Date?
    }
    public var tiers: [Tier]
    public var purposes: [Purpose]
    /// What the assistant changed lately (new models, rebalancing by token usage), in plain words.
    public var changes: [Change]?
    public var changedAt: Date?
}

// MARK: routines (§17)

public struct RoutinesView: Decodable, Sendable {
    public struct Routine: Decodable, Hashable, Sendable, Identifiable {
        public var id: String
        public var title: String
        public var instruction: String?
        public var scheduleLabel: String?
        public var bot: Author?
        public var enabled: Bool
        public var lastRun: Date?
        public var lastResult: String?
        public var lastOk: Bool?
    }
    public struct FollowUp: Decodable, Hashable, Sendable, Identifiable {
        public var id: String { (bot?.id ?? "") + what }
        public var bot: Author?
        public var what: String
        public var dueAt: Date?
    }
    public var routines: [Routine]
    public var followUps: [FollowUp]?
    public var limit: Int?
}

// MARK: channels (§7.2, ax-hq)

public struct ChannelsView: Decodable, Sendable {
    public struct Channel: Decodable, Hashable, Sendable, Identifiable {
        public var id: String
        public var label: String
        public var kind: String?
        public var group: String?
        /// false = the owner can only read this room (결재·브리핑·장애·로그 …); no input box.
        public var writable: Bool?
        public var lastSeq: Int?
        public var count: Int?
        /// §21.2: who speaks for the room.
        public var lead: Author?
    }
    public var channels: [Channel]
}

// MARK: knowledge (ax-hq §7: documents that build up from conversations, grouped by area)

public struct KnowledgeView: Decodable, Sendable {
    public struct Doc: Decodable, Hashable, Sendable, Identifiable {
        public var id: String
        public var title: String
        public var summary: String?
        public var updatedAt: Date?
    }
    public struct Area: Decodable, Hashable, Sendable, Identifiable {
        public var id: String
        public var label: String
        public var summary: String?
        public var docs: [Doc]
    }
    public var areas: [Area]

    /// Newest first across every area (a document can sit in more than one area; shown once).
    public func recent(_ limit: Int) -> [Doc] {
        var seen = Set<String>()
        let all = areas.flatMap(\.docs).filter { seen.insert($0.id).inserted }
        return Array(all.sorted { ($0.updatedAt ?? .distantPast) > ($1.updatedAt ?? .distantPast) }.prefix(limit))
    }
}

/// §21.6 `GET views/knowledge?q=`: the Mac's own search through every document.
public struct KnowledgeSearchView: Decodable, Sendable {
    public struct Result: Decodable, Hashable, Sendable, Identifiable {
        public var id: String
        public var title: String
        public var area: String?
        public var areaLabel: String?
        public var updatedAt: Date?
        public var snippet: String?
    }
    public var total: Int?
    public var results: [Result]?
}

// MARK: health (ax-hq §7: safe checks only, like `ax doctor`)

public struct HealthView: Decodable, Sendable {
    public struct Check: Decodable, Hashable, Sendable, Identifiable {
        public var id: String
        public var label: String
        /// `ok` · `warn` · `error` (`fail` is read as `error`; anything else is shown as unknown).
        public var status: String
        public var detail: String?
        /// ax-hq: what the check belongs to ("기본", "QA" …).
        public var group: String?

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = try c.decode(String.self, forKey: .id)
            // Command output arrives with column padding ("node    v24"): one space is enough.
            label = (try c.decode(String.self, forKey: .label)).replacingOccurrences(of: #"\s{2,}"#, with: " ", options: .regularExpression)
            let raw = (try? c.decode(String.self, forKey: .status)) ?? "unknown"
            status = raw == "fail" || raw == "failed" ? "error" : raw
            let d = try c.decodeIfPresent(String.self, forKey: .detail)?.trimmingCharacters(in: .whitespacesAndNewlines)
            detail = d?.isEmpty == false ? d : nil
            group = try c.decodeIfPresent(String.self, forKey: .group)
        }
        private enum CodingKeys: String, CodingKey { case id, label, status, detail, group }
    }
    public var checkedAt: Date?
    /// A sentence from the Mac; ax-hq sends counts (`{ok, warn, fail}`) instead, which the screen works out itself.
    public var summary: String?
    public var checks: [Check]

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        checkedAt = try? c.decodeIfPresent(Date.self, forKey: .checkedAt)
        summary = try? c.decodeIfPresent(String.self, forKey: .summary)
        checks = try c.decode([Check].self, forKey: .checks)
    }
    private enum CodingKeys: String, CodingKey { case checkedAt, summary, checks }
}

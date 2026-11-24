import Foundation

// §28 `work` (read-only): long jobs the assistant runs in the background — dev jobs, browser errands, life errands —
// and the ones that finished lately. Results also arrive as `notice` with a `kind` (dev.job, browser.task, …).

public struct WorkView: Decodable, Sendable {
    public var title: String?
    public var message: String?
    public var active: [WorkItem]
    public var recent: [WorkItem]

    enum CodingKeys: String, CodingKey { case title, message, active, recent }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        title = try c.decodeIfPresent(String.self, forKey: .title)
        message = try c.decodeIfPresent(String.self, forKey: .message)
        // One odd item must not hide the whole list.
        active = (try? c.decode([Lossy<WorkItem>].self, forKey: .active))?.compactMap(\.value) ?? []
        recent = (try? c.decode([Lossy<WorkItem>].self, forKey: .recent))?.compactMap(\.value) ?? []
    }
    public init(active: [WorkItem] = [], recent: [WorkItem] = []) { self.active = active; self.recent = recent }
}

/// Decodes what it can; a broken element becomes nil instead of failing the whole list.
struct Lossy<T: Decodable>: Decodable {
    var value: T?
    init(from decoder: Decoder) throws { value = try? T(from: decoder) }
}

public struct WorkItem: Decodable, Hashable, Sendable, Identifiable {
    public struct Origin: Decodable, Hashable, Sendable {
        public var channelId: String?
        public var address: String?
        public init(channelId: String? = nil, address: String? = nil) { self.channelId = channelId; self.address = address }
    }
    public var id: String
    /// `dev` · `browser` · `errand` today; unknown kinds are shown as they are.
    public var kind: String?
    public var title: String
    /// `queued` · `running` · `waiting` · `done` · `failed` · `interrupted` (unknown ones shown plainly).
    public var status: String
    /// Plain words for the step ("테스트 중").
    public var phase: String?
    /// Only after it finished. May contain text read from a web page: shown as text, never as a link or command.
    public var summary: String?
    /// Page address, branch or PR address (after it finished).
    public var link: String?
    public var startedAt: Date?
    public var updatedAt: Date?
    public var elapsedMinutes: Int?
    public var origin: Origin?
    /// §31: the `id` of the job that handed this one out (drawn indented under it).
    public var parent: String?

    public init(id: String, kind: String? = nil, title: String, status: String, phase: String? = nil, summary: String? = nil,
                link: String? = nil, elapsedMinutes: Int? = nil, parent: String? = nil, origin: Origin? = nil) {
        self.id = id; self.kind = kind; self.title = title; self.status = status; self.phase = phase; self.summary = summary
        self.link = link; self.elapsedMinutes = elapsedMinutes; self.parent = parent; self.origin = origin
    }

    /// §31 "열기": the room to open. "" is the main conversation (`owner`), `bot:<id>` is that bot's room.
    /// nil when the job says nothing about where it came from, or the bot is unknown here.
    public func room(bots: BotsView?) -> String? {
        guard let address = origin?.address, !address.isEmpty else { return nil }
        if address == "owner" { return "" }
        if address.hasPrefix("bot:") {
            let id = String(address.dropFirst(4))
            guard !id.isEmpty else { return nil }
            // Bots not read yet: the bot's room id is its id on the Mac (that is how channels are named).
            guard let bots else { return id }
            return bots.bot(id: id)?.channel
        }
        return nil
    }

    public var kindWords: String {
        switch kind {
        case "dev": "개발 작업"
        case "browser": "브라우저 심부름"
        case "errand": "심부름"
        case "bot": "봇에게 맡긴 일"
        case let other?: other
        case nil: "일"
        }
    }

    public var statusWords: String {
        switch status {
        case "queued": "차례 기다리는 중"
        case "running": "하는 중"
        case "waiting": "직접 하실 단계에서 멈춤"
        case "done": "끝남"
        case "failed": "못 끝냄"
        case "interrupted": "중간에 멈춤"
        default: status
        }
    }

    public var isActive: Bool { ["queued", "running", "waiting"].contains(status) }

    /// "12분째" / "1시간 5분 걸림".
    public var elapsedWords: String? {
        guard let m = elapsedMinutes, m >= 0 else { return nil }
        let text = m < 1 ? "1분 안" : m < 60 ? "\(m)분" : m % 60 == 0 ? "\(m / 60)시간" : "\(m / 60)시간 \(m % 60)분"
        return isActive ? (m < 1 ? "방금 시작" : text + "째") : text + " 걸림"
    }

    /// The link, only when it is a web address the phone can open (a branch name stays text).
    public var webLink: URL? {
        guard let link, let url = URL(string: link), url.scheme == "https" else { return nil }
        return url
    }
}

/// §31 work sheet: what is running (with sub-jobs indented under the job that handed them out) and a few that
/// finished lately.
public enum WorkSheet {
    public struct Row: Hashable, Sendable, Identifiable {
        public var item: WorkItem
        public var depth: Int
        public var id: String { item.id }
    }

    /// Running jobs first. A finished parent whose sub-jobs still run stays up there (open), above them.
    public static func active(_ work: WorkView) -> [Row] {
        let recentById = Dictionary(work.recent.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var items = work.active
        var ids = Set(items.map(\.id))
        // Hold open the finished ancestors of anything still running.
        for item in work.active {
            var parent = item.parent
            var guardCount = 0
            while let p = parent, !ids.contains(p), let held = recentById[p], guardCount < 20 {
                items.append(held); ids.insert(p); parent = held.parent; guardCount += 1
            }
        }
        return tree(items, order: work.active.map(\.id))
    }

    /// The last few finished jobs not already shown above (each with its finished sub-jobs under it).
    public static func recent(_ work: WorkView, limit: Int = 5) -> [Row] {
        let shown = Set(active(work).map(\.id))
        let rest = work.recent.filter { !shown.contains($0.id) }
        let restIds = Set(rest.map(\.id))
        let roots = rest.filter { $0.parent.map { !restIds.contains($0) } ?? true }.prefix(limit)
        let keep = Set(roots.map(\.id))
        var items = Array(roots)
        // Children of kept roots (any depth).
        var added = true
        var kept = keep
        while added {
            added = false
            for item in rest where !kept.contains(item.id) {
                if let p = item.parent, kept.contains(p) { items.append(item); kept.insert(item.id); added = true }
            }
        }
        return tree(items, order: rest.map(\.id))
    }

    /// Orders items as a tree: roots in `order`, a held parent where its first child would be, children right under.
    static func tree(_ items: [WorkItem], order: [String]) -> [Row] {
        let ids = Set(items.map(\.id))
        var children: [String: [WorkItem]] = [:]
        var roots: [WorkItem] = []
        let rank = Dictionary(order.enumerated().map { ($1, $0) }, uniquingKeysWith: { a, _ in a })
        func position(_ item: WorkItem) -> Int {
            if let r = rank[item.id] { return r }
            // A held parent: as early as its earliest child.
            return items.filter { $0.parent == item.id }.map(position).min() ?? Int.max
        }
        for item in items {
            if let p = item.parent, p != item.id, ids.contains(p) { children[p, default: []].append(item) } else { roots.append(item) }
        }
        var rows: [Row] = []
        var seen = Set<String>()
        func walk(_ item: WorkItem, _ depth: Int) {
            guard seen.insert(item.id).inserted else { return }
            rows.append(Row(item: item, depth: min(depth, 3)))
            for child in (children[item.id] ?? []).sorted(by: { position($0) < position($1) }) { walk(child, depth + 1) }
        }
        for root in roots.sorted(by: { position($0) < position($1) }) { walk(root, 0) }
        // Anything caught in a parent loop still shows, at the top level.
        for item in items where !seen.contains(item.id) { walk(item, 0) }
        return rows
    }

    /// The folded line above the chat box: "하는 중 2개 · 맨 위 항목". nil when nothing runs.
    public static func strip(_ work: WorkView) -> String? {
        guard let first = work.active.first else { return nil }
        return "하는 중 \(work.active.count)개 · \(first.title)"
    }
}

/// Notice kinds that come from §28 work (results of long jobs).
public enum WorkNotice {
    public static func label(_ kind: String?) -> String? {
        switch kind {
        case "dev.job": "개발 작업 결과"
        case "browser.task": "브라우저 심부름 결과"
        case "errands.task": "심부름 결과"
        case "work.interrupted": "멈춘 일"
        default: nil
        }
    }

    /// "밤사이 소식 N건": several notices folded into one, drawn as a list.
    public static let overnight = "overnight"

    /// "시작했어요. 끝나면 알려드릴게요. (작업 <id>)" — the assistant's reply when a long job went to the background.
    public static func startsJob(_ text: String) -> Bool {
        text.range(of: #"\(작업 [A-Za-z0-9:_.\-]+\)"#, options: .regularExpression) != nil
            || (text.contains("그다음 순서로 해 둘게요"))
    }

    /// Overnight digest: a heading line and one line per item ("· …", "- …", "1. …").
    public static func digest(_ text: String) -> (title: String, lines: [String]) {
        var lines = text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let title = lines.first.map { $0.hasPrefix("·") || $0.hasPrefix("-") ? "밤사이 소식" : $0 } ?? "밤사이 소식"
        if let first = lines.first, !(first.hasPrefix("·") || first.hasPrefix("-")) { lines.removeFirst() }
        let items = lines.map { line -> String in
            var l = Substring(line)
            if l.hasPrefix("·") || l.hasPrefix("-") || l.hasPrefix("•") { l = l.dropFirst() }
            else if let r = l.range(of: #"^\d+[.)]"#, options: .regularExpression) { l = l[r.upperBound...] }
            return l.trimmingCharacters(in: .whitespaces)
        }
        return (title, items)
    }
}

public extension APIClient {
    func work() async throws -> WorkView { try await view(WorkView.self, "work") }
}

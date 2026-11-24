import Foundation

/// A room laid out like a group chat: who said it, consecutive lines from one speaker grouped, day separators,
/// replies folded under what they answer, long runs of bot-to-bot talk or work logs folded into one line.
/// Pure value logic so it is tested once and every room looks the same.
public enum RoomFeed {
    public struct Speaker: Hashable, Sendable {
        public var id: String
        public var name: String
        public var avatar: String?
        public var isOwner: Bool
        public init(id: String, name: String, avatar: String? = nil, isOwner: Bool = false) {
            self.id = id; self.name = name; self.avatar = avatar; self.isOwner = isOwner
        }
        public static let owner = Speaker(id: "owner", name: "나", isOwner: true)
    }

    public struct Entry: Hashable, Sendable, Identifiable {
        public var id: Int { seq }
        public var seq: Int
        public var at: Date
        public var speaker: Speaker
        /// Who a bot was talking to.
        public var to: String?
        /// "검토 요청", "질문", "답 (승인)" … from bot talk.
        public var label: String?
        /// Cleaned, ready to draw.
        public var text: String
        /// A work log line (a team's notice with no author): drawn quieter.
        public var isStatus = false
        public var isReply = false
        /// First line of a run from the same speaker: show the face and name.
        public var showHeader = true
        /// The same line sent again right after (shown once with "×2").
        public var repeats = 1
        /// The assistant's own notice in the main room (briefing, important mail, "알아서 했어요"): a bubble with an 알림 chip.
        public var isNotice = false
        public var replies: [Entry] = []
        public var source: Timeline.Item
        /// §21.3: the work thread this line belongs to; the thread's title on its first line.
        public var thread: String? = nil
        public var threadTitle: String? = nil
    }

    public struct Folded: Hashable, Sendable, Identifiable {
        public var id: String
        public var title: String
        public var names: [String]
        public var entries: [Entry]
    }

    public enum Row: Hashable, Sendable, Identifiable {
        case day(String)
        case entry(Entry)
        case folded(Folded)
        /// Cards, delegations and the main room's notices: drawn as they always were.
        case system(Timeline.Item)

        public var id: String {
            switch self {
            case .day(let label): "d-\(label)"
            case .entry(let e): "e-\(e.seq)"
            case .folded(let f): f.id
            case .system(let item): "s-\(item.seq)"
            }
        }
    }

    /// - Parameters:
    ///   - lead: who speaks for the room when a line has no author (the team lead, or the room's name).
    ///   - assistant: the assistant's name (main room).
    public static func build(_ items: [Timeline.Item], room: String, lead: Speaker?, assistant: String,
                             cardDates: [String: Date] = [:], now: Date = Date(), zone: TimeZone = Format.seoul, foldAt: Int = 4) -> [Row] {
        // 1. Every item → an entry (someone said something) or a system row.
        enum Unit { case entry(Entry); case system(Timeline.Item) }
        var units: [Unit] = []
        let roomVoice = lead ?? Speaker(id: room, name: assistant)

        func botSpeaker(_ author: Author?) -> Speaker {
            if let author { return Speaker(id: author.id, name: author.name, avatar: author.avatar) }
            return room.isEmpty ? Speaker(id: "assistant", name: assistant) : roomVoice
        }

        for item in items {
            switch item {
            case .message(let m):
                if m.role == .owner {
                    units.append(.entry(Entry(seq: m.seq, at: m.at, speaker: .owner, text: ChatText.clean(m.text), source: item)))
                } else if m.author == nil, let talk = BotTalk.parse(m.text) {
                    units.append(.entry(entry(talk, seq: m.seq, at: m.at, item: item)))
                } else {
                    units.append(.entry(Entry(seq: m.seq, at: m.at, speaker: botSpeaker(m.author), to: m.to?.name,
                                              text: ChatText.clean(m.text), source: item)))
                }
            case .notice(let n):
                if let talk = BotTalk.parse(n.text) {
                    units.append(.entry(entry(talk, seq: n.seq, at: n.at, item: item)))
                } else if let author = n.author {
                    units.append(.entry(Entry(seq: n.seq, at: n.at, speaker: botSpeaker(author), text: ChatText.clean(n.text), source: item)))
                } else if !room.isEmpty {
                    units.append(.entry(Entry(seq: n.seq, at: n.at, speaker: roomVoice, text: ChatText.clean(n.text), isStatus: true, source: item)))
                } else {
                    // The assistant speaking first in the main room: its words, in its bubble — not a grey footnote.
                    var e = Entry(seq: n.seq, at: n.at, speaker: Speaker(id: "assistant", name: assistant), text: ChatText.clean(n.text), source: item)
                    e.isNotice = true
                    units.append(.entry(e))
                }
            case .card, .delegation:
                units.append(.system(item))
            }
        }

        // Threads (§21.3) from the event itself.
        units = units.map { unit in
            guard case .entry(var e) = unit else { return unit }
            let t: EventThread? = switch e.source {
            case .message(let m): m.thread
            case .notice(let n): n.thread
            default: nil
            }
            e.thread = t?.id
            e.threadTitle = t?.title
            return .entry(e)
        }

        // 2. A thread's later lines fold under its first line; replies fold under the line they answer (A → B, then B → A).
        var merged: [Unit] = []
        var threadRoot: [String: Int] = [:]
        for unit in units {
            if case .entry(let e) = unit, let t = e.thread {
                if let i = threadRoot[t], case .entry(var root) = merged[i] {
                    root.replies.append(e)
                    merged[i] = .entry(root)
                } else {
                    threadRoot[t] = merged.count
                    merged.append(unit)
                }
                continue
            }
            guard case .entry(let e) = unit, e.isReply, let to = e.to else { merged.append(unit); continue }
            let target = merged.indices.reversed().prefix(40).first { i in
                if case .entry(let root) = merged[i] { return root.speaker.name == to && root.to == e.speaker.name && !root.isReply }
                return false
            }
            if let i = target, case .entry(var root) = merged[i] {
                root.replies.append(e)
                merged[i] = .entry(root)
            } else {
                merged.append(unit)
            }
        }

        // 3. The same line again right after → one line "×2" (bots only: the owner's own lines always show, each one,
        //    or a message sent twice looks lost). Empty lines (all cleaned away) disappear.
        var deduped: [Unit] = []
        for unit in merged {
            if case .entry(let e) = unit {
                if e.text.isEmpty && !hasMedia(e.source) { continue }
                if case .entry(var last) = deduped.last, !e.speaker.isOwner, last.speaker == e.speaker, last.text == e.text, e.replies.isEmpty {
                    last.repeats += 1
                    deduped[deduped.count - 1] = .entry(last)
                    continue
                }
            }
            deduped.append(unit)
        }

        // 4. Long runs of work logs or bot-to-bot talk fold, keeping the newest two in view.
        enum Piece { case unit(Unit); case folded(Folded) }
        var pieces: [Piece] = []
        var run: [Entry] = []
        var runKind: Int? = nil // 1 = status, 2 = talk
        // 1 = work log, 2 = bot-to-bot talk, 3 = many lines in a row from one bot (a team lead's progress, §21.1)
        var runSpeaker: Speaker?
        func kind(_ e: Entry) -> Int? {
            if e.isStatus { return 1 }
            if e.to != nil && !e.speaker.isOwner { return 2 }
            if !room.isEmpty && !e.speaker.isOwner && e.replies.isEmpty { return 3 }
            return nil
        }
        func flush() {
            defer { run = []; runKind = nil }
            guard !run.isEmpty else { return }
            let need = runKind == 3 ? foldAt + 2 : foldAt
            if run.count >= need {
                let hidden = Array(run.dropLast(2))
                var names: [String] = []
                for e in hidden { for n in [e.speaker.name] + (e.to.map { [$0] } ?? []) where !names.contains(n) { names.append(n) } }
                let title = runKind == 1
                    ? "이전 작업 기록 \(hidden.count)개"
                    : runKind == 3 ? "\(hidden[0].speaker.name)의 이전 글 \(hidden.count)개"
                    : "\(names.prefix(3).joined(separator: "·"))\(names.count > 3 ? " 외 \(names.count - 3)명" : "")의 대화 \(hidden.count + hidden.reduce(0) { $0 + $1.replies.count })개"
                pieces.append(.folded(Folded(id: "f-\(hidden[0].seq)", title: title, names: names, entries: hidden)))
                for e in run.suffix(2) { pieces.append(.unit(.entry(e))) }
            } else {
                for e in run { pieces.append(.unit(.entry(e))) }
            }
        }
        for unit in deduped {
            if case .entry(let e) = unit, let k = kind(e) {
                if runKind != k || (k == 3 && runSpeaker != e.speaker) { flush(); runKind = k; runSpeaker = e.speaker }
                run.append(e)
            } else {
                flush()
                pieces.append(.unit(unit))
            }
        }
        flush()

        // 5. Day lines and faces: a header only when the speaker changes, 10 minutes pass, or a day line sits between.
        var rows: [Row] = []
        var lastDay: String?
        var lastEntry: Entry?
        var lastAt: Date?
        for piece in pieces {
            let at: Date
            switch piece {
            case .folded(let f): at = f.entries[0].at
            case .unit(.entry(let e)): at = e.at
            case .unit(.system(let item)): at = date(of: item, cardDates) ?? lastAt ?? now
            }
            lastAt = at
            let day = Format.dayLine(at, now: now, zone: zone)
            if day != lastDay {
                rows.append(.day(day))
                lastDay = day
                lastEntry = nil
            }
            switch piece {
            case .folded(let f):
                rows.append(.folded(f))
                lastEntry = nil
            case .unit(.system(let item)):
                rows.append(.system(item))
                lastEntry = nil
            case .unit(.entry(var e)):
                if let prev = lastEntry, prev.speaker == e.speaker, prev.to == e.to, e.at.timeIntervalSince(prev.at) < 600 { e.showHeader = false }
                rows.append(.entry(e))
                lastEntry = e
            }
        }
        return rows
    }

    private static func entry(_ talk: BotTalk, seq: Int, at: Date, item: Timeline.Item) -> Entry {
        Entry(seq: seq, at: at, speaker: Speaker(id: "bot:" + talk.from, name: talk.from), to: talk.to, label: talk.label,
              text: ChatText.clean(talk.text), isReply: talk.isReply, source: item)
    }

    private static func hasMedia(_ item: Timeline.Item) -> Bool {
        if case .message(let m) = item { return !(m.attachments ?? []).isEmpty || m.imageUrl != nil }
        if case .notice(let n) = item { return !(n.attachments ?? []).isEmpty }
        return false
    }

    private static func date(of item: Timeline.Item, _ cardDates: [String: Date]) -> Date? {
        switch item {
        case .message(let e): e.at
        case .notice(let e): e.at
        case .delegation(let e): e.at
        case .card(let id, _): cardDates[id]
        }
    }
}

public extension Timeline.Item {
    /// A line a 👍/👎 can go under: something said, not a card or a hand-off.
    var reactable: Bool {
        switch self {
        case .message(let m): m.role != .owner
        case .notice: true
        default: false
        }
    }
}

import Foundation

/// §31 (with the work sheet): typing "@" in the chat box offers the bots by name; picking one puts "@이름 " in the box.
/// The Mac reads "@이름" (spaces ignored) and hands the request to that bot.
public enum Mentions {
    /// What the owner is typing after a trailing "@" (at the start or after a space), or nil when not typing a mention.
    public static func query(in text: String) -> String? {
        guard let at = text.lastIndex(of: "@") else { return nil }
        if at != text.startIndex, !text[text.index(before: at)].isWhitespace { return nil }
        let typed = text[text.index(after: at)...]
        guard typed.count <= 20, !typed.contains(where: \.isWhitespace) else { return nil }
        return String(typed)
    }

    /// Bots to offer for `query`: names (or ids) starting with it first, then containing it. Bots that are off are left out.
    public static func candidates(_ bots: [BotsView.Bot], query: String, limit: Int = 6) -> [BotsView.Bot] {
        func squeeze(_ s: String) -> String { s.lowercased().filter { !$0.isWhitespace } }
        let q = squeeze(query)
        var seen = Set<String>()
        let live = bots.filter { $0.status != "off" && seen.insert($0.id).inserted }
        guard !q.isEmpty else { return Array(live.prefix(limit)) }
        let starts = live.filter { squeeze($0.name).hasPrefix(q) || squeeze($0.id).hasPrefix(q) }
        let contains = live.filter { b in !starts.contains(b) && (squeeze(b.name).contains(q) || squeeze(b.id).contains(q)) }
        return Array((starts + contains).prefix(limit))
    }

    /// Replaces the "@…" being typed with "@이름 ".
    public static func insert(_ name: String, into text: String) -> String {
        guard query(in: text) != nil, let at = text.lastIndex(of: "@") else { return text + "@\(name) " }
        return String(text[..<at]) + "@\(name) "
    }
}

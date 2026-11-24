import Foundation

/// Cleans what the Mac sends before it is shown, so leftovers from Discord, logs and prompts never reach the screen
/// even when the server has not caught up: mentions, emoji codes, internal ids, `key: value` metadata, prompt blocks.
public enum ChatText {
    /// Text for a chat bubble or a list line (keeps inline markdown, turns block markdown into plain lines).
    /// Cleaned once per text: a room redraws often and the same lines come back every time.
    public static func clean(_ raw: String, zone: TimeZone = Format.seoul) -> String {
        if raw.isEmpty { return "" }
        let key = zone.identifier + "\u{1}" + raw as NSString
        if let hit = cleanCache.object(forKey: key) { return hit as String }
        let text = cleanUncached(raw, zone: zone)
        cleanCache.setObject(text as NSString, forKey: key)
        return text
    }

    private static let cleanCache: NSCache<NSString, NSString> = { let c = NSCache<NSString, NSString>(); c.countLimit = 6000; return c }()
    private static let previewCache: NSCache<NSString, NSString> = { let c = NSCache<NSString, NSString>(); c.countLimit = 3000; return c }()

    static func cleanUncached(_ raw: String, zone: TimeZone) -> String {
        var text = raw.replacingOccurrences(of: "\r\n", with: "\n")
        text = dropPromptBlocks(text)
        text = cutMetadata(text)
        text = discord(text, zone: zone)
        text = plainLines(text)
        text = dropInternalIds(text)
        text = glossary(text)
        // Addresses read as written ("…/__없는-주소"), not as %EC%97….
        text = replace(text, #"https?://[^\s\]\)]+"#) { g in g[0].contains("%") ? (g[0].removingPercentEncoding ?? g[0]) : g[0] }
        text = text.replacingOccurrences(of: #"(?<=\S)[ \t]{2,}"#, with: " ", options: .regularExpression)
        // At most one empty line in a row, nothing dangling at the ends.
        text = text.replacingOccurrences(of: #"\n{3,}"#, with: "\n\n", options: .regularExpression)
        text = text.replacingOccurrences(of: #"[ \t]+\n"#, with: "\n", options: .regularExpression)
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// One line for a list: cleaned, markdown marks removed, newlines folded.
    public static func preview(_ raw: String, limit: Int = 120) -> String {
        let key = "\(limit)\u{1}" + raw as NSString
        if let hit = previewCache.object(forKey: key) { return hit as String }
        let text = previewUncached(raw, limit: limit)
        previewCache.setObject(text as NSString, forKey: key)
        return text
    }

    private static func previewUncached(_ raw: String, limit: Int) -> String {
        var text = clean(raw)
        text = text.replacingOccurrences(of: #"\*\*|__|`"#, with: "", options: .regularExpression)
        text = text.replacingOccurrences(of: #"\[([^\]]+)\]\([^)]+\)"#, with: "$1", options: .regularExpression)
        text = text.replacingOccurrences(of: #"^[•\-]\s+"#, with: "", options: [.regularExpression])
        text = text.replacingOccurrences(of: #"\s*\n+\s*[•\-]?\s*"#, with: " · ", options: .regularExpression)
        text = text.trimmingCharacters(in: .whitespaces)
        if text.count > limit { text = String(text.prefix(limit - 1)) + "…" }
        return text
    }

    /// A card summary that is only metadata ("eventId: 8648") is useless as a title: use the note's first sentence.
    public static func cardTitle(summary: String, note: String?) -> String {
        let s = clean(summary)
        if !s.isEmpty, !isMetadataLine(s) { return s }
        let n = clean(note ?? "")
        let first = n.split(separator: "\n").first.map(String.init) ?? ""
        return first.isEmpty ? "확인이 필요한 일" : first
    }

    // MARK: pieces

    /// `<knowledge_x> … </knowledge_x>` and similar prompt context the model should never have shown.
    static func dropPromptBlocks(_ text: String) -> String {
        var t = text.replacingOccurrences(of: #"(?s)<([a-z][a-z0-9_]*)>.*?</\1>"#, with: "", options: .regularExpression)
        // An unclosed block runs to the end.
        t = t.replacingOccurrences(of: #"(?s)\n?<[a-z][a-z0-9_]*_[a-z0-9_]*>.*$"#, with: "", options: .regularExpression)
        // "허용 action과 params_json 형식 …" style tool lists.
        if let r = t.range(of: #"(?m)^.*params_json.*$"#, options: .regularExpression) { t = String(t[..<r.lowerBound]) }
        return t
    }

    static func isMetadataLine(_ line: String) -> Bool {
        line.range(of: #"^[a-zA-Z][a-zA-Z0-9_]{1,24}: \S"#, options: .regularExpression) != nil
    }

    /// Everything from the first run of two or more `key: value` lines (eventId, source, received …) is raw context.
    static func cutMetadata(_ text: String) -> String {
        let lines = text.components(separatedBy: "\n")
        var i = 0
        while i < lines.count - 1 {
            if isMetadataLine(lines[i]), isMetadataLine(lines[i + 1]) {
                return lines[..<i].joined(separator: "\n")
            }
            i += 1
        }
        // A single dangling metadata line at the end ("eventId: 8648").
        if let last = lines.last, lines.count > 1, isMetadataLine(last) { return lines.dropLast().joined(separator: "\n") }
        return text
    }

    static let shortcodes: [String: String] = [
        "white_check_mark": "✅", "heavy_check_mark": "✔️", "x": "❌", "warning": "⚠️", "rotating_light": "🚨", "tada": "🎉",
        "eyes": "👀", "memo": "📝", "thumbsup": "👍", "+1": "👍", "thumbsdown": "👎", "-1": "👎", "fire": "🔥", "bulb": "💡",
        "hammer_and_wrench": "🛠️", "tools": "🛠️", "gear": "⚙️", "lock": "🔒", "bell": "🔔", "calendar": "📅", "pushpin": "📌",
        "red_circle": "🔴", "green_circle": "🟢", "yellow_circle": "🟡", "orange_circle": "🟠", "large_blue_circle": "🔵",
        "information_source": "ℹ️", "no_entry": "⛔", "stop_sign": "🛑", "rocket": "🚀", "speech_balloon": "💬", "art": "🎨",
        "test_tube": "🧪", "shield": "🛡️", "money_with_wings": "💸", "moneybag": "💰", "clipboard": "📋", "mag": "🔍",
        "hourglass": "⌛", "zzz": "💤", "wave": "👋", "pray": "🙏", "sparkles": "✨", "star": "⭐", "heart": "❤️",
    ]

    /// Discord leftovers: `<@123>`, `<#123>`, `<@&123>`, `<:name:123>`, `<t:1700000000:R>`, `:emoji:`, `||spoiler||`, `-# `.
    static func discord(_ text: String, zone: TimeZone) -> String {
        var t = text
        t = t.replacingOccurrences(of: #"<@[!&]?\d+>\s?"#, with: "", options: .regularExpression)
        t = t.replacingOccurrences(of: #"<#\d+>"#, with: "", options: .regularExpression)
        t = t.replacingOccurrences(of: #"<a?:\w+:\d+>"#, with: "", options: .regularExpression)
        t = replace(t, #"<t:(\d{9,11})(?::[a-zA-Z])?>"#) { groups in
            guard let secs = Double(groups[1]) else { return "" }
            let date = Date(timeIntervalSince1970: secs)
            return "\(Format.monthDay(date, zone: zone)) \(Format.clock(date, zone: zone))"
        }
        t = replace(t, #"(?<![\w:/]):([a-z0-9_+\-]{2,30}):(?![\w/])"#) { groups in shortcodes[groups[1]] ?? "" }
        t = t.replacingOccurrences(of: #"\|\|(.+?)\|\|"#, with: "$1", options: .regularExpression)
        t = t.replacingOccurrences(of: #"(?m)^-# "#, with: "", options: .regularExpression)
        // The owner's channels are gone from the app: "→ #결재" means the 결재 tab.
        t = t.replacingOccurrences(of: "#결재", with: "결재 탭")
        // Other Discord channel names ("#일상에 알림") are rooms in plain words.
        t = t.replacingOccurrences(of: #"(?<![\w#&])#([가-힣]{1,8}?)(?=(?:에서|으로|에|을|를|이|가|은|는|의|로)?(?:[\s,.)!?]|$))"#, with: "$1 방", options: .regularExpression)
        t = t.replacingOccurrences(of: "방 방", with: "방")
        return t
    }

    /// Block markdown the chat bubble cannot draw: headings → bold line, quotes → plain, code fences → gone, `- ` → `• `.
    static func plainLines(_ text: String) -> String {
        var out: [String] = []
        for raw in text.components(separatedBy: "\n") {
            var line = raw
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("```") { continue }
            if let m = line.firstMatch(of: #/^\s{0,3}#{1,6}\s+(.*)$/#) {
                let body = String(m.1).trimmingCharacters(in: .whitespaces)
                line = body.isEmpty ? "" : (body.hasPrefix("**") ? body : "**\(body)**")
            } else if let m = line.firstMatch(of: #/^\s{0,3}>\s?(.*)$/#) {
                line = String(m.1)
            } else if let m = line.firstMatch(of: #/^(\s*)[-*]\s+(.*)$/#) {
                line = String(m.1) + "• " + String(m.2)
            } else if line.range(of: #"^\s*([-*_]\s*){3,}$"#, options: .regularExpression) != nil {
                continue
            }
            out.append(line)
        }
        return out.joined(separator: "\n")
    }

    /// Branch names, run ids and hashes mean nothing to the owner: " · v2-ax-qa-web-4ac6f8339bea2b7d", "(head a614e74)".
    static func dropInternalIds(_ text: String) -> String {
        var t = text
        t = t.replacingOccurrences(of: #"\s*\((?:head|commit|작업|run|id)\s+[0-9a-f]{6,40}\)"#, with: "", options: .regularExpression)
        t = t.replacingOccurrences(of: #"\s*·\s*[A-Za-z0-9][A-Za-z0-9._/:-]*[0-9a-f]{8,}[A-Za-z0-9._/:-]*(?=\s*(·|\n|$))"#, with: "", options: .regularExpression)
        t = t.replacingOccurrences(of: #"\s*·\s*[a-z0-9-]+/[A-Za-z0-9._-]+-\d{4}-\d{2}-\d{2}(?=\s*(·|\n|$))"#, with: "", options: .regularExpression)
        return t
    }

    /// Internal English role words that slipped into sentences; the same emoji twice in a row once.
    static func glossary(_ text: String) -> String {
        var t = text
        t = t.replacingOccurrences(of: #"([\x{2600}-\x{27BF}\x{1F300}-\x{1FAFF}]\x{FE0F}?)(\s*\1)+"#, with: "$1", options: .regularExpression)
        for (en, ko) in [("Engineer", "개발 봇"), ("P0 결정", "긴급 결정")] {
            t = t.replacingOccurrences(of: #"(?<![A-Za-z])\#(en)(?![A-Za-z])"#, with: ko, options: .regularExpression)
        }
        return t
    }

    private static let regexLock = NSLock()
    nonisolated(unsafe) private static var regexes: [String: NSRegularExpression] = [:]

    /// Compiled once per pattern.
    private static func regex(_ pattern: String) -> NSRegularExpression? {
        regexLock.withLock {
            if let r = regexes[pattern] { return r }
            let r = try? NSRegularExpression(pattern: pattern)
            regexes[pattern] = r
            return r
        }
    }

    private static func replace(_ text: String, _ pattern: String, _ make: ([String]) -> String) -> String {
        guard let regex = regex(pattern) else { return text }
        let ns = text as NSString
        var result = ""
        var last = 0
        for match in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            result += ns.substring(with: NSRange(location: last, length: match.range.location - last))
            let groups = (0..<match.numberOfRanges).map { i -> String in
                let r = match.range(at: i)
                return r.location == NSNotFound ? "" : ns.substring(with: r)
            }
            result += make(groups)
            last = match.range.location + match.range.length
        }
        result += ns.substring(from: last)
        return result
    }
}

/// A bot talking to another bot, from the old notice wording ("💬 Leo → Mia · 검토 요청: …", "↩️ Mia → Leo · 답 (승인): …")
/// or from a message with `author` and `to`.
public struct BotTalk: Hashable, Sendable {
    public var from: String
    public var to: String
    /// "검토 요청", "질문", "답 (승인)" …
    public var label: String?
    public var text: String
    public var isReply: Bool

    private static let lock = NSLock()
    nonisolated(unsafe) private static var memo: [String: BotTalk?] = [:]

    /// Remembered per text: the room list and every room layout parse the same lines again (Swift Regex is slow).
    public static func parse(_ raw: String) -> BotTalk? {
        lock.lock()
        if let hit = memo[raw] { lock.unlock(); return hit }
        lock.unlock()
        let out = compute(raw)
        lock.lock()
        if memo.count >= 4000 { memo.removeAll(keepingCapacity: true) }
        memo[raw] = .some(out)
        lock.unlock()
        return out
    }

    static func compute(_ raw: String) -> BotTalk? {
        let pattern = #/^\s*(💬|↩️|↩︎|↪️)?\s*([^\s→·:]{1,20}(?: [^\s→·:]{1,20})?)\s*(?:→|->)\s*([^\s→·:]{1,20}(?: [^\s→·:]{1,20})?)\s*·\s*([^:\n]{1,24}):\s*(.+)$/#.dotMatchesNewlines()
        guard let m = raw.firstMatch(of: pattern) else { return nil }
        let mark = m.1.map(String.init) ?? ""
        let label = String(m.4).trimmingCharacters(in: .whitespaces)
        return BotTalk(from: String(m.2), to: String(m.3), label: label.isEmpty ? nil : label,
                       text: String(m.5).trimmingCharacters(in: .whitespacesAndNewlines),
                       isReply: mark.hasPrefix("↩") || label.hasPrefix("답"))
    }
}

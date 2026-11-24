import Foundation

/// Korean wording for numbers and times, kept here so it is tested once.
public enum Format {
    public static let seoul = TimeZone(identifier: "Asia/Seoul")!

    private static let formatterLock = NSLock()
    nonisolated(unsafe) private static var formatters: [String: DateFormatter] = [:]

    /// DateFormatter is slow to make; one per format, zone and locale, reused. Only used under the lock.
    private static func string(_ date: Date, format: String, zone: TimeZone, locale: String = "ko_KR") -> String {
        formatterLock.withLock {
            let key = format + "|" + zone.identifier + "|" + locale
            let f: DateFormatter
            if let saved = formatters[key] { f = saved } else {
                f = DateFormatter()
                f.calendar = Calendar(identifier: .gregorian)
                f.locale = Locale(identifier: locale)
                f.timeZone = zone
                f.dateFormat = format
                formatters[key] = f
            }
            return f.string(from: date)
        }
    }

    /// 12500 → "1만 2,500원", 980 → "980원", 1234567 → "123만 4,567원".
    public static func won(_ amount: Double) -> String {
        let negative = amount < 0
        let value = Int((abs(amount)).rounded())
        let man = value / 10_000
        let rest = value % 10_000
        let grouped = NumberFormatter()
        grouped.numberStyle = .decimal
        grouped.locale = Locale(identifier: "ko_KR")
        func g(_ n: Int) -> String { grouped.string(from: NSNumber(value: n)) ?? String(n) }
        var text: String
        if man == 0 { text = "\(g(rest))원" }
        else if rest == 0 { text = "\(g(man))만원" }
        else { text = "\(g(man))만 \(g(rest))원" }
        if negative { text = "-" + text }
        return text
    }

    public static func money(_ amount: Double, currency: String) -> String {
        if currency.uppercased() == "KRW" { return won(amount) }
        if currency.uppercased() == "USD" { return dollars(amount) }
        return String(format: "%.2f %@", amount, currency)
    }

    /// Small API costs: "$0.42", "$0.003" → "1센트 미만".
    public static func dollars(_ amount: Double) -> String {
        if amount > 0 && amount < 0.01 { return "1센트 미만" }
        return String(format: "$%.2f", amount)
    }

    /// "방금", "5분 전", "3시간 전", "어제", "11월 3일".
    public static func relative(_ date: Date, now: Date = Date(), zone: TimeZone = seoul) -> String {
        let seconds = now.timeIntervalSince(date)
        if seconds < 60 { return "방금" }
        if seconds < 3600 { return "\(Int(seconds / 60))분 전" }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        if calendar.isDate(date, inSameDayAs: now) { return "\(Int(seconds / 3600))시간 전" }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(date, inSameDayAs: yesterday) { return "어제" }
        let c = calendar.dateComponents([.month, .day], from: date)
        return "\(c.month ?? 0)월 \(c.day ?? 0)일"
    }

    /// "오후 3:20".
    public static func clock(_ date: Date, zone: TimeZone = seoul) -> String {
        string(date, format: "a h:mm", zone: zone)
    }

    /// "오후 5:45까지", "내일 오전 9:45까지", "11월 21일까지".
    public static func deadline(_ date: Date, now: Date = Date(), zone: TimeZone = seoul) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        if calendar.isDate(date, inSameDayAs: now) { return "\(clock(date, zone: zone))까지" }
        if let tomorrow = calendar.date(byAdding: .day, value: 1, to: now), calendar.isDate(date, inSameDayAs: tomorrow) {
            return "내일 \(clock(date, zone: zone))까지"
        }
        let c = calendar.dateComponents([.month, .day], from: date)
        return "\(c.month ?? 0)월 \(c.day ?? 0)일까지"
    }

    /// "11월 18일".
    public static func monthDay(_ date: Date, zone: TimeZone = seoul) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let c = calendar.dateComponents([.month, .day], from: date)
        return "\(c.month ?? 0)월 \(c.day ?? 0)일"
    }

    /// The line between days in a room: "오늘", "어제", "11월 18일 화요일", "2025년 12월 31일 수요일".
    public static func dayLine(_ date: Date, now: Date = Date(), zone: TimeZone = seoul) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        if calendar.isDate(date, inSameDayAs: now) { return "오늘" }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(date, inSameDayAs: yesterday) { return "어제" }
        let sameYear = calendar.component(.year, from: date) == calendar.component(.year, from: now)
        return string(date, format: sameYear ? "M월 d일 EEEE" : "yyyy년 M월 d일 EEEE", zone: zone)
    }

    public static func ymd(_ date: Date, zone: TimeZone = seoul) -> String {
        string(date, format: "yyyy-MM-dd", zone: zone, locale: "en_US_POSIX")
    }

    /// Subject particle by the last syllable: "개발 봇" → "개발 봇이", "비서" → "비서가".
    public static func subject(_ name: String) -> String {
        guard let last = name.unicodeScalars.last, (0xAC00...0xD7A3).contains(last.value) else { return name + "이(가)" }
        return name + ((last.value - 0xAC00) % 28 == 0 ? "가" : "이")
    }

    public static func duration(seconds: Double) -> String {
        let s = Int(seconds)
        if s < 3600 { return "\(max(s / 60, 1))분" }
        if s < 86_400 { return "\(s / 3600)시간" }
        return "\(s / 86_400)일"
    }
}

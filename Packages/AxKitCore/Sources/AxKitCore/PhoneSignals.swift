import Foundation

/// 휴대폰 신호 the app sends by itself to `POST /m/v1/ingest` (ARCHITECTURE §9.4, same token as the app):
/// `{"v":1,"ts":<sent>,"items":[{kind,…,"at":<happened>}]}`, `at` within 48 hours. Location on a real move or a
/// visit, battery when it runs low, yesterday's steps once a day. Text messages and other apps' notifications can't be
/// read on iOS; those stay with the Shortcuts automation.
public enum PhoneSignals {
    public enum Kind: String, CaseIterable, Sendable { case location, battery, steps }

    public static func body(_ items: [[String: Any]], now: Date = Date()) -> [String: Any] {
        ["v": 1, "ts": iso(now), "items": items]
    }

    public static func location(lat: Double, lng: Double, accuracy: Double?, label: String? = nil, at: Date) -> [String: Any] {
        var item: [String: Any] = ["kind": "location", "lat": lat, "lng": lng, "at": iso(at)]
        if let accuracy, accuracy.isFinite, accuracy >= 0 { item["accuracy"] = min((accuracy * 10).rounded() / 10, 100_000) }
        if let label, !label.isEmpty { item["label"] = String(label.prefix(200)) }
        return item
    }

    public static func battery(level: Int, at: Date) -> [String: Any] {
        ["kind": "battery", "level": max(0, min(100, level)), "at": iso(at)]
    }

    public static func steps(_ count: Int, date: String, at: Date) -> [String: Any] {
        ["kind": "steps", "steps": max(0, min(200_000, count)), "date": date, "at": iso(at)]
    }

    static func iso(_ date: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.string(from: date)
    }

    /// Low battery: once at 20%, again at 10% and 5%, never while charging; back above 25% (or charging) starts over.
    public enum Battery {
        public static let steps = [20, 10, 5]

        /// - Returns: the level to send now (and remember), or nil.
        public static func toSend(level: Int, charging: Bool, lastSent: Int?) -> Int? {
            guard !charging, level >= 0 else { return nil }
            guard let step = steps.last(where: { level <= $0 }) else { return nil }
            if let lastSent, lastSent <= step { return nil }
            return level
        }

        /// What to remember after a reading: cleared once the phone is charging or well above the first step.
        public static func remembered(level: Int, charging: Bool, lastSent: Int?) -> Int? {
            if charging || level > 25 { return nil }
            return lastSent
        }
    }

    /// Steps: yesterday's whole day, once (today isn't over yet).
    public enum Steps {
        /// The day (yyyy-MM-dd, Seoul) to send, or nil when it went already.
        public static func dayToSend(lastSentDay: String?, now: Date = Date(), zone: TimeZone = Format.seoul) -> String? {
            let yesterday = day(now.addingTimeInterval(-86_400), zone: zone)
            return lastSentDay == yesterday ? nil : yesterday
        }

        public static func day(_ date: Date, zone: TimeZone = Format.seoul) -> String {
            var cal = Calendar(identifier: .gregorian)
            cal.timeZone = zone
            let c = cal.dateComponents([.year, .month, .day], from: date)
            return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
        }
    }
}

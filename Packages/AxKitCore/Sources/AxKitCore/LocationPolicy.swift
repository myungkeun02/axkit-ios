import Foundation

/// When the phone sends its place to the Mac. The Mac counts only fixes from the last 30 minutes as "now",
/// so a fix goes out on open, every 20 minutes while the app is open, and on a real move.
public enum LocationPolicy {
    /// While the app is open: ask for a fresh fix this often.
    public static let refresh: TimeInterval = 20 * 60
    /// A new fix is worth sending when this much time passed since the last one sent…
    public static let resendAfter: TimeInterval = 10 * 60
    /// …or the phone moved this far (meters).
    public static let moved: Double = 150
    /// Fixes vaguer than this (meters) are not sent.
    public static let worstAccuracy: Double = 1500

    public struct Fix: Equatable, Sendable {
        public var lat: Double
        public var lng: Double
        public var accuracy: Double
        public var at: Date
        public init(lat: Double, lng: Double, accuracy: Double, at: Date) {
            self.lat = lat; self.lng = lng; self.accuracy = accuracy; self.at = at
        }
    }

    public static func shouldSend(_ fix: Fix, last: Fix?, opening: Bool = false) -> Bool {
        guard fix.accuracy >= 0, fix.accuracy <= worstAccuracy,
              (-90...90).contains(fix.lat), (-180...180).contains(fix.lng) else { return false }
        guard let last else { return true }
        if opening { return fix.at.timeIntervalSince(last.at) >= 60 }
        return fix.at.timeIntervalSince(last.at) >= resendAfter || distance(fix, last) >= moved
    }

    /// Great-circle distance in meters.
    public static func distance(_ a: Fix, _ b: Fix) -> Double {
        let r = 6_371_000.0
        let dLat = (b.lat - a.lat) * .pi / 180, dLng = (b.lng - a.lng) * .pi / 180
        let h = sin(dLat / 2) * sin(dLat / 2) + cos(a.lat * .pi / 180) * cos(b.lat * .pi / 180) * sin(dLng / 2) * sin(dLng / 2)
        return 2 * r * asin(min(1, sqrt(h)))
    }
}

/// The same text sent twice in a row by a double tap goes out once.
public struct RepeatGuard: Sendable {
    public var window: TimeInterval
    private var last: (key: String, at: Date)?
    public init(window: TimeInterval = 3) { self.window = window }

    /// True when this send should go; false for the same room and text within the window.
    public mutating func allow(_ text: String, in room: String, at now: Date = Date()) -> Bool {
        let key = room + "\u{1}" + text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let last, last.key == key, now.timeIntervalSince(last.at) < window { return false }
        last = (key, now)
        return true
    }
}

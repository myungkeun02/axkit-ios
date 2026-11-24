import XCTest
@testable import AxKitCore

/// Timing on a real recorded Mac answer (dev/capture-snapshot.mjs). The recording holds the owner's real data, so it lives
/// outside the repo: `AX_SNAPSHOT=/path/snap.json swift test --filter FeedBenchmark`. Skipped without it.
final class FeedBenchmarkTests: XCTestCase {
    private func timeline() throws -> Timeline {
        guard let path = ProcessInfo.processInfo.environment["AX_SNAPSHOT"] else { throw XCTSkip("AX_SNAPSHOT not set") }
        let root = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: path))) as! [String: Any]
        let data = try JSONSerialization.data(withJSONObject: root["events"]!)
        var events: [AppEvent] = []
        ms("decode \(data.count / 1024) KB of events", 3) { events = EventDecoding.events(fromArray: data) }
        var t = Timeline()
        t.apply(events)
        return t
    }

    private func ms(_ label: String, _ times: Int = 5, _ work: () -> Void) {
        let start = Date()
        for _ in 0..<times { work() }
        print(String(format: "BENCH %@: %.2f ms", label, Date().timeIntervalSince(start) * 1000 / Double(times)))
    }

    func testFeedTimings() throws {
        let t = try timeline()
        let dates = t.cards.mapValues(\.at)
        for room in ["", "개발", "팀장회의"] {
            let items = t.items(in: room)
            ms("build[\(room.isEmpty ? "main" : room)] \(items.count) items") {
                _ = RoomFeed.build(items, room: room, lead: nil, assistant: "비서", cardDates: dates)
            }
        }
        ms("preview of every room") { for r in t.roomIds { _ = t.preview(of: r); _ = t.unreadCount(in: r) } }
        ms("isDuplicate for every card") { for id in t.cards.keys { _ = t.isDuplicate(id) } }
    }
}

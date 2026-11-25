import XCTest
@testable import AxKitCore

final class ChatChoicesTests: XCTestCase {
    func testOnlyTheOpenQuestionIsLive() {
        XCTAssertEqual(ChatChoices.state(seq: 5, live: 5, picked: nil), .live)
        XCTAssertEqual(ChatChoices.state(seq: 4, live: 5, picked: nil), .done(picked: nil))
        XCTAssertEqual(ChatChoices.state(seq: 5, live: 5, picked: "a"), .done(picked: "a"))
        XCTAssertEqual(ChatChoices.state(seq: 5, live: nil, picked: nil), .done(picked: nil))
    }

    private func card(_ options: String? = nil) throws -> CardEvent {
        let json = """
        {"type":"card","seq":9,"at":"2026-11-25T01:00:00Z","cardId":"c1","summary":"보낼까요?","effects":["send"],"effectLabels":["보내기"],"expiresAt":"2026-11-26T01:00:00Z"\(options.map { ",\"options\":\($0)" } ?? "")}
        """
        guard case .card(let c) = EventDecoding.event(from: Data(json.utf8)) else { throw XCTSkip("not a card") }
        return c
    }

    private func closed(_ state: String, _ answer: String? = nil) -> CardClosedEvent {
        CardClosedEvent(seq: 10, at: Date(), cardId: "c1", state: state, answer: answer, channel: nil)
    }

    func testCardEchoIsWhatTheOwnerSaid() throws {
        let plain = try card()
        XCTAssertNil(ChatChoices.cardEcho(plain, nil))
        XCTAssertEqual(ChatChoices.cardEcho(plain, closed("approved")), "네, 보내요")
        XCTAssertEqual(ChatChoices.cardEcho(plain, closed("denied")), "아니요")
        XCTAssertEqual(ChatChoices.cardEcho(plain, closed("closed", " 내일 보내 ")), "내일 보내")
        XCTAssertNil(ChatChoices.cardEcho(plain, closed("expired")))
        let picked = try card(#"[{"id":"now","label":"지금 보내기","tone":"primary"},{"id":"no","label":"안 보내기","tone":"danger"}]"#)
        XCTAssertEqual(ChatChoices.cardEcho(picked, closed("approved", "지금 보내기")), "지금 보내기")
        XCTAssertEqual(ChatChoices.answeredOption(picked, closed("approved", "지금 보내기")), "now")
        XCTAssertEqual(ChatChoices.answeredOption(picked, closed("denied")), "no")
    }
}

final class TeamTextTests: XCTestCase {
    func testProblem() {
        XCTAssertNotNil(TeamText.problem("  팀 "))
        XCTAssertNil(TeamText.problem("영상 제작팀이 필요해요"))
        XCTAssertNotNil(TeamText.problem(String(repeating: "가", count: 6001)))
    }

    func testBuiltDecodesAndDropsBrokenMembers() throws {
        let json = """
        {"teamId":"t1","channel":"t1","group":"moa","name":"영상팀","purpose":"영상 2개","briefKept":true,
         "members":[{"id":"t1","name":"영상 팀장","role":"이끌어요"},{"id":"","name":"x"},{"id":"t1-1","name":"대본"}]}
        """
        let built = try JSONDecoder().decode(TeamText.Built.self, from: Data(json.utf8))
        XCTAssertEqual(built.name, "영상팀")
        XCTAssertEqual(built.members.map(\.name), ["영상 팀장", "대본"])
        XCTAssertEqual(built.members.last?.role, "")
        XCTAssertTrue(built.briefKept)
        XCTAssertThrowsError(try JSONDecoder().decode(TeamText.Built.self, from: Data(#"{"teamId":"t1","name":"x"}"#.utf8)))
    }
}

final class BotModelTests: XCTestCase {
    private func bot(_ tier: String?, _ model: String?) throws -> BotsView.Bot {
        var o: [String: Any] = ["id": UUID().uuidString, "name": "a", "channel": "c"]
        if let tier { o["tier"] = tier }
        if let model { o["model"] = model }
        return try JSONDecoder().decode(BotsView.Bot.self, from: JSONSerialization.data(withJSONObject: o))
    }

    func testGradeLine() throws {
        XCTAssertEqual(try bot("A", "Claude Opus · 구독").gradeLine, "A 등급 · Claude Opus · 구독")
        XCTAssertEqual(try bot("B", nil).gradeLine, "B 등급")
        XCTAssertEqual(try bot(nil, nil).gradeLine, "")
    }

    func testTeamModels() throws {
        XCTAssertEqual(BotsView.teamModels([try bot("A", "X"), try bot("B", "X")]), "X")
        XCTAssertEqual(BotsView.teamModels([try bot("A", "X"), try bot("B", "Y"), try bot("C", nil)]), "X / Y")
        XCTAssertEqual(BotsView.teamModels([try bot("A", "X"), try bot("B", "Y"), try bot("C", "Z")]), "X / Y 외 1")
        XCTAssertEqual(BotsView.teamModels([try bot("A", nil)]), "")
    }
}

final class PhoneSignalsTests: XCTestCase {
    func testBatteryStepsDown() {
        typealias B = PhoneSignals.Battery
        XCTAssertNil(B.toSend(level: 40, charging: false, lastSent: nil))
        XCTAssertEqual(B.toSend(level: 18, charging: false, lastSent: nil), 18)
        XCTAssertNil(B.toSend(level: 15, charging: false, lastSent: 18))
        XCTAssertEqual(B.toSend(level: 9, charging: false, lastSent: 18), 9)
        XCTAssertNil(B.toSend(level: 7, charging: false, lastSent: 9))
        XCTAssertEqual(B.toSend(level: 4, charging: false, lastSent: 9), 4)
        XCTAssertNil(B.toSend(level: 4, charging: true, lastSent: nil))
        XCTAssertNil(B.remembered(level: 30, charging: false, lastSent: 9))
        XCTAssertNil(B.remembered(level: 12, charging: true, lastSent: 9))
        XCTAssertEqual(B.remembered(level: 12, charging: false, lastSent: 9), 9)
    }

    func testStepsOncePerDayForYesterday() {
        let now = ISO8601DateFormatter().date(from: "2026-11-25T00:30:00Z")! // 09:30 in Seoul
        XCTAssertEqual(PhoneSignals.Steps.dayToSend(lastSentDay: nil, now: now), "2026-11-24")
        XCTAssertNil(PhoneSignals.Steps.dayToSend(lastSentDay: "2026-11-24", now: now))
        XCTAssertEqual(PhoneSignals.Steps.dayToSend(lastSentDay: "2026-11-22", now: now), "2026-11-24")
    }

    func testBodyShape() throws {
        let at = Date(timeIntervalSince1970: 1_790_000_000)
        let body = PhoneSignals.body([PhoneSignals.location(lat: 37.5, lng: 127.0, accuracy: 65.43, at: at), PhoneSignals.battery(level: 140, at: at)], now: at)
        XCTAssertEqual(body["v"] as? Int, 1)
        let items = try XCTUnwrap(body["items"] as? [[String: Any]])
        XCTAssertEqual(items[0]["kind"] as? String, "location")
        XCTAssertEqual(items[0]["accuracy"] as? Double, 65.4)
        XCTAssertEqual(items[1]["level"] as? Int, 100)
        XCTAssertNotNil(items[1]["at"] as? String)
        XCTAssertTrue(JSONSerialization.isValidJSONObject(body))
    }
}

final class RoomFeedShortTests: XCTestCase {
    func testLongViewKeepsEveryLine() throws {
        var items: [Timeline.Item] = []
        for i in 0..<8 {
            let json = """
            {"type":"message","seq":\(i + 1),"at":"2026-11-25T01:0\(i):00Z","role":"assistant","channel":"dev","author":{"id":"a\(i % 2)","name":"봇\(i % 2)"},"to":{"id":"a\((i + 1) % 2)","name":"봇\((i + 1) % 2)"},"text":"줄 \(i)"}
            """
            guard case .message(let m) = EventDecoding.event(from: Data(json.utf8)) else { return XCTFail() }
            items.append(.message(m))
        }
        let folded = RoomFeed.build(items, room: "dev", lead: nil, assistant: "비서")
        XCTAssertTrue(folded.contains { if case .folded = $0 { true } else { false } })
        let long = RoomFeed.build(items, room: "dev", lead: nil, assistant: "비서", short: false)
        XCTAssertFalse(long.contains { if case .folded = $0 { true } else { false } })
        XCTAssertEqual(long.filter { if case .entry = $0 { true } else { false } }.count, 8)
    }
}

final class BlockRowQueryTests: XCTestCase {
    func testQueryDecodesAsStringsAndWinsOverMessage() throws {
        let json = """
        {"title":"드라이브","blocks":[{"kind":"list","rows":[
          {"title":"기획","query":{"mode":"tree","folder":"f1","depth":2,"shared":true,"x":null},"message":"요약해 줘"},
          {"title":"처음으로","query":{}},
          {"title":"파일","message":"요약"},
          {"title":"이상한","query":"oops"}]}]}
        """
        let rows = try XCTUnwrap(JSONDecoder().decode(BlocksView.self, from: Data(json.utf8)).blocks.first?.rows)
        XCTAssertEqual(rows[0].query, ["mode": "tree", "folder": "f1", "depth": "2", "shared": "true"])
        XCTAssertEqual(rows[1].query, [:])
        XCTAssertNil(rows[2].query)
        XCTAssertNil(rows[3].query)
    }
}

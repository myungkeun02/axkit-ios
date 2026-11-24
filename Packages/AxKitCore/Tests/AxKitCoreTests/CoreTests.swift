import CryptoKit
import XCTest
@testable import AxKitCore

final class SSEParserTests: XCTestCase {
    func testParsesEventIdAndDataAndSkipsComments() {
        var parser = SSEParser()
        XCTAssertNil(parser.feed(": open"))
        XCTAssertNil(parser.feed("event: message"))
        XCTAssertNil(parser.feed("id: 42"))
        XCTAssertNil(parser.feed("data: {\"a\":1}"))
        let message = parser.feed("")
        XCTAssertEqual(message, SSEMessage(event: "message", id: "42", data: "{\"a\":1}"))
        XCTAssertNil(parser.feed(""), "a blank line with nothing buffered yields nothing")
    }

    func testJoinsMultiLineDataAndHandlesCR() {
        var parser = SSEParser()
        _ = parser.feed("data: one\r")
        _ = parser.feed("data:two")
        XCTAssertEqual(parser.feed("\r")?.data, "one\ntwo")
    }

    func testLineSplitterKeepsBlankLines() {
        var splitter = LineSplitter()
        var lines: [String] = []
        for byte in Array("a\n\nb\n".utf8) { if let line = splitter.feed(byte) { lines.append(line) } }
        XCTAssertEqual(lines, ["a", "", "b"])
    }

    func testBackoffDoublesToSixtyAndResets() {
        var backoff = Backoff()
        XCTAssertEqual((0..<7).map { _ in backoff.fail() }, [2, 4, 8, 16, 32, 60, 60])
        backoff.reset()
        XCTAssertEqual(backoff.fail(), 2)
    }
}

final class EventDecodingTests: XCTestCase {
    func decode(_ json: String) -> AppEvent? { EventDecoding.event(from: Data(json.utf8)) }

    func testMessageWithChannelAndAuthor() throws {
        let event = decode(#"{"type":"message","seq":3,"at":"2026-11-18T06:19:46.209Z","role":"assistant","text":"안녕","channel":"dev","author":{"id":"dev","name":"개발 봇"},"extra":1}"#)
        guard case .message(let m) = event else { return XCTFail("not a message") }
        XCTAssertEqual(m.text, "안녕")
        XCTAssertEqual(m.author?.name, "개발 봇")
        XCTAssertEqual(event?.channel, "dev")
    }

    func testCardWithOptionsAndUnknownTone() throws {
        let event = decode(#"{"type":"card","seq":5,"at":"2026-11-18T06:19:46Z","cardId":"c1","summary":"결제","effects":["pay"],"effectLabels":["결제"],"expiresAt":"2026-11-18T07:00:00Z","options":[{"id":"a","label":"승인","tone":"sparkly"}],"amount":{"value":12000,"currency":"KRW"}}"#)
        guard case .card(let c) = event else { return XCTFail("not a card") }
        XCTAssertEqual(c.options?.first?.tone, nil)
        XCTAssertTrue(c.isPayment)
        XCTAssertEqual(c.amount?.value, 12000)
    }

    func testUnknownTypeAndBrokenKnownTypeBecomeUnknown() {
        XCTAssertEqual(decode(#"{"type":"hologram","seq":9,"at":"x"}"#), .unknown(type: "hologram", seq: 9))
        XCTAssertEqual(decode(#"{"type":"message","seq":10,"at":"2026-11-18T06:19:46Z"}"#), .unknown(type: "message", seq: 10))
        XCTAssertNil(decode("not json"))
    }

    func testDelegationDefaultsState() {
        let event = decode(#"{"type":"delegation","seq":4,"at":"2026-11-18T06:19:46Z","bot":{"id":"dev","name":"개발 봇"},"botChannel":"dev","task":"로그인 고치기","state":"weird"}"#)
        guard case .delegation(let d) = event else { return XCTFail("not a delegation") }
        XCTAssertEqual(d.state, .started)
        XCTAssertEqual(event?.channel, "")
    }

    func testEventsArraySkipsGarbage() {
        let events = EventDecoding.events(fromArray: Data(#"[{"type":"notice","seq":1,"at":"2026-11-18T06:19:46Z","text":"hi"}, 5, {"nope":true}]"#.utf8))
        XCTAssertEqual(events.map(\.seq), [1])
    }
}

final class PairingTests: XCTestCase {
    func testParsesLinkAndAccessToken() throws {
        let link = try PairingLink.parse("axkit://pair?u=https%3A%2F%2Fmac.tail1.ts.net%2F&n=abc_123&c=482913&ci=id1&cs=sec")
        XCTAssertEqual(link.baseURL.absoluteString, "https://mac.tail1.ts.net")
        XCTAssertEqual(link.nonce, "abc_123")
        XCTAssertEqual(link.code, "482913")
        XCTAssertEqual(link.accessClientId, "id1")
    }

    func testRejectsPublicHTTPAndJunk() {
        XCTAssertThrowsError(try PairingLink.parse("axkit://pair?u=http%3A%2F%2Fexample.com&n=a&c=123456")) {
            XCTAssertEqual($0 as? PairingLink.ParseError, .insecureAddress)
        }
        XCTAssertThrowsError(try PairingLink.parse("https://pair?u=x"))
        XCTAssertThrowsError(try PairingLink.parse("axkit://pair?u=https%3A%2F%2Fa.b&n=a%2F..&c=1"))
    }

    func testPrivateHosts() {
        for host in ["127.0.0.1", "10.1.2.3", "192.168.0.9", "172.20.1.1", "100.101.1.2", "localhost", "::1"] {
            XCTAssertTrue(AddressPolicy.isPrivateHost(host), host)
        }
        for host in ["8.8.8.8", "172.32.0.1", "100.128.0.1", "mac.ts.net", "1.2.3"] {
            XCTAssertFalse(AddressPolicy.isPrivateHost(host), host)
        }
    }
}

final class TimelineTests: XCTestCase {
    let at = Date(timeIntervalSince1970: 1_800_000_000)

    func message(_ seq: Int, _ text: String, channel: String? = nil, role: MessageEvent.Role = .assistant) -> AppEvent {
        .message(MessageEvent(seq: seq, at: at, role: role, text: text, channel: channel))
    }

    func card(_ seq: Int, _ id: String, expires: Date? = nil) -> AppEvent {
        .card(CardEvent(seq: seq, at: at, cardId: id, summary: "s\(seq)", effects: ["pay"], effectLabels: ["결제"], expiresAt: expires))
    }

    /// A card asked again (same id, newer seq) moves to the bottom, once.
    func testResentCardMovesToItsNewPlace() {
        var timeline = Timeline()
        timeline.apply(card(1, "c1"))
        timeline.apply(message(2, "중간"))
        timeline.apply(card(3, "c1"))
        XCTAssertEqual(timeline.items(in: "").map(\.seq), [2, 3])
        XCTAssertEqual(timeline.card("c1")?.seq, 3)
    }

    /// What the phone keeps: newest lines per room, open cards, what was read.
    func testSnapshotRoundTripKeepsNewestAndRead() throws {
        var timeline = Timeline()
        for seq in 1...10 { timeline.apply(message(seq, "m\(seq)")) }
        timeline.apply(card(11, "c1"))
        timeline.markRead("")
        let data = try JSONEncoder().encode(timeline.snapshot(perRoom: 5))
        let back = Timeline(try JSONDecoder().decode(Timeline.Snapshot.self, from: data))
        XCTAssertEqual(back.items(in: "").map(\.seq), [7, 8, 9, 10, 11])
        XCTAssertEqual(back.lastSeq, 11)
        XCTAssertEqual(back.readUpTo[""], 11)
        XCTAssertEqual(back.unreadCount(in: ""), 0)
        XCTAssertTrue(back.isOpen("c1"))
        XCTAssertTrue(back.has(seq: 9))
        var again = back
        XCTAssertFalse(again.apply(message(9, "dup")))
    }

    /// A late older copy of a card (catch-up after the stream) never replaces the newer one.
    func testOlderCardCopyDoesNotReplaceNewer() {
        var timeline = Timeline()
        timeline.apply(card(5, "c1"))
        timeline.apply(card(3, "c1"))
        XCTAssertEqual(timeline.card("c1")?.seq, 5)
        XCTAssertEqual(timeline.items(in: "").map(\.seq), [5])
    }

    /// A snapshot with one unreadable line still loads the rest; another version is not read at all.
    func testSnapshotIsLossyAndVersioned() throws {
        var timeline = Timeline()
        for seq in 1...3 { timeline.apply(message(seq, "m\(seq)")) }
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(timeline.snapshot())) as? [String: Any])
        var rooms = try XCTUnwrap(json["rooms"] as? [String: [Any]])
        rooms[""]?.append(["broken": true])
        json["rooms"] = rooms
        let back = try JSONDecoder().decode(Timeline.Snapshot.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertEqual(Timeline(back).items(in: "").map(\.seq), [1, 2, 3])
        json["version"] = 99
        XCTAssertThrowsError(try JSONDecoder().decode(Timeline.Snapshot.self, from: JSONSerialization.data(withJSONObject: json)))
    }

    func testOpenQuestionEndsWithOwnersAnswer() {
        var timeline = Timeline()
        var asked = MessageEvent(seq: 1, at: at, role: .assistant, text: "어떻게 할까요?")
        asked.choices = [Choice(id: "a", label: "A")]
        timeline.apply(.message(asked))
        XCTAssertEqual(timeline.openQuestion(in: ""), 1)
        timeline.apply(message(2, "A", role: .owner))
        XCTAssertNil(timeline.openQuestion(in: ""))
    }

    /// A reconnect replays an older answer right after the fresh "still thinking": the dots stay.
    func testReplayedAnswerKeepsNewerActivity() {
        var board = ActivityBoard()
        board.apply(ActivityEvent(state: .thinking, at: at))
        board.answered(in: "", at: at.addingTimeInterval(-30))
        XCTAssertNotNil(board[""])
        board.answered(in: "", at: at.addingTimeInterval(1))
        XCTAssertNil(board[""])
    }

    func testLateEventsSlotInAndRoomsKeepTheNewest() {
        var timeline = Timeline()
        for seq in 1...(Timeline.maxPerRoom + 5) where seq != 1003 { timeline.apply(message(seq, "m\(seq)")) }
        timeline.apply(message(1003, "late"))
        let seqs = timeline.items(in: "").map(\.seq)
        XCTAssertEqual(seqs.count, Timeline.maxPerRoom)
        XCTAssertEqual(seqs, seqs.sorted())
        XCTAssertEqual(seqs.last, Timeline.maxPerRoom + 5)
        XCTAssertTrue(seqs.contains(1003))
        XCTAssertEqual(timeline.unreadCount(in: ""), Timeline.maxPerRoom)
    }

    func testCleanedTextIsTheSameFromTheCache() {
        let raw = "<@123> 배포 끝 :white_check_mark: · v2-ax-qa-web-4ac6f8339bea2b7d\n\n\n\n## 다음\n- 확인"
        let first = ChatText.clean(raw)
        XCTAssertEqual(first, ChatText.cleanUncached(raw, zone: Format.seoul))
        XCTAssertEqual(ChatText.clean(raw), first)
        XCTAssertEqual(ChatText.preview(raw, limit: 10), ChatText.preview(raw, limit: 10))
        XCTAssertNotEqual(ChatText.preview(raw, limit: 10), ChatText.preview(raw, limit: 100))
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        XCTAssertEqual(Format.clock(date), Format.clock(date))
        XCTAssertEqual(Format.ymd(date, zone: TimeZone(identifier: "UTC")!), "2027-01-15")
    }

    func testSplitsRoomsDedupesAndOrders() {
        var timeline = Timeline()
        timeline.apply([message(3, "c"), message(1, "a"), message(2, "b", channel: "dev")])
        XCTAssertFalse(timeline.apply(message(1, "again")))
        XCTAssertEqual(timeline.items(in: "").map(\.seq), [1, 3])
        XCTAssertEqual(timeline.items(in: "dev").map(\.seq), [2])
        XCTAssertEqual(timeline.lastSeq, 3)
        timeline.apply(message(2, "late")) // already seen
        XCTAssertEqual(timeline.items(in: "").count, 2)
    }

    func testCardsOpenCloseExpireAndReplaceInPlace() {
        var timeline = Timeline()
        timeline.apply(card(1, "a", expires: at.addingTimeInterval(600)))
        timeline.apply(card(2, "b", expires: at.addingTimeInterval(-1)))
        XCTAssertEqual(timeline.openCards(now: at).map(\.cardId), ["a"])
        // Same card re-sent with a form: one item, newest content.
        timeline.apply(.card(CardEvent(seq: 3, at: at, cardId: "a", summary: "new", effects: [], effectLabels: [], expiresAt: at.addingTimeInterval(600))))
        XCTAssertEqual(timeline.items(in: "").count, 2)
        XCTAssertEqual(timeline.card("a")?.summary, "new")
        timeline.apply(.cardClosed(CardClosedEvent(seq: 4, at: at, cardId: "a", state: "approved")))
        XCTAssertTrue(timeline.openCards(now: at).isEmpty)
        XCTAssertEqual(Set(timeline.finishedCards(now: at).map(\.cardId)), ["a", "b"])
    }

    func testSameQuestionShowsOnce() {
        var timeline = Timeline()
        func ask(_ seq: Int, _ id: String, topic: String?, summary: String = "Drive에 저장할까요?") -> AppEvent {
            .card(CardEvent(seq: seq, at: at, cardId: id, summary: summary, effects: ["send"], effectLabels: [], note: "회의록",
                            expiresAt: at.addingTimeInterval(600)))
        }
        timeline.apply(ask(1, "a", topic: nil))
        timeline.apply(ask(2, "b", topic: nil))
        timeline.apply(ask(3, "c", topic: nil, summary: "다른 질문"))
        XCTAssertEqual(timeline.openCards(now: at).map(\.cardId), ["c", "b"])
        XCTAssertTrue(timeline.isDuplicate("a", now: at))
        XCTAssertFalse(timeline.isDuplicate("b", now: at))
        var withTopic = CardEvent(seq: 4, at: at, cardId: "d", summary: "말만 다름", effects: [], effectLabels: [], expiresAt: at.addingTimeInterval(600))
        withTopic.topic = "drive:save"
        var again = withTopic; again.seq = 5; again.cardId = "e"; again.summary = "또 다른 말"
        timeline.apply(.card(withTopic)); timeline.apply(.card(again))
        XCTAssertEqual(timeline.openCards(now: at).filter { $0.topic == "drive:save" }.map(\.cardId), ["e"])
    }

    func testUnreadCountsOnlyAssistantSideAndResetsOnRead() {
        var timeline = Timeline()
        timeline.apply([message(1, "me", role: .owner), message(2, "bot"), card(3, "x")])
        XCTAssertEqual(timeline.unreadCount(in: ""), 2)
        timeline.markRead("")
        XCTAssertEqual(timeline.unreadCount(in: ""), 0)
        XCTAssertEqual(timeline.preview(of: "")?.text, "s3")
    }

    func testDefaultOptionsMapToDecisions() {
        let c = CardEvent(seq: 1, at: at, cardId: "c", summary: "", effects: ["send"], effectLabels: [])
        let options = CardWords.defaultOptions(for: c)
        XCTAssertEqual(options.first?.label, "네, 보내요")
        XCTAssertEqual(CardWords.answer(for: options[0]), .decision("approve"))
        XCTAssertEqual(CardWords.answer(for: CardOption(id: "org:d:1", label: "x")), .option("org:d:1"))
        XCTAssertEqual(CardWords.closedLabel(CardClosedEvent(seq: 1, at: at, cardId: "c", state: "closed", answer: "내일 해"), expired: false), "답함: 내일 해")
    }
}

final class OutboxTests: XCTestCase {
    struct Offline: Error {}

    /// Sending twice quickly started two flushes at once; both removed "the first" message after their send,
    /// so the second removal hit an empty queue and the app crashed. Each message must go once, in order.
    func testOverlappingFlushesSendEachMessageOnceInOrder() async throws {
        let box = Outbox(fileURL: nil)
        for i in 1...5 { await box.enqueue(text: "메시지 \(i)", channel: "") }
        let sent = SentBox()
        let slowSend: @Sendable (PendingMessage) async throws -> Void = { message in
            try await Task.sleep(nanoseconds: 20_000_000)
            await sent.add(message.text)
        }
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<4 {
                group.addTask { _ = await box.flush(using: slowSend) }
                group.addTask { await box.enqueue(text: "더", channel: "") }
            }
        }
        _ = await box.flush(using: slowSend)
        let texts = await sent.ids
        XCTAssertEqual(texts.count, 9)
        XCTAssertEqual(Array(texts.prefix(5)), (1...5).map { "메시지 \($0)" })
        let left = await box.pending
        XCTAssertTrue(left.isEmpty)
    }

    func testPersistsSendsInOrderAndStopsOnTransientFailure() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("outbox-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let box = Outbox(fileURL: url)
        let first = await box.enqueue(text: "하나", channel: "")
        await box.enqueue(text: "둘", channel: "dev")

        let reopened = Outbox(fileURL: url)
        let pending = await reopened.pending
        XCTAssertEqual(pending.map(\.text), ["하나", "둘"])

        let failing = await reopened.flush { _ in throw APIError.offline }
        XCTAssertEqual(failing.remaining, 2)
        let attempts = await reopened.pending.first?.attempts
        XCTAssertEqual(attempts, 1)

        let sent = SentBox()
        let result = await reopened.flush { await sent.add($0.id) }
        XCTAssertEqual(result.sent.first, first.id)
        XCTAssertEqual(result.remaining, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    /// Nothing typed is ever thrown away: the Mac's "no" and stale codes stay in the queue marked failed.
    func testKeepsRefusedAndStaleCodesAsFailed() async {
        let clock = Clock(Date(timeIntervalSince1970: 0))
        let box = Outbox(fileURL: nil, now: { clock.now })
        await box.enqueue(text: "인증번호 482913", channel: "")
        await box.enqueue(text: "too long", channel: "")
        await box.enqueue(text: "fine", channel: "")
        clock.now = Date(timeIntervalSince1970: 11 * 60)
        let result = await box.flush { message in
            if message.text == "too long" { throw APIError.badRequest("shape") }
        }
        XCTAssertEqual(result.failed.count, 2)
        XCTAssertEqual(result.sent.count, 1)
        XCTAssertEqual(result.retrying, 0)
        let left = await box.pending
        XCTAssertEqual(left.map(\.text), ["인증번호 482913", "too long"])
        XCTAssertTrue(left.allSatisfy { $0.showsFailed })
        // A failed one is skipped by later flushes until the owner taps 다시 보내기.
        let again = await box.flush { _ in XCTFail("failed messages must wait for the owner") }
        XCTAssertEqual(again.sent.count, 0)
        await box.retry(left[1].id)
        let retried = await box.flush { _ in }
        XCTAssertEqual(retried.sent, [left[1].id])
    }

    /// A proxy's HTML page, an unreadable body and a refused token are not the Mac saying no: keep and retry.
    func testKeepsMessagesOnProxyErrorsAndUnauthorized() async {
        let box = Outbox(fileURL: nil)
        await box.enqueue(text: "하나", channel: "")
        for error in [APIError.server(status: 404, error: nil), .decoding, .offline] {
            let result = await box.flush { _ in throw error }
            XCTAssertEqual(result.retrying, 1)
            XCTAssertTrue(result.failed.isEmpty)
        }
        let attempts = await box.pending.first?.attempts
        XCTAssertEqual(attempts, 3)
        let unauthorized = await box.flush { _ in throw APIError.unauthorized }
        XCTAssertTrue(unauthorized.unauthorized)
        XCTAssertEqual(unauthorized.remaining, 1)
        XCTAssertEqual(APIError.decoding.isFinalRefusal, false)
        XCTAssertEqual(APIError.refused("x").isFinalRefusal, true)
    }

    func testLooksLikeCode() {
        XCTAssertTrue(Outbox.looksLikeCode("인증번호는 [123456] 입니다"))
        XCTAssertTrue(Outbox.looksLikeCode("Your code: 9921"))
        XCTAssertFalse(Outbox.looksLikeCode("내일 3시에 만나요"))
        XCTAssertFalse(Outbox.looksLikeCode("코드 리뷰 해 줘"))
    }
}

actor SentBox { var ids: [String] = []; func add(_ id: String) { ids.append(id) } }
final class Clock: @unchecked Sendable { var now: Date; init(_ now: Date) { self.now = now } }

final class LayoutAndFormatTests: XCTestCase {
    func testLayoutIsDeterministicFiniteAndPullsLinksTogether() {
        let nodes = (0..<12).map { "n\($0)" }
        let links = [("n0", "n1"), ("n1", "n2"), ("n2", "n0")]
        let a = GraphLayout.layout(nodes: nodes, links: links, size: 1000, iterations: 200)
        let b = GraphLayout.layout(nodes: nodes, links: links, size: 1000, iterations: 200)
        XCTAssertEqual(a, b)
        XCTAssertEqual(a.count, 12)
        for p in a.values { XCTAssertTrue(p.x.isFinite && abs(p.x) <= 500.001 && abs(p.y) <= 500.001) }
        func d(_ x: String, _ y: String) -> Double { hypot(a[x]!.x - a[y]!.x, a[x]!.y - a[y]!.y) }
        let linked = (d("n0", "n1") + d("n1", "n2") + d("n2", "n0")) / 3
        let others = nodes.dropFirst(3).map { d("n0", $0) }.reduce(0, +) / 9
        XCTAssertLessThan(linked, others)
        XCTAssertTrue(GraphLayout.layout(nodes: [], links: []).isEmpty)
    }

    func testLayout3DIsDeterministicInsideTheSphereAndPullsLinksTogether() {
        let nodes = (0..<14).map { "n\($0)" }
        let links = [("n0", "n1"), ("n1", "n2"), ("n2", "n0")]
        let a = GraphLayout.layout3D(nodes: nodes, links: links, size: 1000, iterations: 150)
        XCTAssertEqual(a, GraphLayout.layout3D(nodes: nodes, links: links, size: 1000, iterations: 150))
        for p in a.values { XCTAssertLessThanOrEqual(sqrt(p.x * p.x + p.y * p.y + p.z * p.z), 500.001) }
        func d(_ x: String, _ y: String) -> Double { let p = a[x]!, q = a[y]!; return sqrt(pow(p.x - q.x, 2) + pow(p.y - q.y, 2) + pow(p.z - q.z, 2)) }
        let linked = (d("n0", "n1") + d("n1", "n2") + d("n2", "n0")) / 3
        let others = nodes.dropFirst(3).map { d("n0", $0) }.reduce(0, +) / 11
        XCTAssertLessThan(linked, others)
    }

    func testWon() {
        XCTAssertEqual(Format.won(980), "980원")
        XCTAssertEqual(Format.won(12_500), "1만 2,500원")
        XCTAssertEqual(Format.won(30_000), "3만원")
        XCTAssertEqual(Format.won(1_234_567), "123만 4,567원")
        XCTAssertEqual(Format.won(-4_000), "-4,000원")
        XCTAssertEqual(Format.dollars(0.004), "1센트 미만")
    }

    func testRelative() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        XCTAssertEqual(Format.relative(now.addingTimeInterval(-30), now: now), "방금")
        XCTAssertEqual(Format.relative(now.addingTimeInterval(-300), now: now), "5분 전")
        XCTAssertEqual(Format.relative(now.addingTimeInterval(-86_400), now: now), "어제")
        XCTAssertTrue(Format.deadline(now.addingTimeInterval(86_400), now: now).hasPrefix("내일 "))
        XCTAssertEqual(Format.subject("개발 봇"), "개발 봇이")
        XCTAssertEqual(Format.subject("비서"), "비서가")
    }
}

final class APIClientTests: XCTestCase {
    override func tearDown() { StubProtocol.handler = nil }

    func client() -> APIClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubProtocol.self]
        let credentials = ServerCredentials(baseURL: URL(string: "http://127.0.0.1:47790")!, token: "tok", deviceId: "d_1",
                                            deviceName: "아이폰", accessClientId: "cid", accessClientSecret: "csec")
        return APIClient(credentials: credentials, session: URLSession(configuration: config))
    }

    func testSendsAuthHeadersAndChannel() async throws {
        StubProtocol.handler = { request in
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer tok")
            XCTAssertEqual(request.value(forHTTPHeaderField: "CF-Access-Client-Id"), "cid")
            XCTAssertEqual(request.url?.path, "/m/v1/app/messages")
            let body = try JSONSerialization.jsonObject(with: StubProtocol.body(of: request)) as? [String: Any]
            XCTAssertEqual(body?["channel"] as? String, "dev")
            XCTAssertNil(body?["remember"])
            XCTAssertEqual(body?["clientId"] as? String, "c1")
            return (200, #"{"ok":true,"seq":7}"#, "application/json")
        }
        let result = try await client().sendMessage(text: "hi", channel: "dev", clientId: "c1")
        XCTAssertEqual(result.seq, 7)
    }

    func testOwnJSON401IsUnauthorizedButProxyHTMLIsNot() async {
        StubProtocol.handler = { _ in (401, #"{"ok":false}"#, "application/json") }
        do { _ = try await client().status(); XCTFail() } catch { XCTAssertEqual(error as? APIError, .unauthorized) }
        StubProtocol.handler = { _ in (401, "<html>", "text/html") }
        do { _ = try await client().status(); XCTFail() } catch { XCTAssertEqual(error as? APIError, .server(status: 401, error: nil)) }
    }

    func testViewUnwrapsDataAndGoneCard() async throws {
        StubProtocol.handler = { request in
            if request.url?.path.hasPrefix("/m/v1/app/cards/") == true { return (410, #"{"ok":false,"error":"gone"}"#, "application/json") }
            return (200, #"{"ok":true,"view":"today","version":1,"data":{"date":"2026-11-19","events":null,"todos":[],"pendingCards":2}}"#, "application/json")
        }
        let today = try await client().view(TodayView.self, "today")
        XCTAssertEqual(today.pendingCards, 2)
        XCTAssertNil(today.events)
        do { _ = try await client().answerCard("org:d:1", .text("내일")); XCTFail() } catch { XCTAssertEqual(error as? APIError, .gone) }
    }

    func testCardIdWithColonsIsSentOnce() async throws {
        StubProtocol.handler = { request in
            XCTAssertEqual(request.url?.absoluteString, "http://127.0.0.1:47790/m/v1/app/cards/p0:b142-a8:0")
            return (200, #"{"ok":true,"state":"open"}"#, "application/json")
        }
        _ = try await client().answerCard("p0:b142-a8:0", .option("x"))
    }

    func testFormAndSelectAnswers() async throws {
        StubProtocol.handler = { request in
            let body = try JSONSerialization.jsonObject(with: StubProtocol.body(of: request)) as? [String: Any]
            if let form = body?["form"] as? [String: Any] {
                XCTAssertEqual(form["id"] as? String, "pin:p0:1")
                XCTAssertEqual((form["fields"] as? [String: String])?["pin"], "123456")
            } else {
                let select = body?["select"] as? [String: Any]
                XCTAssertEqual(select?["values"] as? [String], ["a", "b"])
            }
            return (200, #"{"ok":true,"state":"approved"}"#, "application/json")
        }
        _ = try await client().answerCard("p0:1", .form(id: "pin:p0:1", fields: ["pin": "123456"]))
        _ = try await client().answerCard("c", .select(id: "s1", values: ["a", "b"]))
        let card = EventDecoding.event(from: Data(#"{"type":"card","seq":1,"at":"2026-11-18T06:19:46Z","cardId":"p0:1","summary":"x","effects":[],"effectLabels":[],"form":{"id":"pin:p0:1","title":"PIN","fields":[{"id":"pin","label":"PIN","secret":true}]},"selects":[{"id":"s1","max":2,"choices":[{"id":"a","label":"A"}]}]}"#.utf8))
        guard case .card(let c) = card else { return XCTFail() }
        XCTAssertEqual(c.form?.fields.first?.secret, true)
        XCTAssertEqual(c.selects?.first?.max, 2)
    }

    func testKnowledgeHealthAndReactions() async throws {
        StubProtocol.handler = { request in
            let path = request.url?.path ?? ""
            if path.hasSuffix("views/knowledge") {
                return (200, #"{"ok":true,"view":"knowledge","version":1,"data":{"areas":[{"id":"a","label":"회사","docs":[{"id":"d1","title":"규칙","updatedAt":"2026-11-10T00:00:00Z"},{"id":"d2","title":"예산","updatedAt":"2026-11-18T00:00:00Z"}]},{"id":"b","label":"기록","docs":[{"id":"d2","title":"예산","updatedAt":"2026-11-18T00:00:00Z"}]}]}}"#, "application/json")
            }
            if path.hasSuffix("views/health") {
                return (200, #"{"ok":true,"view":"health","version":1,"data":{"summary":"2가지","checks":[{"id":"db","label":"저장소","status":"ok"},{"id":"disk","label":"저장 공간","status":"warn","detail":"82%"}]}}"#, "application/json")
            }
            XCTAssertTrue(path.hasSuffix("messages/42/react"))
            let body = try JSONSerialization.jsonObject(with: StubProtocol.body(of: request)) as? [String: Any]
            XCTAssertEqual(body?["emoji"] as? String, "👎")
            return (200, #"{"ok":true}"#, "application/json")
        }
        let k = try await client().view(KnowledgeView.self, "knowledge")
        XCTAssertEqual(k.recent(5).map(\.id), ["d2", "d1"], "newest first, each document once")
        let h = try await client().view(HealthView.self, "health")
        XCTAssertEqual(h.checks.last?.status, "warn")
        try await client().react(seq: 42, emoji: "👎")
    }

    func testSSHPresetsKeysAndKnownHosts() throws {
        let presets = SSHHost.presets("서버 맥=alice@100.1.2.3, 노트북=bob@100.4.5.6:2222, 이상한 것, =x@y")
        XCTAssertEqual(presets.map(\.name), ["서버 맥", "노트북"])
        XCTAssertEqual(presets[1].port, 2222)
        XCTAssertEqual(presets[1].knownHostsKey, "[100.4.5.6]:2222")
        XCTAssertEqual(presets[0].target, "alice@100.1.2.3")
        XCTAssertTrue(SSHHost.presets("$(AX_SSH_HOSTS)").isEmpty)

        // A fixed key: the line and fingerprint must match what ssh-keygen prints for it.
        let key = try Curve25519.Signing.PrivateKey(rawRepresentation: Data(repeating: 7, count: 32))
        let line = SSHKeyFormat.openSSHLine(key.publicKey, comment: "ax-kit iPhone")
        // Both values are what ssh-keygen prints for this key (`ssh-keygen -lf`).
        XCTAssertEqual(line, "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOpKbGPinFIKvvVQexMuxfmVR3auvr57kkIe6mkURtIs ax-kit iPhone")
        XCTAssertEqual(SSHKeyFormat.fingerprint(openSSHLine: line), "SHA256:z/fSv0Z0RZS+Lccbc6ZoOWwt/fbj1VFJGSBKQbo4icE")

        let defaults = UserDefaults(suiteName: "ssh-test-\(UUID())")!
        let known = KnownHosts(defaults: defaults)
        XCTAssertEqual(known.check("ssh-ed25519 AAA1", for: "h"), .new)
        known.remember("ssh-ed25519 AAA1 old-comment", for: "h")
        XCTAssertEqual(known.check("ssh-ed25519 AAA1", for: "h"), .same)
        XCTAssertEqual(known.check("ssh-ed25519 BBB2", for: "h"), .changed(previous: "ssh-ed25519 AAA1 old-comment"))

        let list = SSHHostList(defaults: defaults)
        list.seed(presets)
        XCTAssertEqual(list.hosts.count, 2)
        list.save(Array(list.hosts.dropFirst()))   // the owner deletes one
        list.seed(presets)                         // next launch
        XCTAssertEqual(list.hosts.map(\.name), ["노트북"], "a deleted preset does not come back")
    }

    func testRememberRidesAlongWithTheChoice() async throws {
        StubProtocol.handler = { request in
            let body = try JSONSerialization.jsonObject(with: StubProtocol.body(of: request)) as? [String: Any]
            XCTAssertEqual(body?["option"] as? String, "beans:usual")
            XCTAssertEqual(body?["remember"] as? Bool, true)
            return (200, #"{"ok":true,"state":"approved"}"#, "application/json")
        }
        let result = try await client().answerCard("beans", .option("beans:usual"), remember: true)
        XCTAssertEqual(result.state, "approved")
    }

    func testRefusalShowsTheMacsOwnWords() async {
        StubProtocol.handler = { _ in (400, #"{"ok":false,"error":"key","message":"키가 맞지 않아요. 다시 확인해 주세요."}"#, "application/json") }
        do { try await client().connectProvider("openai", apiKey: "sk-test-not-real"); XCTFail() }
        catch { XCTAssertEqual((error as? APIError)?.friendlyMessage, "키가 맞지 않아요. 다시 확인해 주세요.") }
    }

    func testEventsDecodesEachAndKeepsCursors() async throws {
        StubProtocol.handler = { request in
            XCTAssertTrue(request.url?.query?.contains("after=5") == true)
            return (200, #"{"ok":true,"events":[{"type":"notice","seq":6,"at":"2026-11-18T06:19:46Z","text":"t"},{"type":"x","seq":7,"at":"z"}],"lastSeq":7,"oldestSeq":1}"#, "application/json")
        }
        let page = try await client().events(after: 5)
        XCTAssertEqual(page.events.map(\.seq), [6, 7])
        XCTAssertEqual(page.lastSeq, 7)
    }

    func testPairing() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubProtocol.self]
        let session = URLSession(configuration: config)
        let link = try PairingLink.parse("axkit://pair?u=http%3A%2F%2F127.0.0.1%3A47790&n=dev&c=123456")
        StubProtocol.handler = { request in
            XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
            XCTAssertEqual(request.url?.path, "/m/p/dev/app")
            return (200, #"{"ok":true,"deviceId":"d_9","deviceName":"테오 폰","baseUrl":"http://example.com","token":"t"}"#, "application/json")
        }
        let credentials = try await APIClient.pair(link, session: session)
        XCTAssertEqual(credentials.deviceId, "d_9")
        XCTAssertEqual(credentials.baseURL.absoluteString, "http://127.0.0.1:47790", "a public http address from the server is ignored")
        StubProtocol.handler = { _ in (403, #"{"ok":false,"error":"wrong","attemptsLeft":3}"#, "application/json") }
        do { _ = try await APIClient.pair(link, session: session); XCTFail() } catch { XCTAssertEqual(error as? APIError, .wrongCode(attemptsLeft: 3)) }
    }
}

final class StubProtocol: URLProtocol {
    nonisolated(unsafe) static var handler: ((URLRequest) throws -> (Int, String, String))?

    static func body(of request: URLRequest) -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let n = stream.read(&buffer, maxLength: buffer.count)
            if n <= 0 { break }
            data.append(buffer, count: n)
        }
        return data
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            guard let handler = Self.handler else { throw URLError(.badServerResponse) }
            let (status, body, type) = try handler(request)
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: ["Content-Type": type])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(body.utf8))
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }
    override func stopLoading() {}
}

final class RecordingTests: XCTestCase {
    func testChunkMath() {
        XCTAssertEqual(RecordingChunks.count(size: 0, chunk: 10), 1)
        XCTAssertEqual(RecordingChunks.count(size: 25, chunk: 10), 3)
        XCTAssertEqual(RecordingChunks.range(2, size: 25, chunk: 10), 20..<25)
    }

    func testUploadsInChunksResumesAndDeletesFile() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("rec-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let queue = RecordingQueue(folder: folder)
        let bytes = Data(repeating: 7, count: RecordingChunks.size * 2 + 10)
        try bytes.write(to: folder.appendingPathComponent("a.m4a"))
        await queue.add(PendingRecording(id: "r1", fileName: "a.m4a", startedAt: Date(), durationSec: 60, size: bytes.count))

        let seen = SentBox()
        // Network drops on the second chunk.
        let first = await queue.upload { rec, index, data in
            if index == 1 { throw APIError.offline }
            await seen.add("\(index):\(data.count)")
            return ChunkResult(received: index + 1, complete: false)
        }
        XCTAssertTrue(first.isEmpty)
        let reopened = RecordingQueue(folder: folder)
        let sentBefore = await reopened.pending.first?.sentChunks
        XCTAssertEqual(sentBefore, 1, "progress survives a restart")

        let done = await reopened.upload { rec, index, data in
            await seen.add("\(index):\(data.count)")
            return ChunkResult(received: index + 1, complete: index == rec.totalChunks - 1)
        }
        XCTAssertEqual(done, ["r1"])
        let ids = await seen.ids
        XCTAssertEqual(ids, ["0:\(RecordingChunks.size)", "1:\(RecordingChunks.size)", "2:10"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent("a.m4a").path))
        let left = await reopened.pending
        XCTAssertTrue(left.isEmpty)
    }
}

final class BrowserLiveTests: XCTestCase {
    func testStateAndFrameFromTheStream() {
        let state = BrowserLiveUpdate.from(SSEMessage(event: "state", id: nil, data: #"{"live":true,"url":"https://shop.example.com/login","title":"로그인","reason":"login","startedAt":"2026-11-20T03:10:00.000Z","idleClosesAt":"2026-11-20T03:25:00.000Z","extra":1}"#))
        guard case .state(let s) = state else { return XCTFail("state") }
        XCTAssertTrue(s.live)
        XCTAssertEqual(s.host, "shop.example.com")
        XCTAssertEqual(s.reasonWords, "로그인이 필요해요")
        XCTAssertNotNil(s.idleClosesAt)

        let jpeg = Data([0xFF, 0xD8, 0xFF, 0xD9])
        let frame = BrowserLiveUpdate.from(SSEMessage(event: "frame", id: nil, data: #"{"seq":3,"url":"https://a.b","title":"t","width":824,"height":1720,"jpeg":"\#(jpeg.base64EncodedString())"}"#))
        XCTAssertEqual(frame, .frame(BrowserLiveFrame(seq: 3, url: "https://a.b", title: "t", width: 824, height: 1720, jpeg: jpeg)))

        XCTAssertNil(BrowserLiveUpdate.from(SSEMessage(event: "ping", id: nil, data: "{}")))
        let closed = BrowserLiveUpdate.from(SSEMessage(event: "state", id: nil, data: #"{"live":false,"closed":"idle","pending":{"url":"https://x.y/pay","reason":"payment","at":"2026-11-20T03:10:00Z"}}"#))
        guard case .state(let c) = closed else { return XCTFail("closed") }
        XCTAssertEqual(c.closedWords, "한동안 아무것도 하지 않아서 브라우저 화면을 닫았어요.")
        XCTAssertEqual(c.host, "x.y")
        XCTAssertEqual(c.reasonWords, "마지막 결제 버튼은 직접 눌러 주세요")
    }

    func testTapsBecomeJPEGPixels() {
        let image = CGSize(width: 824, height: 1720)
        // Drawn at half size, centred horizontally in a wider box.
        let shown = CGSize(width: 512, height: 860)
        let p = BrowserLiveGeometry.pixel(at: CGPoint(x: 50 + 206, y: 430), shown: shown, image: image)
        XCTAssertEqual(p?.x, 412)
        XCTAssertEqual(p?.y, 860)
        XCTAssertNil(BrowserLiveGeometry.pixel(at: CGPoint(x: 10, y: 10), shown: shown, image: image))
        XCTAssertEqual(BrowserLiveGeometry.pixel(at: CGPoint(x: 462, y: 860), shown: shown, image: image)?.x, 823)
    }

    func testActionBodies() {
        XCTAssertEqual(BrowserLiveAction.scroll(dy: 9000).body["dy"] as? Int, 4000)
        XCTAssertEqual(BrowserLiveAction.type(String(repeating: "a", count: 1200)).body["text"].map { ($0 as! String).count }, 1000)
        XCTAssertEqual(BrowserLiveAction.tap(x: 1, y: 2).name, "tap")
        XCTAssertTrue(BrowserLiveHint.mentions("앱의 브라우저 화면에서 직접 하실 수 있어요. 다 하셨으면 그 화면에서 '다 했어요'를 눌러 주세요."))
        XCTAssertTrue(BrowserLiveHint.mentions("앱의 브라우저 화면에 준비해 뒀어요. 그 화면에서 직접 하시고 '다 했어요'를 눌러 주세요."))
        XCTAssertFalse(BrowserLiveHint.mentions("브라우저로 찾아볼게요"))
        XCTAssertFalse(BrowserLiveHint.mentions("(앱의 브라우저 화면에서 직접 마쳤어요: a.b) 계속해 주세요."))
    }

    func testTheLiveFieldDecidesTheButton() throws {
        func message(_ json: String) throws -> MessageEvent {
            guard case .message(let m) = EventDecoding.event(from: Data(json.utf8)) else { throw XCTSkip("not a message") }
            return m
        }
        let withField = try message(#"{"type":"message","seq":1,"at":"2026-11-20T03:10:00.000Z","role":"assistant","text":"로그인만 해 주시면 이어서 할게요.","live":{"view":"browser-live","reason":"login","url":"https://shop.example.com/login"}}"#)
        XCTAssertEqual(withField.live?.reason, "login")
        XCTAssertTrue(BrowserLiveHint.offers(withField))
        let oldServer = try message(#"{"type":"message","seq":2,"at":"2026-11-20T03:10:00.000Z","role":"assistant","text":"앱의 브라우저 화면에서 직접 하실 수 있어요."}"#)
        XCTAssertTrue(BrowserLiveHint.offers(oldServer))
        let otherView = try message(#"{"type":"message","seq":3,"at":"2026-11-20T03:10:00.000Z","role":"assistant","text":"앱의 브라우저 화면에서 직접 하실 수 있어요.","live":{"view":"something-else"}}"#)
        XCTAssertFalse(BrowserLiveHint.offers(otherView))
        let owner = try message(#"{"type":"message","seq":4,"at":"2026-11-20T03:10:00.000Z","role":"owner","text":"앱의 브라우저 화면 열어 줘"}"#)
        XCTAssertFalse(BrowserLiveHint.offers(owner))
    }

    func testDoneGoesBackWhereTheErrandStarted() throws {
        func done(_ json: String) throws -> BrowserLiveState { try EventDecoding.decoder.decode(BrowserLiveState.self, from: Data(json.utf8)) }
        XCTAssertEqual(try done(#"{"live":false,"resumed":true,"continuedIn":"app"}"#).returnRoom, "")
        XCTAssertEqual(try done(#"{"live":false,"resumed":true,"continuedIn":"app","channel":"bot_shop"}"#).returnRoom, "bot_shop")
        let elsewhere = try done(#"{"live":false,"resumed":true,"continuedIn":"elsewhere"}"#)
        XCTAssertNil(elsewhere.returnRoom)
        XCTAssertTrue(elsewhere.doneWords.contains("디스코드"))
        XCTAssertEqual(try done(#"{"live":false,"resumed":false}"#).doneWords, "브라우저 화면을 닫았어요.")
    }
}

final class ActivityTests: XCTestCase {
    func testActivityIsReadApartFromLogEvents() throws {
        let thinking = Data(#"{"type":"activity","state":"thinking","at":"2026-11-20T03:10:00.000Z"}"#.utf8)
        XCTAssertEqual(ActivityEvent.from(thinking)?.state, .thinking)
        XCTAssertNil(ActivityEvent.from(thinking)?.channel)
        // No seq: never a timeline event.
        XCTAssertNil(EventDecoding.event(from: thinking))
        let message = Data(#"{"type":"message","seq":3,"at":"2026-11-20T03:10:00.000Z","role":"assistant","text":"네"}"#.utf8)
        XCTAssertNil(ActivityEvent.from(message))
        XCTAssertNil(ActivityEvent.from(Data(#"{"type":"activity","state":"dancing"}"#.utf8)))
    }

    func testBoardShowsTheStepAndClears() {
        var board = ActivityBoard()
        let now = Date(timeIntervalSince1970: 1_000)
        board.apply(ActivityEvent(state: .thinking), now: now)
        XCTAssertEqual(board[""]?.words, "생각하는 중")
        board.apply(ActivityEvent(channel: "bot_mail", state: .working, step: "메일 보는 중"), now: now)
        XCTAssertEqual(board["bot_mail"]?.words, "메일 보는 중")
        board.apply(ActivityEvent(channel: "bot_mail", state: .working, step: "웹에서 찾아보는 중…"), now: now)
        XCTAssertEqual(board["bot_mail"]?.words, "웹에서 찾아보는 중")
        board.apply(ActivityEvent(state: .idle), now: now)
        XCTAssertNil(board[""])
        board.answered(in: "bot_mail")
        XCTAssertTrue(board.rooms.isEmpty)
    }

    func testBoardForgetsAfterThreeMinutes() {
        var board = ActivityBoard()
        let start = Date(timeIntervalSince1970: 1_000)
        board.apply(ActivityEvent(state: .thinking), now: start)
        board.apply(ActivityEvent(channel: "team", state: .thinking), now: start.addingTimeInterval(100))
        board.forgetStale(now: start.addingTimeInterval(181))
        XCTAssertNil(board[""])
        XCTAssertNotNil(board["team"])
    }
}

final class ProjectsTests: XCTestCase {
    private let json = #"""
    {"companies":[
      {"name":"에이컴퍼니","projects":[
        {"path":"/u/dev/acompany/web","display":"~/dev/acompany/web","name":"acompany-web","company":"에이컴퍼니","lastActive":"2026-11-20T03:00:00.000Z","claude":12,"codex":3,"picked":true},
        {"path":"/u/dev/acompany/api","display":"~/dev/acompany/api","name":"acompany-api","company":"에이컴퍼니","lastActive":"2026-11-19T03:00:00.000Z","claude":2,"picked":false}]},
      {"name":"dev","projects":[
        {"path":"/u/dev/old","name":"old","company":"dev","picked":true}]}],
     "picked":2,
     "scan":{"status":"running","phase":"projects","counts":{"repos":3,"docs":0,"sessions":45}}}
    """#

    private func view() throws -> ProjectsView { try EventDecoding.decoder.decode(ProjectsView.self, from: Data(json.utf8)) }

    func testReadsTheListAndScan() throws {
        let v = try view()
        XCTAssertEqual(v.companies.map(\.name), ["에이컴퍼니", "dev"])
        XCTAssertNil(v.companies[1].projects[0].lastActive)
        XCTAssertEqual(v.scan?.words, "읽는 중 · 프로젝트 읽는 중")
        XCTAssertEqual(v.scan?.countWords, "저장소 3 · 대화 45")
        let picks = ProjectPicks(v)
        XCTAssertEqual(picks.picked, ["/u/dev/acompany/web", "/u/dev/old"])
    }

    func testSaveSendsTheWholePickedListWithFixedNames() throws {
        var picks = ProjectPicks(try view())
        let api = picks.projects[1], old = picks.projects[2]
        picks.toggle(api)
        picks.toggle(old)
        picks.rename(api, to: "  에이컴퍼니 API  ")
        picks.renameCompany("에이컴퍼니", to: "오키")
        let body = picks.body(rescan: true)
        XCTAssertEqual(body["rescan"] as? Bool, true)
        let list = try XCTUnwrap(body["projects"] as? [[String: Any]])
        XCTAssertEqual(list.map { $0["path"] as? String }, ["/u/dev/acompany/web", "/u/dev/acompany/api"])
        XCTAssertEqual(list.map { $0["name"] as? String }, ["acompany-web", "에이컴퍼니 API"])
        XCTAssertEqual(list.map { $0["company"] as? String }, ["오키", "오키"])
    }

    func testMovingAProjectRegroupsIt() throws {
        var picks = ProjectPicks(try view())
        picks.move(picks.projects[2], to: "에이컴퍼니")
        XCTAssertEqual(picks.groups.map(\.company), ["에이컴퍼니"])
        XCTAssertEqual(picks.groups[0].projects.count, 3)
        picks.move(picks.projects[0], to: "새 회사")
        XCTAssertEqual(picks.groups.map(\.company), ["새 회사", "에이컴퍼니"])
        // Blank names are ignored; long ones are cut to 80.
        picks.rename(picks.projects[1], to: "   ")
        XCTAssertEqual(picks.name(of: picks.projects[1]), "acompany-api")
        picks.rename(picks.projects[1], to: String(repeating: "가", count: 100))
        XCTAssertEqual(picks.name(of: picks.projects[1]).count, 80)
    }
}

final class RoomPickerTests: XCTestCase {
    /// The owner saw the chat jump to another room when the left sheet was dragged; now only a tap on an open list
    /// changes the room, and a tap that arrives after the list closed does nothing.
    func testOnlyATapOnTheOpenListChangesTheRoom() {
        var picker = RoomPicker()
        XCTAssertNil(picker.pick("dev"), "closed list: no room change")
        picker.open()
        XCTAssertEqual(picker.pick("dev"), ["dev"])
        XCTAssertFalse(picker.isOpen)
        XCTAssertNil(picker.pick("ops"), "a late second tap must not switch again")
        picker.open()
        XCTAssertEqual(picker.pick(""), [], "the assistant is the bottom of the stack")
        picker.open(); picker.close()
        XCTAssertNil(picker.pick("dev"), "closing without a pick keeps the room")
    }
}

final class TeamPlanTests: XCTestCase {
    let sample = """
    {"plan":{"id":"p1","createdAt":"2026-11-23T06:00:00Z","status":"proposed","teams":[
      {"company":"스튜디오 오름","name":"브랜드A 리뉴얼","purpose":"로고·가이드 개편","kind":"general",
       "roles":[{"title":"레퍼런스 조사","does":"비슷한 사례를 모아요"}],"tasks":["주간 시안 진행 점검"],
       "routines":[{"title":"시안 진행 점검","instruction":"이번 주 시안 진행 상황을 정리해 알려 줘","schedule":{"kind":"weekly","day":"mon","at":"09:30"}}]},
      {"company":"스튜디오 오름","name":"웹 개발","kind":"dev"},
      {"company":"나","name":"가계부","purpose":"","kind":"general","roles":[],"tasks":[],"routines":[{"title":"정산","instruction":"정리해 줘","schedule":{"kind":"every","hours":3}}]}]}}
    """

    func testReadsThePlanAndSaysTheSchedulesLikeTheCard() throws {
        let view = try JSONDecoder().decode(TeamPlanView.self, from: Data(sample.utf8))
        let plan = try XCTUnwrap(view.plan)
        XCTAssertTrue(plan.isProposed)
        XCTAssertEqual(plan.teams.count, 3)
        XCTAssertTrue(plan.teams[1].isDev)
        XCTAssertEqual(plan.teams[1].roles, [])
        XCTAssertEqual(plan.teams[0].routines[0].schedule.words, "매주 월 09:30")
        XCTAssertEqual(plan.teams[2].routines[0].schedule.words, "3시간마다")
        XCTAssertEqual(PlanSchedule(kind: "daily", at: "08:00").words, "매일 08:00")
        XCTAssertEqual(TeamPlanDraft(teams: plan.teams).groups.map(\.company), ["스튜디오 오름", "나"])
        let none = try JSONDecoder().decode(TeamPlanView.self, from: Data(#"{"plan":null}"#.utf8))
        XCTAssertNil(none.plan)
    }

    func testEditsGoBackAsTheWholeListWithoutLocalIds() throws {
        var draft = TeamPlanDraft(teams: try XCTUnwrap(JSONDecoder().decode(TeamPlanView.self, from: Data(sample.utf8)).plan).teams)
        draft.remove(draft.teams[2].id)
        draft.renameCompany("스튜디오 오름", to: "  오름 스튜디오 ")
        var team = draft.teams[0]
        team.roles.append(PlanRole(title: "  시안 정리 담당자가 하는 아주 긴 역할 이름입니다  ", does: "시안을 모아요"))
        team.routines[0].schedule = PlanSchedule(kind: "daily", day: "mon", at: "07:00")
        draft.update(team)
        XCTAssertNil(draft.problem)

        let body = try draft.body()
        let teams = try XCTUnwrap(body["teams"] as? [[String: Any]])
        XCTAssertEqual(teams.count, 2)
        XCTAssertEqual(teams[0]["company"] as? String, "오름 스튜디오")
        XCTAssertNil(teams[0]["id"])
        let roles = try XCTUnwrap(teams[0]["roles"] as? [[String: Any]])
        XCTAssertEqual(roles.count, 2)
        XCTAssertEqual((roles[1]["title"] as? String)?.count, 20)
        XCTAssertNil(roles[0]["id"])
        let routine = try XCTUnwrap((teams[0]["routines"] as? [[String: Any]])?.first)
        let schedule = try XCTUnwrap(routine["schedule"] as? [String: Any])
        XCTAssertEqual(schedule["kind"] as? String, "daily")
        XCTAssertNil(schedule["day"], "a daily routine sends no day")
    }

    func testProblemsAreSaidBeforeSaving() {
        var team = PlanTeam(company: "나", name: "가계부")
        XCTAssertNil(TeamPlanDraft.problem(in: team))
        team.roles = (1...7).map { PlanRole(title: "역할 \($0)") }
        XCTAssertEqual(TeamPlanDraft.problem(in: team), "직원 역할은 6개까지예요")
        team.roles = [PlanRole(title: " ")]
        XCTAssertEqual(TeamPlanDraft.problem(in: team), "이름이 빈 역할이 있어요")
        team.roles = []
        team.routines = [PlanRoutine(title: "점검", instruction: "해 줘", schedule: PlanSchedule(kind: "weekly", day: "mon", at: "25:00"))]
        XCTAssertEqual(TeamPlanDraft.problem(in: team), "루틴 일정이 맞지 않아요")
        XCTAssertEqual(TeamPlanApplied(teams: 2, routines: 3).words, "팀 2개와 루틴 3개를 만들었어요. 봇 목록에서 볼 수 있어요.")
    }
}

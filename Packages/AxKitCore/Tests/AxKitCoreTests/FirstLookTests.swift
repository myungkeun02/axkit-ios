import XCTest
@testable import AxKitCore

final class FirstLookTests: XCTestCase {
    private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try JSONDecoder().decode(T.self, from: Data(json.utf8))
    }

    func testRunningProgress() throws {
        let v = try decode(FirstLookView.self, """
        {"status":"running","phase":"projects","percent":42,"startedAt":"2026-11-23T01:00:00.000Z",
         "phases":[{"id":"local","label":"폴더 파일","done":400,"total":400,"state":"done"},
                   {"id":"projects","label":"프로젝트 문서·대화 기록","done":12,"total":40,"state":"active"},
                   {"id":"drive","label":"Drive","done":0,"total":0,"state":"waiting"}],
         "counts":{"files":120,"repos":2}}
        """)
        XCTAssertTrue(v.isRunning)
        XCTAssertEqual(v.percent, 42)
        XCTAssertNil(v.result)
        XCTAssertEqual(v.countsText, "폴더 파일 400/400 · 프로젝트 문서·대화 기록 12/40")
        XCTAssertEqual(v.statusWords, "프로젝트 문서·대화 기록 읽는 중")
    }

    func testFailedKeepsReason() throws {
        let v = try decode(FirstLookView.self, #"{"status":"failed","phase":"profile","phases":[],"counts":{},"percent":80,"startedAt":null,"error":"model_unavailable"}"#)
        XCTAssertTrue(v.isFailed)
        XCTAssertEqual(v.error, "model_unavailable")
        XCTAssertEqual(v.countsText, "읽을 것을 세는 중…")
    }

    func testResultTreeAndMissingFields() throws {
        let v = try decode(FirstLookView.self, """
        {"status":"done","phase":"done","phases":[],"counts":{},"percent":100,"startedAt":"2026-11-23T01:00:00Z","finishedAt":"2026-11-23T01:03:12Z",
         "result":{"about":"개발자 겸 운영자","companies":[{"name":"에이컴퍼니","relation":"employer","projects":[
            {"name":"비컴퍼니","purpose":"학습 플랫폼","team":{"kind":"dev","roles":[{"title":"개발","does":"기능을 만들어요"}]},
             "routines":[{"title":"주간 점검","when":"매주 월 09:00","schedule":{"kind":"weekly","day":"mon","at":"09:00"}}]},
            {"name":"메모"}]}],
          "plan":{"id":"p1","status":"proposed"}}}
        """)
        let r = try XCTUnwrap(v.result)
        XCTAssertTrue(v.canBuild)
        XCTAssertEqual(r.companies.first?.relationWords, "다니는 곳")
        let p = try XCTUnwrap(r.companies.first?.projects.first)
        XCTAssertTrue(p.team.isDev)
        XCTAssertEqual(p.routines.first?.when, "매주 월 09:00")
        XCTAssertEqual(r.companies.first?.projects.last?.team.roles.count, 0)
        XCTAssertEqual(v.elapsedText(), "3분 12초")
        let empty = try decode(FirstLookResult.self, #"{"about":"","companies":[],"plan":null}"#)
        XCTAssertNil(empty.plan)
    }

    func testRevisedAndStarted() throws {
        let r = try decode(FirstLookRevised.self, #"{"text":"이렇게 바꿨어요","changed":["a → b"],"skipped":["c"],"result":{"about":"x","companies":[],"plan":null}}"#)
        XCTAssertEqual(r.changed, ["a → b"])
        XCTAssertEqual(r.skipped, ["c"])
        XCTAssertNotNil(r.result)
        let none = try decode(FirstLookRevised.self, #"{"text":"바꿀 것을 못 찾았어요","changed":[],"skipped":[]}"#)
        XCTAssertTrue(none.changed.isEmpty)
        XCTAssertNil(none.result)
        XCTAssertEqual(try decode(FirstLookStarted.self, #"{"scan":"started"}"#).scan, "started")
    }
}

final class WorkTests: XCTestCase {
    func testDecodesWorkViewAndKeepsUnknownKinds() throws {
        let json = #"""
        {"title":"하고 있는 일","active":[{"id":"dev:job_1","kind":"dev","title":"owner/repo: 파서 고치기","status":"running","phase":"테스트 중",
          "startedAt":"2026-11-23T00:00:00.000Z","updatedAt":"2026-11-23T00:11:30.000Z","elapsedMinutes":12,"origin":{"channelId":"channel.app","address":"owner"}},
          {"id":"x","kind":"routine","title":"새 종류","status":"thinking"}, {"broken":true}],
         "recent":[{"id":"browser_1","kind":"browser","title":"가격 알아보기","status":"done","summary":"마쳤어요","link":"https://example.com/item","elapsedMinutes":40},
          {"id":"dev:2","kind":"dev","title":"브랜치","status":"failed","link":"fix/a"}]}
        """#
        let work = try EventDecoding.decoder.decode(WorkView.self, from: Data(json.utf8))
        XCTAssertEqual(work.active.count, 2)
        XCTAssertEqual(work.active[0].statusWords, "하는 중")
        XCTAssertEqual(work.active[0].elapsedWords, "12분째")
        XCTAssertEqual(work.active[1].kindWords, "routine")
        XCTAssertEqual(work.active[1].statusWords, "thinking")
        XCTAssertEqual(work.recent[0].elapsedWords, "40분 걸림")
        XCTAssertNotNil(work.recent[0].webLink)
        XCTAssertNil(work.recent[1].webLink)
    }

    func testWorkNoticesDecodeKindAndLive() throws {
        let json = #"{"type":"notice","seq":5,"at":"2026-11-23T00:00:00Z","text":"멈췄어요","kind":"browser.task","live":{"view":"browser-live","reason":"로그인"}}"#
        guard case .notice(let n)? = EventDecoding.event(from: Data(json.utf8)) else { return XCTFail() }
        XCTAssertEqual(WorkNotice.label(n.kind), "브라우저 심부름 결과")
        XCTAssertTrue(BrowserLiveHint.offers(n))
        // Today's server sends neither kind nor live: the sentence decides.
        let plain = NoticeEvent(seq: 6, at: Date(), text: "로그인은 앱의 브라우저 화면에서 직접 하실 수 있어요.")
        XCTAssertTrue(BrowserLiveHint.offers(plain))
    }

    func testOvernightDigestAndJobStart() {
        let d = WorkNotice.digest("밤사이 소식 3건\n· 메일 2통\n- 일정 하나 바뀜\n1. 결제 끝남")
        XCTAssertEqual(d.title, "밤사이 소식 3건")
        XCTAssertEqual(d.lines, ["메일 2통", "일정 하나 바뀜", "결제 끝남"])
        XCTAssertTrue(WorkNotice.startsJob("시작했어요. 끝나면 알려드릴게요. (작업 job_1a2b3c4d)"))
        XCTAssertFalse(WorkNotice.startsJob("시작했어요"))
        XCTAssertEqual(FirstLookView.errorWords("TimeoutError").hasPrefix("시간이"), true)
    }
}

final class PeopleDictationTests: XCTestCase {
    func testPeopleDecodeLossyAndSearch() throws {
        let json = """
        {"title":"사람","people":[{"key":"p:kim","name":"김민수","names":["김민수","김 대표"],"title":"대표","company":"에이컴퍼니","relation":"회사 대표","note":"결정이 빠름\\n\\n아침형","emails":2,"openCommitments":2,"updatedAt":"2026-11-24T01:00:00.000Z"},{"name":"키 없음"},{"key":"p:x","title":""}]}
        """
        let view = try EventDecoding.decoder.decode(PeopleView.self, from: Data(json.utf8))
        XCTAssertEqual(view.people.count, 2)
        let noh = view.people[0]
        XCTAssertEqual(noh.roleLine, "대표 · 에이컴퍼니")
        XCTAssertEqual(noh.otherNames, ["김 대표"])
        XCTAssertEqual(noh.noteLines, ["결정이 빠름", "아침형"])
        XCTAssertNotNil(noh.updatedAt)
        XCTAssertTrue(noh.matches("에이컴퍼니 대표"))
        XCTAssertTrue(noh.matches("김 대표"))
        XCTAssertFalse(noh.matches("디자이너"))
        XCTAssertNil(view.people[1].title)
        XCTAssertEqual(view.people[1].name, "p:x")
    }

    func testEditBodySendsOnlyChangesAndEmptiesAsBlank() {
        let p = Person(key: "k", name: "n", title: "대표", company: "에이컴퍼니", relation: nil, note: "a")
        var form = PersonForm(p)
        XCTAssertEqual(form.editBody(for: p), ["key": "k"])
        form.title = "  "
        form.relation = "친구 "
        XCTAssertEqual(form.editBody(for: p), ["key": "k", "title": "", "relation": "친구"])
        form.note = String(repeating: "가", count: 450); form.title = String(repeating: "a", count: 41)
        form.clamp()
        XCTAssertEqual(form.note.count, 400); XCTAssertEqual(form.title.count, 40)
        form.note = ""; form.title = "  "
        let after = form.applied(to: p)
        XCTAssertNil(after.title)
        XCTAssertEqual(after.relation, "친구")
    }

    func testDictationHelpers() {
        XCTAssertEqual(DictationRules.insert("안녕", into: ""), "안녕")
        XCTAssertEqual(DictationRules.insert(" 안녕 ", into: "네"), "네 안녕")
        XCTAssertEqual(DictationRules.insert("안녕", into: "네 "), "네 안녕")
        XCTAssertEqual(DictationRules.insert("  ", into: "네"), "네")
        XCTAssertEqual(DictationRules.clock(102), "1:42")
        XCTAssertEqual(DictationRules.meter(-60), 0)
        XCTAssertEqual(DictationRules.meter(0), 1)
        XCTAssertEqual(DictationRules.meter(-.infinity), 0)
        XCTAssertEqual(DictationAnswer.decode(Data(#"{"text":" 안녕 "}"#.utf8)), DictationAnswer(text: "안녕"))
        XCTAssertEqual(DictationAnswer.decode(Data(#"{"text":"","message":"못 들었어요"}"#.utf8)), DictationAnswer(text: "", message: "못 들었어요"))
    }
}

final class WorkSheetMentionTests: XCTestCase {
    private func item(_ id: String, _ status: String, parent: String? = nil, address: String? = nil) -> WorkItem {
        WorkItem(id: id, kind: "bot", title: id, status: status, parent: parent, origin: address.map { .init(channelId: "channel.app", address: $0) })
    }

    func testActiveTreeHoldsFinishedParentOpen() {
        let work = WorkView(active: [item("c1", "running", parent: "p"), item("solo", "queued"), item("c2", "waiting", parent: "p"), item("g", "running", parent: "c1")],
                            recent: [item("p", "done"), item("old", "done"), item("oldkid", "done", parent: "old")])
        let rows = WorkSheet.active(work)
        XCTAssertEqual(rows.map(\.id), ["p", "c1", "g", "c2", "solo"])
        XCTAssertEqual(rows.map(\.depth), [0, 1, 2, 1, 0])
        let recent = WorkSheet.recent(work, limit: 5)
        XCTAssertEqual(recent.map(\.id), ["old", "oldkid"])
        XCTAssertEqual(recent.map(\.depth), [0, 1])
        XCTAssertEqual(WorkSheet.strip(work), "하는 중 4개 · c1")
        XCTAssertNil(WorkSheet.strip(WorkView()))
    }

    func testRecentLimitAndLoops() {
        let many = (0..<8).map { item("r\($0)", "done") }
        XCTAssertEqual(WorkSheet.recent(WorkView(recent: many), limit: 3).count, 3)
        let loop = WorkView(active: [item("a", "running", parent: "b"), item("b", "running", parent: "a")])
        XCTAssertEqual(Set(WorkSheet.active(loop).map(\.id)), ["a", "b"])
    }

    func testRoomForAddress() throws {
        let bots = try JSONDecoder().decode(BotsView.self, from: Data(#"{"groups":[{"id":"g","label":"카페","bots":[{"id":"stock","name":"재고 팀장","channel":"stock-room"}]}]}"#.utf8))
        XCTAssertEqual(item("x", "done", address: "owner").room(bots: bots), "")
        XCTAssertEqual(item("x", "done", address: "bot:stock").room(bots: bots), "stock-room")
        XCTAssertNil(item("x", "done", address: "bot:ghost").room(bots: bots))
        XCTAssertEqual(item("x", "done", address: "bot:stock").room(bots: nil), "stock")
        XCTAssertNil(item("x", "done").room(bots: bots))
        XCTAssertEqual(item("x", "done").kindWords, "봇에게 맡긴 일")
    }

    func testMentions() throws {
        XCTAssertEqual(Mentions.query(in: "@"), "")
        XCTAssertEqual(Mentions.query(in: "이거 @재고"), "재고")
        XCTAssertNil(Mentions.query(in: "메일 a@b"))
        XCTAssertNil(Mentions.query(in: "@재고 팀장 "))
        XCTAssertNil(Mentions.query(in: "안녕"))
        let bots = try JSONDecoder().decode(BotsView.self, from: Data(#"{"groups":[{"id":"g","label":"카페","bots":[{"id":"stock","name":"재고 팀장","channel":"stock"},{"id":"store","name":"매장 팀장","channel":"store","status":"off"},{"id":"qa","name":"검사 봇","channel":"qa"}]}]}"#.utf8))
        XCTAssertEqual(Mentions.candidates(bots.allBots, query: "").map(\.id), ["stock", "qa"])
        XCTAssertEqual(Mentions.candidates(bots.allBots, query: "팀장").map(\.id), ["stock"])
        XCTAssertEqual(Mentions.candidates(bots.allBots, query: "QA").map(\.id), ["qa"])
        XCTAssertEqual(Mentions.insert("재고 팀장", into: "이거 @재"), "이거 @재고 팀장 ")
    }
}

final class LocationRepeatTests: XCTestCase {
    func testLocationPolicy() {
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        let home = LocationPolicy.Fix(lat: 37.5, lng: 127.0, accuracy: 30, at: t0)
        XCTAssertTrue(LocationPolicy.shouldSend(home, last: nil))
        var vague = home; vague.accuracy = 5000
        XCTAssertFalse(LocationPolicy.shouldSend(vague, last: nil))
        var invalid = home; invalid.accuracy = -1
        XCTAssertFalse(LocationPolicy.shouldSend(invalid, last: nil))
        var soon = home; soon.at = t0.addingTimeInterval(120)
        XCTAssertFalse(LocationPolicy.shouldSend(soon, last: home))
        XCTAssertTrue(LocationPolicy.shouldSend(soon, last: home, opening: true))
        var later = home; later.at = t0.addingTimeInterval(11 * 60)
        XCTAssertTrue(LocationPolicy.shouldSend(later, last: home))
        var moved = soon; moved.lat += 0.002 // about 220 m north
        XCTAssertTrue(LocationPolicy.shouldSend(moved, last: home))
        XCTAssertEqual(LocationPolicy.distance(home, moved), 222, accuracy: 5)
    }

    func testRepeatGuard() {
        var g = RepeatGuard(window: 3)
        let t = Date(timeIntervalSince1970: 0)
        XCTAssertTrue(g.allow("안녕", in: "", at: t))
        XCTAssertFalse(g.allow("안녕 ", in: "", at: t.addingTimeInterval(1)))
        XCTAssertTrue(g.allow("안녕", in: "dev", at: t.addingTimeInterval(1.5)))
        XCTAssertTrue(g.allow("안녕", in: "dev", at: t.addingTimeInterval(5)))
        XCTAssertTrue(g.allow("안녕하세요", in: "dev", at: t.addingTimeInterval(5.1)))
    }
}

final class BlockRowMessageTests: XCTestCase {
    func testRowMessageMakesRowTappable() throws {
        let json = """
        {"title":"드라이브","blocks":[{"kind":"list","title":"오늘 · 2건","rows":[
          {"title":"11월 매출 정리","detail":"모아카페","trailing":"14:05","message":"드라이브의 \\"11월 매출 정리\\" 내용을 요약해 줘"},
          {"title":"견적서","message":"   "},
          {"title":"근무표"}]}]}
        """
        let v = try JSONDecoder().decode(BlocksView.self, from: Data(json.utf8))
        let rows = try XCTUnwrap(v.blocks.first?.rows)
        XCTAssertEqual(rows[0].tapMessage, "드라이브의 \"11월 매출 정리\" 내용을 요약해 줘")
        XCTAssertNil(rows[1].tapMessage)
        XCTAssertNil(rows[2].tapMessage)
        XCTAssertEqual(rows[2].trailing, nil)
    }
}

import XCTest
@testable import AxKitCore

final class ChatTextTests: XCTestCase {
    func testDiscordLeftoversGo() {
        XCTAssertEqual(ChatText.clean("<@123456789> 확인했어요 :white_check_mark:"), "확인했어요 ✅")
        XCTAssertEqual(ChatText.clean("<#998877> 방에 올렸어요 <:blob:1234>"), "방에 올렸어요")
        XCTAssertEqual(ChatText.clean("이상한 :not_a_real_code: 코드"), "이상한 코드")
        XCTAssertEqual(ChatText.clean("-# 작은 글"), "작은 글")
        XCTAssertEqual(ChatText.clean("||비밀||"), "비밀")
        XCTAssertFalse(ChatText.clean("시간 <t:1763600000:R>").contains("<t:"))
        // URLs and times keep their colons.
        XCTAssertEqual(ChatText.clean("https://example.com/a:b 오후 3:20"), "https://example.com/a:b 오후 3:20")
    }

    func testBlockMarkdownBecomesPlainLines() {
        XCTAssertEqual(ChatText.clean("## 결론\n> 인용\n- 하나\n```\ncode\n```"), "**결론**\n인용\n• 하나\ncode")
    }

    func testMetadataAndPromptBlocksAreCut() {
        let note = "슬랙에서 빼자고 했어요.\n\neventId: 8648\nsource: slack / account: x\nfrom: joy\n\n원문\n<knowledge_x>\n- 비밀 맥락\n</knowledge_x>"
        XCTAssertEqual(ChatText.clean(note), "슬랙에서 빼자고 했어요.")
        XCTAssertEqual(ChatText.clean("앞 글\n<knowledge_abc>\n안 닫힘"), "앞 글")
        XCTAssertEqual(ChatText.cardTitle(summary: "eventId: 8648", note: note), "슬랙에서 빼자고 했어요.")
        XCTAssertEqual(ChatText.cardTitle(summary: "노트북 살까요?", note: nil), "노트북 살까요?")
        // One ordinary "Note: …" line in the middle stays.
        XCTAssertEqual(ChatText.clean("Note: 그대로\n다음 줄"), "Note: 그대로\n다음 줄")
    }

    func testInternalIdsAndEnglishRoleWords() {
        XCTAssertEqual(ChatText.clean("🛠️ Engineer 시작: 로그인 고치기 · v2-ax-qa-web-4ac6f8339bea2b7d · ax/qa-web-4ac6f8339bea2b7d-2026-11-18"),
                       "🛠️ 개발 봇 시작: 로그인 고치기")
        XCTAssertEqual(ChatText.clean("승인 카드를 올렸어요 (head a614e74)"), "승인 카드를 올렸어요")
        XCTAssertEqual(ChatText.clean("개발팀에 넘겼어요 (작업 37ac4816): 홈 피드"), "개발팀에 넘겼어요: 홈 피드")
        XCTAssertEqual(ChatText.clean("→ #결재"), "→ 결재 탭")
        XCTAssertEqual(ChatText.clean("보고 — #일상에 알림"), "보고 — 일상 방에 알림")
        XCTAssertEqual(ChatText.clean("PR #712 반영"), "PR #712 반영")
        XCTAssertEqual(ChatText.clean("[https://a.com/__%EC%97%86%EB%8A%94] 화면"), "[https://a.com/__없는] 화면")
        XCTAssertEqual(ChatText.clean("⚠️ ⚠️ 출시 없이 정리됨"), "⚠️ 출시 없이 정리됨")
    }

    func testPreviewIsOneLine() {
        XCTAssertEqual(ChatText.preview("**굵게**\n- 하나\n- 둘"), "굵게 · 하나 · 둘")
        XCTAssertEqual(ChatText.preview(String(repeating: "가", count: 200), limit: 10).count, 10)
    }

    func testBotTalkParses() {
        let ask = BotTalk.parse("💬 Leo → Mia · 검토 요청: Leo입니다. 이렇게 바꾸자는 제안이 나왔어요.")
        XCTAssertEqual(ask?.from, "Leo"); XCTAssertEqual(ask?.to, "Mia"); XCTAssertEqual(ask?.label, "검토 요청"); XCTAssertEqual(ask?.isReply, false)
        let reply = BotTalk.parse("↩️ Mia → Leo · 답 (승인): Leo, 방향은 승인해요.\n둘째 줄")
        XCTAssertEqual(reply?.from, "Mia"); XCTAssertEqual(reply?.isReply, true); XCTAssertEqual(reply?.text, "Leo, 방향은 승인해요.\n둘째 줄")
        XCTAssertNil(BotTalk.parse("🛠️ Engineer 시작: 로그인 고치기"))
    }
}

final class RoomFeedTests: XCTestCase {
    let zone = Format.seoul
    let now = ISO8601DateFormatter().date(from: "2026-11-20T03:00:00Z")!

    private func at(_ iso: String) -> Date { ISO8601DateFormatter().date(from: iso)! }
    private func notice(_ seq: Int, _ text: String, _ iso: String = "2026-11-20T01:00:00Z") -> Timeline.Item {
        .notice(NoticeEvent(seq: seq, at: at(iso), text: text, channel: "개발"))
    }
    private func message(_ seq: Int, _ text: String, author: String? = nil, to: String? = nil, owner: Bool = false, _ iso: String = "2026-11-20T01:00:00Z") -> Timeline.Item {
        .message(MessageEvent(seq: seq, at: at(iso), role: owner ? .owner : .assistant, text: text, channel: "개발",
                              author: author.map { Author(id: $0.lowercased(), name: $0) }, to: to.map { Author(id: $0.lowercased(), name: $0) }))
    }
    private let leo = RoomFeed.Speaker(id: "engineering", name: "Leo")

    private func entries(_ rows: [RoomFeed.Row]) -> [RoomFeed.Entry] {
        rows.compactMap { if case .entry(let e) = $0 { e } else { nil } }
    }

    func testRepliesFoldUnderTheQuestion() {
        let rows = RoomFeed.build([
            notice(1, "💬 Leo → Mia · 검토 요청: 바꿔도 될까요?"),
            notice(2, "↩️ Mia → Leo · 답 (승인): 좋아요."),
        ], room: "개발", lead: leo, assistant: "비서", now: now, zone: zone)
        let list = entries(rows)
        XCTAssertEqual(list.count, 1)
        XCTAssertEqual(list[0].speaker.name, "Leo")
        XCTAssertEqual(list[0].to, "Mia")
        XCTAssertEqual(list[0].replies.map(\.speaker.name), ["Mia"])
        XCTAssertEqual(rows.first, .day("오늘"))
    }

    func testAuthorlessNoticesSpeakForTheLeadAndGroup() {
        let rows = RoomFeed.build([
            notice(1, "🛠️ Engineer 시작: 하나"),
            notice(2, "✅ 끝: 하나"),
            message(3, "제가 볼게요", author: "Nora"),
            message(4, "확인 부탁해요", owner: true),
        ], room: "개발", lead: leo, assistant: "비서", now: now, zone: zone)
        let list = entries(rows)
        XCTAssertEqual(list.map(\.speaker.name), ["Leo", "Leo", "Nora", "나"])
        XCTAssertEqual(list.map(\.showHeader), [true, false, true, true])
        XCTAssertTrue(list[0].isStatus)
        XCTAssertEqual(list[0].text, "🛠️ 개발 봇 시작: 하나")
    }

    func testLongRunsFoldKeepingTheNewestTwo() {
        let items = (1...6).map { notice($0, "작업 \($0)") }
        let rows = RoomFeed.build(items, room: "개발", lead: leo, assistant: "비서", now: now, zone: zone)
        guard case .folded(let f) = rows[1] else { return XCTFail("\(rows)") }
        XCTAssertEqual(f.entries.count, 4)
        XCTAssertEqual(f.title, "이전 작업 기록 4개")
        XCTAssertEqual(entries(rows).map(\.text), ["작업 5", "작업 6"])

        let talk = (1...5).map { notice($0, "💬 Leo → \($0 % 2 == 0 ? "Mia" : "Victor") · 질문: 질문 \($0)") }
        let talkRows = RoomFeed.build(talk, room: "개발", lead: leo, assistant: "비서", now: now, zone: zone)
        guard case .folded(let g) = talkRows[1] else { return XCTFail("\(talkRows)") }
        XCTAssertEqual(g.title, "Leo·Victor·Mia의 대화 3개")
    }

    func testALongRunFromOneBotFolds() {
        let rows = RoomFeed.build((1...9).map { message($0, "✅ \($0)단계", author: "Leo") }, room: "개발", lead: leo, assistant: "비서", now: now, zone: zone)
        guard case .folded(let f) = rows[1] else { return XCTFail("\(rows)") }
        XCTAssertEqual(f.title, "Leo의 이전 글 7개")
        XCTAssertEqual(entries(rows).count, 2)
        // A short run stays as it is.
        XCTAssertEqual(entries(RoomFeed.build((1...5).map { message($0, "글 \($0)", author: "Leo") }, room: "개발", lead: leo, assistant: "비서", now: now, zone: zone)).count, 5)
    }

    func testRepeatsAndDays() {
        let rows = RoomFeed.build([
            notice(1, "선택지를 기록했어요", "2026-11-18T01:00:00Z"),
            notice(2, "선택지를 기록했어요", "2026-11-18T01:00:05Z"),
            message(3, "안녕", author: "Leo", "2026-11-19T01:00:00Z"),
            message(4, "다시", author: "Leo", "2026-11-20T01:00:00Z"),
        ], room: "개발", lead: leo, assistant: "비서", now: now, zone: zone)
        XCTAssertEqual(rows.compactMap { if case .day(let d) = $0 { d } else { nil } }, ["11월 18일 수요일", "어제", "오늘"])
        XCTAssertEqual(entries(rows).first?.repeats, 2)
    }

    func testThreadLinesFoldUnderTheFirst() {
        func line(_ seq: Int, _ text: String, start: Bool = false) -> Timeline.Item {
            var m = MessageEvent(seq: seq, at: at("2026-11-20T01:00:00Z"), role: .assistant, text: text, channel: "개발", author: Author(id: "leo", name: "Leo"))
            m.thread = EventThread(id: "app-th-1", title: "로그인 다시 확인", start: start)
            return .message(m)
        }
        let rows = RoomFeed.build([line(1, "맡았어요.", start: true), message(2, "다른 말", author: "Nora"), line(3, "📋 계획"), line(4, "🏁 결과")],
                                  room: "개발", lead: leo, assistant: "비서", now: now, zone: zone)
        let list = entries(rows)
        XCTAssertEqual(list.map(\.text), ["맡았어요.", "다른 말"])
        XCTAssertEqual(list[0].replies.map(\.text), ["📋 계획", "🏁 결과"])
        XCTAssertEqual(list[0].threadTitle, "로그인 다시 확인")
    }

    func testReactionAndReadEvents() throws {
        var t = Timeline()
        for json in [#"{"type":"message","seq":1,"at":"2026-11-20T01:00:00Z","role":"assistant","text":"hi","channel":"개발"}"#,
                     #"{"type":"reaction","seq":2,"at":"2026-11-20T01:00:01Z","target":1,"emoji":"👍","by":{"id":"leo","name":"Leo"},"channel":"개발"}"#,
                     #"{"type":"read","seq":3,"channel":"개발","upTo":1}"#] {
            t.apply(try XCTUnwrap(EventDecoding.event(from: Data(json.utf8))))
        }
        XCTAssertEqual(t.reactions[1], ["👍": 1])
        XCTAssertEqual(t.unreadCount(in: "개발"), 0)
        XCTAssertEqual(t.items(in: "개발").count, 1)
    }

    /// The assistant speaking first in the main room (briefing, important mail) is its bubble with an 알림 chip.
    func testMainRoomNoticesAreAssistantBubbles() {
        let rows = RoomFeed.build([.notice(NoticeEvent(seq: 1, at: now, text: "오늘 브리핑"))], room: "", lead: nil, assistant: "비서", now: now, zone: zone)
        XCTAssertEqual(rows.count, 2)
        let entry = try? XCTUnwrap(entries(rows).first)
        XCTAssertEqual(entry?.speaker.name, "비서")
        XCTAssertEqual(entry?.isNotice, true)
        XCTAssertEqual(entry?.text, "오늘 브리핑")
    }

    /// The owner sending the same words twice sees both; only bots' repeats fold into "×2".
    func testOwnerRepeatsAreNotMerged() {
        let rows = RoomFeed.build([message(1, "확인해 줘", owner: true), message(2, "확인해 줘", owner: true)],
                                  room: "개발", lead: leo, assistant: "비서", now: now, zone: zone)
        XCTAssertEqual(entries(rows).map(\.repeats), [1, 1])
    }
}

final class KoreanSearchTests: XCTestCase {
    func testSpacesCaseAndPartialWords() {
        XCTAssertTrue(KoreanSearch.matches("결제/PG 정리", "결제pg"))
        XCTAssertTrue(KoreanSearch.matches("앱 후원 멤버십", "후원멤버"))
        XCTAssertFalse(KoreanSearch.matches("법무·정책", "결제"))
    }

    func testInitialSounds() {
        XCTAssertTrue(KoreanSearch.matches("결제 화면", "ㄱㅈ"))
        XCTAssertTrue(KoreanSearch.matches("결제 화면", "ㄱㅈㅎ"))
        XCTAssertFalse(KoreanSearch.matches("법무", "ㄱㅈ"))
    }

    func testRangeAndSnippet() {
        let text = "토스 본인 확인 계약"
        let r = KoreanSearch.range(in: text, of: "본인확인")
        XCTAssertEqual(r.map { String(text[$0]) }, "본인 확인")
        XCTAssertEqual(KoreanSearch.range(in: "결제 화면", of: "ㅎㅁ").map { String("결제 화면"[$0]) }, "화면")
        XCTAssertEqual(KoreanSearch.snippet("# 제목\n- **토스 본인확인**: 아직 안 했어요", "본인확인"), "토스 본인확인: 아직 안 했어요")
        XCTAssertNil(KoreanSearch.snippet("없음", "결제"))
    }
}

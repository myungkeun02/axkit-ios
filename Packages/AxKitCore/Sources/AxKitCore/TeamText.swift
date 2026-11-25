import Foundation

/// §37 팀 만들기: one text → a team. `POST views/bots/createTeamFromText {text, group?}` →
/// `{teamId, channel, group, name, purpose, members:[{id,name,role}], briefKept}`. The Mac's model turns the owner's own
/// words into a name, a purpose, 2–6 members named after their jobs, and a brief kept with the lead.
public enum TeamText {
    public static let min = 5
    public static let max = 6000

    public static let placeholder = [
        "예) 유튜브 영상 제작팀이 필요해요.",
        "- 매주 화·금 영상 2개: 기획 → 대본 → 촬영 목록 → 편집 지시 → 썸네일·제목",
        "- 채널은 \"모아카페 TV\", 20~30대 직장인 대상, 말투는 친근하게",
        "- 편집은 외주 편집자에게 넘기니 편집 지시서를 꼭 써 줘요",
        "- 올리기 전엔 꼭 저한테 물어봐 주세요",
    ].joined(separator: "\n")

    /// Why the text can't go yet, or nil.
    public static func problem(_ text: String) -> String? {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.count < min { return "어떤 팀인지 조금만 더 적어 주세요." }
        if t.count > max { return "6,000자까지 적을 수 있어요." }
        return nil
    }

    public struct Built: Decodable, Hashable, Sendable {
        public struct Member: Decodable, Hashable, Sendable, Identifiable {
            public var id: String
            public var name: String
            public var role: String
        }
        public var teamId: String
        public var channel: String
        public var group: String?
        public var name: String
        public var purpose: String
        public var members: [Member]
        public var briefKept: Bool

        private enum Keys: String, CodingKey { case teamId, channel, group, name, purpose, members, briefKept }
        private struct RawMember: Decodable { var id: String?; var name: String?; var role: String? }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: Keys.self)
            func str(_ k: Keys) -> String { ((try? c.decodeIfPresent(String.self, forKey: k)) ?? nil)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "" }
            teamId = str(.teamId); channel = str(.channel); name = str(.name); purpose = str(.purpose)
            guard !teamId.isEmpty, !channel.isEmpty, !name.isEmpty else {
                throw DecodingError.dataCorruptedError(forKey: .teamId, in: c, debugDescription: "team without id, room or name")
            }
            let g = str(.group)
            group = g.isEmpty ? nil : g
            let raw = (try? c.decodeIfPresent([Lossy<RawMember>].self, forKey: .members)) ?? nil
            members = (raw ?? []).compactMap(\.value).compactMap { m in
                guard let id = m.id?.trimmingCharacters(in: .whitespaces), !id.isEmpty,
                      let name = m.name?.trimmingCharacters(in: .whitespaces), !name.isEmpty else { return nil }
                return Member(id: id, name: name, role: m.role?.trimmingCharacters(in: .whitespaces) ?? "")
            }
            briefKept = ((try? c.decodeIfPresent(Bool.self, forKey: .briefKept)) ?? nil) == true
        }
    }
}

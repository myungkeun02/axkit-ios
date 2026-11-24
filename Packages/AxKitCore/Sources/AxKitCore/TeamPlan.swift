import Foundation

/// §24 팀 구조 미리보기 (`team-plan`): the teams the Mac proposes from the work map, before it builds them.
public struct TeamPlanView: Decodable, Sendable {
    public var plan: TeamPlan?
}

public struct TeamPlan: Codable, Hashable, Sendable {
    public var id: String
    public var createdAt: String?
    /// proposed | applied | declined
    public var status: String
    public var appliedAt: String?
    public var teams: [PlanTeam]

    public var isProposed: Bool { status == "proposed" }

    /// "만들었어요" / "만들지 않았어요" for an old plan, nil while it waits for the owner.
    public var pastWords: String? {
        switch status {
        case "applied": "만들었어요"
        case "declined": "만들지 않았어요"
        default: nil
        }
    }
}

public struct PlanRole: Codable, Hashable, Sendable, Identifiable {
    /// Local only (never sent): keeps a row steady while its title is edited.
    public var id = UUID()
    public var title: String
    public var does: String

    public init(title: String, does: String = "") { self.title = title; self.does = does }
    enum CodingKeys: String, CodingKey { case title, does }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        title = try c.decode(String.self, forKey: .title)
        does = try c.decodeIfPresent(String.self, forKey: .does) ?? ""
    }
}

public struct PlanSchedule: Codable, Hashable, Sendable {
    /// daily | weekly | every
    public var kind: String
    public var day: String?
    public var at: String?
    public var hours: Int?

    public init(kind: String, day: String? = nil, at: String? = nil, hours: Int? = nil) {
        self.kind = kind; self.day = day; self.at = at; self.hours = hours
    }

    public static let days = ["mon", "tue", "wed", "thu", "fri", "sat", "sun"]
    public static let dayWords = ["mon": "월", "tue": "화", "wed": "수", "thu": "목", "fri": "금", "sat": "토", "sun": "일"]

    /// "매일 09:30", "매주 월 09:30", "3시간마다" (same words as the Mac's card).
    public var words: String {
        switch kind {
        case "every": "\(hours ?? 1)시간마다"
        case "daily": "매일 \(at ?? "")"
        default: "매주 \(Self.dayWords[day ?? ""] ?? day ?? "") \(at ?? "")"
        }
    }

    /// Only the fields its kind uses go to the Mac.
    public var cleaned: PlanSchedule {
        switch kind {
        case "every": PlanSchedule(kind: "every", hours: min(max(hours ?? 1, 1), 24))
        case "daily": PlanSchedule(kind: "daily", at: at ?? "09:00")
        default: PlanSchedule(kind: "weekly", day: Self.days.contains(day ?? "") ? day : "mon", at: at ?? "09:00")
        }
    }

    public var isValid: Bool {
        switch kind {
        case "every": return (1...24).contains(hours ?? 0)
        case "daily": return Self.validTime(at)
        case "weekly": return Self.days.contains(day ?? "") && Self.validTime(at)
        default: return false
        }
    }

    static func validTime(_ text: String?) -> Bool {
        guard let text else { return false }
        return text.range(of: #"^([01]\d|2[0-3]):[0-5]\d$"#, options: .regularExpression) != nil
    }
}

public struct PlanRoutine: Codable, Hashable, Sendable, Identifiable {
    public var id = UUID()
    public var title: String
    public var instruction: String
    public var schedule: PlanSchedule

    public init(title: String, instruction: String, schedule: PlanSchedule) {
        self.title = title; self.instruction = instruction; self.schedule = schedule
    }
    enum CodingKeys: String, CodingKey { case title, instruction, schedule }
}

public struct PlanTeam: Codable, Hashable, Sendable, Identifiable {
    public var id = UUID()
    public var company: String
    public var name: String
    public var purpose: String
    /// general | dev (a dev team gets a reviewer bot)
    public var kind: String
    public var roles: [PlanRole]
    public var tasks: [String]
    public var routines: [PlanRoutine]

    public var isDev: Bool { kind == "dev" }

    public init(company: String, name: String, purpose: String = "", kind: String = "general",
                roles: [PlanRole] = [], tasks: [String] = [], routines: [PlanRoutine] = []) {
        self.company = company; self.name = name; self.purpose = purpose; self.kind = kind
        self.roles = roles; self.tasks = tasks; self.routines = routines
    }
    enum CodingKeys: String, CodingKey { case company, name, purpose, kind, roles, tasks, routines }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        company = try c.decode(String.self, forKey: .company)
        name = try c.decode(String.self, forKey: .name)
        purpose = try c.decodeIfPresent(String.self, forKey: .purpose) ?? ""
        kind = try c.decodeIfPresent(String.self, forKey: .kind) ?? "general"
        roles = try c.decodeIfPresent([PlanRole].self, forKey: .roles) ?? []
        tasks = try c.decodeIfPresent([String].self, forKey: .tasks) ?? []
        routines = try c.decodeIfPresent([PlanRoutine].self, forKey: .routines) ?? []
    }
}

/// The owner's edits to a proposed plan. The whole list goes back on save (§24.2), so edits stay here until then.
public struct TeamPlanDraft: Equatable, Sendable {
    public static let maxTeams = 24, maxRoles = 6, maxRoutines = 5
    public static let roleTitleLimit = 20, roleDoesLimit = 120, teamNameLimit = 60, companyLimit = 80, purposeLimit = 300
    public static let routineTitleLimit = 60, instructionLimit = 1000

    public var teams: [PlanTeam]

    public init(teams: [PlanTeam] = []) { self.teams = teams }

    public struct Group: Identifiable, Equatable, Sendable {
        public var id: String { company }
        public var company: String
        public var teams: [PlanTeam]
    }

    /// Companies in the order their first team appears.
    public var groups: [Group] {
        var out: [Group] = []
        for team in teams {
            if let i = out.firstIndex(where: { $0.company == team.company }) { out[i].teams.append(team) }
            else { out.append(Group(company: team.company, teams: [team])) }
        }
        return out
    }

    public mutating func remove(_ team: PlanTeam.ID) { teams.removeAll { $0.id == team } }

    public mutating func update(_ team: PlanTeam) {
        guard let i = teams.firstIndex(where: { $0.id == team.id }) else { return }
        teams[i] = Self.tidy(team)
    }

    /// Every team of that company moves under the new name. Blank names are ignored.
    public mutating func renameCompany(_ old: String, to new: String) {
        let name = String(new.trimmingCharacters(in: .whitespacesAndNewlines).prefix(Self.companyLimit))
        guard !name.isEmpty else { return }
        for i in teams.indices where teams[i].company == old { teams[i].company = name }
    }

    /// Trims and cuts text to what the Mac accepts; keeps at most 6 roles and 5 routines.
    public static func tidy(_ team: PlanTeam) -> PlanTeam {
        func cut(_ s: String, _ n: Int) -> String { String(s.trimmingCharacters(in: .whitespacesAndNewlines).prefix(n)) }
        var t = team
        t.company = cut(t.company, companyLimit)
        t.name = cut(t.name, teamNameLimit)
        t.purpose = cut(t.purpose, purposeLimit)
        t.roles = Array(t.roles.prefix(maxRoles)).map { var r = $0; r.title = cut(r.title, roleTitleLimit); r.does = cut(r.does, roleDoesLimit); return r }
        t.routines = Array(t.routines.prefix(maxRoutines)).map {
            var r = $0; r.title = cut(r.title, routineTitleLimit); r.instruction = cut(r.instruction, instructionLimit); r.schedule = r.schedule.cleaned; return r
        }
        return t
    }

    /// Why this team can't be saved yet, in plain words; nil when it's fine.
    public static func problem(in team: PlanTeam) -> String? {
        if team.name.trimmingCharacters(in: .whitespaces).isEmpty { return "팀 이름을 써 주세요" }
        if team.company.trimmingCharacters(in: .whitespaces).isEmpty { return "회사 이름을 써 주세요" }
        if team.roles.count > maxRoles { return "직원 역할은 \(maxRoles)개까지예요" }
        if team.roles.contains(where: { $0.title.trimmingCharacters(in: .whitespaces).isEmpty }) { return "이름이 빈 역할이 있어요" }
        if team.roles.contains(where: { $0.title.count > roleTitleLimit }) { return "역할 이름은 \(roleTitleLimit)자까지예요" }
        if team.routines.count > maxRoutines { return "루틴은 팀마다 \(maxRoutines)개까지예요" }
        if team.routines.contains(where: { $0.title.trimmingCharacters(in: .whitespaces).isEmpty || $0.instruction.trimmingCharacters(in: .whitespaces).isEmpty }) {
            return "제목이나 하는 일이 빈 루틴이 있어요"
        }
        if team.routines.contains(where: { !$0.schedule.isValid }) { return "루틴 일정이 맞지 않아요" }
        return nil
    }

    public var problem: String? {
        if teams.count > Self.maxTeams { return "팀은 \(Self.maxTeams)개까지예요" }
        for team in teams { if let p = Self.problem(in: team) { return "\(team.name.isEmpty ? "이름 없는 팀" : team.name): \(p)" } }
        return nil
    }

    /// `{teams: [...]}` for POST views/team-plan/save — the whole list, without the app's local ids.
    public func body() throws -> [String: Any] {
        let data = try JSONEncoder().encode(teams.map(Self.tidy))
        let list = try JSONSerialization.jsonObject(with: data)
        return ["teams": list]
    }
}

public struct TeamPlanSaved: Decodable, Sendable { public var saved: Int }
public struct TeamPlanApplied: Decodable, Sendable {
    public var teams: Int
    public var routines: Int

    public var words: String {
        if teams == 0 && routines == 0 { return "이미 만든 팀 구조예요. 새로 만든 것은 없어요." }
        return "팀 \(teams)개" + (routines > 0 ? "와 루틴 \(routines)개" : "") + "를 만들었어요. 봇 목록에서 볼 수 있어요."
    }
}
public struct TeamPlanDeclined: Decodable, Sendable { public var declined: Bool }

public extension CardEvent {
    /// The Mac's "일 지도대로 이렇게 팀을 만들까요?" card (its 앱에서 고칠게요 choice opens the team-plan screen).
    var isTeamPlan: Bool { topic?.hasPrefix("bots:team-plan") == true }
    /// Its "앱에서 고칠게요" choice: open the screen, send nothing (server 870e742 uses fix-in-app).
    static let teamPlanFixInApp: Set<String> = ["fix-in-app", "edit"]
}

public extension APIClient {
    func teamPlan() async throws -> TeamPlanView { try await view(TeamPlanView.self, "team-plan") }
    func saveTeamPlan(_ draft: TeamPlanDraft) async throws -> TeamPlanSaved {
        try await viewAction(TeamPlanSaved.self, "team-plan", "save", json: try draft.body())
    }
    func applyTeamPlan() async throws -> TeamPlanApplied { try await viewAction(TeamPlanApplied.self, "team-plan", "apply", json: [:]) }
    func declineTeamPlan() async throws -> TeamPlanDeclined { try await viewAction(TeamPlanDeclined.self, "team-plan", "decline", json: [:]) }
}

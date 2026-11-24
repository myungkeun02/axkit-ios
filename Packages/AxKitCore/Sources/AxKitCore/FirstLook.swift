import Foundation

/// §27 처음 알아보기 (`first-look`): the first look's live progress, the result tree and fixing it by words.
public struct FirstLookView: Decodable, Sendable, Equatable {
    /// The server's error is a code ("TimeoutError", "AbortError" …): plain words for the owner instead.
    public static func errorWords(_ code: String?) -> String {
        let c = (code ?? "").lowercased()
        if c.contains("timeout") || c.contains("abort") { return "시간이 너무 오래 걸렸어요. 다시 시작하면 이어서 읽어요." }
        if c.contains("network") || c.contains("fetch") || c.contains("econn") || c.contains("enotfound") { return "인터넷에 닿지 않았어요. 연결을 확인하고 다시 시작해 주세요." }
        if c.contains("auth") || c.contains("401") || c.contains("403") || c.contains("key") { return "AI 연결이 거절됐어요. 더보기 › AI 연결하기를 확인해 주세요." }
        if c.contains("rate") || c.contains("429") || c.contains("quota") { return "AI 사용 한도에 걸렸어요. 조금 뒤에 다시 시작해 주세요." }
        return "맥에서 예상하지 못한 문제가 생겼어요. 다시 시작해 주세요."
    }

    /// idle | running | paused | done | failed
    public var status: String
    /// local | projects | drive | signals | profile | done
    public var phase: String
    public var phases: [FirstLookPhase]
    public var counts: [String: Int]
    public var percent: Int
    public var startedAt: String?
    public var finishedAt: String?
    public var error: String?
    public var result: FirstLookResult?

    public init(status: String = "idle", phase: String = "local", phases: [FirstLookPhase] = [], counts: [String: Int] = [:],
                percent: Int = 0, startedAt: String? = nil, finishedAt: String? = nil, error: String? = nil, result: FirstLookResult? = nil) {
        self.status = status; self.phase = phase; self.phases = phases; self.counts = counts; self.percent = percent
        self.startedAt = startedAt; self.finishedAt = finishedAt; self.error = error; self.result = result
    }

    enum CodingKeys: String, CodingKey { case status, phase, phases, counts, percent, startedAt, finishedAt, error, result }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        status = try c.decodeIfPresent(String.self, forKey: .status) ?? "idle"
        phase = try c.decodeIfPresent(String.self, forKey: .phase) ?? "local"
        phases = try c.decodeIfPresent([FirstLookPhase].self, forKey: .phases) ?? []
        counts = try c.decodeIfPresent([String: Int].self, forKey: .counts) ?? [:]
        let p = (try? c.decodeIfPresent(Double.self, forKey: .percent)) ?? 0
        percent = Int(min(max(p, 0), 100).rounded())
        startedAt = try c.decodeIfPresent(String.self, forKey: .startedAt)
        finishedAt = try c.decodeIfPresent(String.self, forKey: .finishedAt)
        error = try c.decodeIfPresent(String.self, forKey: .error)
        result = try c.decodeIfPresent(FirstLookResult.self, forKey: .result)
    }

    public var isRunning: Bool { status == "running" }
    public var isPaused: Bool { status == "paused" }
    public var isFailed: Bool { status == "failed" }
    public var isDone: Bool { status == "done" }
    public var isIdle: Bool { status == "idle" }
    /// The owner can still fix or build the proposal.
    public var canBuild: Bool { result?.plan?.status == "proposed" }

    /// "폴더 파일 120/400 · 프로젝트 문서·대화 기록 12/40": every phase that has something to read.
    public var countsText: String {
        let parts = phases.filter { $0.total > 0 }.map { "\($0.label) \($0.done)/\($0.total)" }
        return parts.isEmpty ? "읽을 것을 세는 중…" : parts.joined(separator: " · ")
    }

    /// What it is doing now, in plain words.
    public var statusWords: String {
        switch status {
        case "running":
            if let active = phases.first(where: { $0.state == "active" }) { return "\(active.label) 읽는 중" }
            return "준비 중"
        case "paused": return "멈춰 있어요"
        case "done": return "다 읽었어요"
        case "failed": return "멈췄어요"
        default: return "아직 시작 전이에요"
        }
    }

    /// "3분 12초" / "45초" / "1시간 5분"; empty before it started.
    public func elapsedText(now: Date = Date()) -> String {
        guard let start = startedAt.flatMap(ISODates.parse) else { return "" }
        let end = (finishedAt.flatMap(ISODates.parse)).flatMap { isRunning ? nil : $0 } ?? now
        let s = max(0, Int(end.timeIntervalSince(start)))
        if s >= 3600 { return "\(s / 3600)시간 \((s % 3600) / 60)분" }
        if s >= 60 { return "\(s / 60)분 \(s % 60)초" }
        return "\(s)초"
    }
}

public struct FirstLookPhase: Decodable, Sendable, Equatable, Identifiable {
    public var id: String
    public var label: String
    public var done: Int
    public var total: Int
    /// waiting | active | done
    public var state: String

    public init(id: String, label: String, done: Int = 0, total: Int = 0, state: String = "waiting") {
        self.id = id; self.label = label; self.done = done; self.total = total; self.state = state
    }
}

public struct FirstLookResult: Decodable, Sendable, Equatable {
    public var about: String
    public var companies: [FirstLookCompany]
    public var plan: FirstLookPlanRef?

    public init(about: String = "", companies: [FirstLookCompany] = [], plan: FirstLookPlanRef? = nil) {
        self.about = about; self.companies = companies; self.plan = plan
    }
    enum CodingKeys: String, CodingKey { case about, companies, plan }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        about = try c.decodeIfPresent(String.self, forKey: .about) ?? ""
        companies = try c.decodeIfPresent([FirstLookCompany].self, forKey: .companies) ?? []
        plan = try c.decodeIfPresent(FirstLookPlanRef.self, forKey: .plan)
    }
}

public struct FirstLookPlanRef: Decodable, Sendable, Equatable {
    public var id: String
    /// proposed | applied | declined
    public var status: String
}

public struct FirstLookCompany: Decodable, Sendable, Equatable, Identifiable {
    public var id: String { name }
    public var name: String
    /// employer | own | client | partner | personal
    public var relation: String
    public var projects: [FirstLookProject]

    public init(name: String, relation: String = "employer", projects: [FirstLookProject] = []) {
        self.name = name; self.relation = relation; self.projects = projects
    }
    enum CodingKeys: String, CodingKey { case name, relation, projects }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        relation = try c.decodeIfPresent(String.self, forKey: .relation) ?? "employer"
        projects = try c.decodeIfPresent([FirstLookProject].self, forKey: .projects) ?? []
    }

    public static let relationWords = ["employer": "다니는 곳", "own": "내 사업", "client": "고객사", "partner": "협력사", "personal": "개인"]
    public var relationWords: String { Self.relationWords[relation] ?? relation }
}

public struct FirstLookProject: Decodable, Sendable, Equatable, Identifiable {
    public var id: String { name }
    public var name: String
    public var purpose: String
    public var team: FirstLookTeam
    public var routines: [FirstLookRoutine]

    public init(name: String, purpose: String = "", team: FirstLookTeam = FirstLookTeam(), routines: [FirstLookRoutine] = []) {
        self.name = name; self.purpose = purpose; self.team = team; self.routines = routines
    }
    enum CodingKeys: String, CodingKey { case name, purpose, team, routines }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        purpose = try c.decodeIfPresent(String.self, forKey: .purpose) ?? ""
        team = try c.decodeIfPresent(FirstLookTeam.self, forKey: .team) ?? FirstLookTeam()
        routines = try c.decodeIfPresent([FirstLookRoutine].self, forKey: .routines) ?? []
    }
}

public struct FirstLookTeam: Decodable, Sendable, Equatable {
    /// dev | general
    public var kind: String
    public var roles: [FirstLookRole]

    public init(kind: String = "general", roles: [FirstLookRole] = []) { self.kind = kind; self.roles = roles }
    enum CodingKeys: String, CodingKey { case kind, roles }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        kind = try c.decodeIfPresent(String.self, forKey: .kind) ?? "general"
        roles = try c.decodeIfPresent([FirstLookRole].self, forKey: .roles) ?? []
    }
    public var isDev: Bool { kind == "dev" }
}

public struct FirstLookRole: Decodable, Sendable, Equatable, Identifiable {
    public var id: String { title }
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

public struct FirstLookRoutine: Decodable, Sendable, Equatable, Identifiable {
    public var id: String { "\(when)|\(title)" }
    public var title: String
    /// "매주 월 09:00" (already words); falls back to the schedule.
    public var when: String
    public var schedule: PlanSchedule?

    public init(title: String, when: String = "", schedule: PlanSchedule? = nil) { self.title = title; self.when = when; self.schedule = schedule }
    enum CodingKeys: String, CodingKey { case title, when, schedule }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        title = try c.decode(String.self, forKey: .title)
        schedule = try? c.decodeIfPresent(PlanSchedule.self, forKey: .schedule)
        when = try c.decodeIfPresent(String.self, forKey: .when) ?? schedule?.words ?? ""
    }
}

/// `POST views/first-look/revise` answer.
public struct FirstLookRevised: Decodable, Sendable, Equatable {
    public var text: String
    public var changed: [String]
    public var skipped: [String]
    public var result: FirstLookResult?

    enum CodingKeys: String, CodingKey { case text, changed, skipped, result }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        text = try c.decodeIfPresent(String.self, forKey: .text) ?? ""
        changed = try c.decodeIfPresent([String].self, forKey: .changed) ?? []
        skipped = try c.decodeIfPresent([String].self, forKey: .skipped) ?? []
        result = try c.decodeIfPresent(FirstLookResult.self, forKey: .result)
    }
}

/// `POST views/first-look/start` answer: started | running.
public struct FirstLookStarted: Decodable, Sendable, Equatable { public var scan: String }

public enum FirstLookLimits { public static let reviseMax = 500 }

public extension APIClient {
    func firstLook() async throws -> FirstLookView { try await view(FirstLookView.self, "first-look") }
    func reviseFirstLook(_ text: String) async throws -> FirstLookRevised {
        try await viewAction(FirstLookRevised.self, "first-look", "revise", json: ["text": text])
    }
    /// Same answer as team-plan/apply: `{teams, routines}`.
    func applyFirstLook() async throws -> TeamPlanApplied { try await viewAction(TeamPlanApplied.self, "first-look", "apply", json: [:]) }
    func startFirstLook() async throws -> FirstLookStarted { try await viewAction(FirstLookStarted.self, "first-look", "start", json: [:]) }
}

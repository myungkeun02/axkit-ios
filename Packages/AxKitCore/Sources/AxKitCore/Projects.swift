import Foundation

// §23 프로젝트 가져오기: which projects the first look reads, grouped by company. The owner picks them, fixes names and
// moves a project to another company; saving sends the whole picked list.

public struct ProjectsView: Decodable, Equatable, Sendable {
    public struct Project: Decodable, Equatable, Sendable, Identifiable {
        public var id: String { path }
        public var path: String
        public var display: String?
        public var name: String
        public var company: String
        public var remote: String?
        /// nil = picked before but not found any more (can only be taken out).
        public var lastActive: Date?
        public var claude: Int?
        public var codex: Int?
        public var picked: Bool?

        public init(path: String, display: String? = nil, name: String, company: String, remote: String? = nil,
                    lastActive: Date? = nil, claude: Int? = nil, codex: Int? = nil, picked: Bool? = nil) {
            self.path = path; self.display = display; self.name = name; self.company = company; self.remote = remote
            self.lastActive = lastActive; self.claude = claude; self.codex = codex; self.picked = picked
        }
    }

    public struct Company: Decodable, Equatable, Sendable {
        public var name: String
        public var projects: [Project]
    }

    public struct Scan: Decodable, Equatable, Sendable {
        public var status: String?
        public var phase: String?
        public var counts: [String: Int]?
        public var finishedAt: Date?

        public var running: Bool { status == "running" }

        /// "읽는 중 · 프로젝트 읽기" and the like.
        public var words: String {
            let state = switch status {
            case "running": "읽는 중"
            case "paused": "잠시 멈춤"
            case "done": "다 읽었어요"
            case "failed": "읽다가 멈췄어요"
            default: "아직 읽지 않았어요"
            }
            guard running, let phase = phaseWords else { return state }
            return "\(state) · \(phase)"
        }

        public var phaseWords: String? {
            switch phase {
            case "local": "이 맥에서 찾는 중"
            case "projects": "프로젝트 읽는 중"
            case "drive": "드라이브 읽는 중"
            case "signals": "메일·일정 살피는 중"
            case "profile": "정리하는 중"
            case "done": "마무리"
            default: nil
            }
        }

        /// "저장소 3 · 문서 120 · 대화 45 · 요약 12" (only the non-zero ones).
        public var countWords: String? {
            guard let counts else { return nil }
            let labels: [(String, String)] = [("repos", "저장소"), ("files", "파일"), ("docs", "문서"), ("sessions", "대화"),
                                              ("drive", "드라이브"), ("summarized", "요약"), ("signals", "신호")]
            let parts = labels.compactMap { key, label in counts[key].flatMap { $0 > 0 ? "\(label) \($0)" : nil } }
            return parts.isEmpty ? nil : parts.joined(separator: " · ")
        }
    }

    public var companies: [Company]
    public var picked: Int?
    public var scan: Scan?
}

/// The owner's picks and fixed names, on top of what the Mac found.
public struct ProjectPicks: Equatable, Sendable {
    public static let nameLimit = 80
    public static let maxProjects = 200

    public private(set) var projects: [ProjectsView.Project] = []
    public private(set) var picked: Set<String> = []
    private var names: [String: String] = [:]
    private var companies: [String: String] = [:]

    public init() {}

    public init(_ view: ProjectsView) {
        projects = view.companies.flatMap(\.projects)
        picked = Set(projects.filter { $0.picked == true }.map(\.path))
    }

    public func name(of p: ProjectsView.Project) -> String { names[p.path] ?? p.name }
    public func company(of p: ProjectsView.Project) -> String { companies[p.path] ?? p.company }
    public func isPicked(_ p: ProjectsView.Project) -> Bool { picked.contains(p.path) }

    public mutating func toggle(_ p: ProjectsView.Project) {
        if picked.contains(p.path) { picked.remove(p.path) } else { picked.insert(p.path) }
    }

    public mutating func rename(_ p: ProjectsView.Project, to name: String) {
        let n = Self.clean(name)
        guard !n.isEmpty else { return }
        names[p.path] = n == p.name ? nil : n
    }

    /// Moves one project to another (or a new) company.
    public mutating func move(_ p: ProjectsView.Project, to company: String) {
        let c = Self.clean(company)
        guard !c.isEmpty else { return }
        companies[p.path] = c == p.company ? nil : c
    }

    /// Renames a company: every project now under `old` goes under `new`.
    public mutating func renameCompany(_ old: String, to new: String) {
        let c = Self.clean(new)
        guard !c.isEmpty else { return }
        for p in projects where company(of: p) == old { companies[p.path] = c == p.company ? nil : c }
    }

    /// Companies in the Mac's order (most recent first), with moved projects under their new company.
    public struct Group: Equatable, Identifiable, Sendable {
        public var id: String { company }
        public var company: String
        public var projects: [ProjectsView.Project]
    }

    public var groups: [Group] {
        var order: [String] = []
        var byCompany: [String: [ProjectsView.Project]] = [:]
        for p in projects {
            let c = company(of: p)
            if byCompany[c] == nil { order.append(c) }
            byCompany[c, default: []].append(p)
        }
        return order.map { Group(company: $0, projects: byCompany[$0] ?? []) }
    }

    /// Something the server would refuse, in plain words (nil when it can be saved).
    public var problem: String? {
        if picked.count > Self.maxProjects { return "프로젝트는 \(Self.maxProjects)개까지 고를 수 있어요." }
        return nil
    }

    /// `POST views/projects/save` body.
    public func body(rescan: Bool) -> [String: Any] {
        let list: [[String: Any]] = projects.filter { picked.contains($0.path) }.map {
            ["path": $0.path, "name": name(of: $0), "company": company(of: $0)]
        }
        return ["projects": list, "rescan": rescan]
    }

    static func clean(_ text: String) -> String {
        String(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(nameLimit))
    }
}

public struct ProjectsSaved: Decodable, Sendable {
    public var saved: Int?
    /// `started` · `running` when `rescan` was asked for.
    public var scan: String?
}

public extension APIClient {
    func projects(refresh: Bool = false) async throws -> ProjectsView {
        try await view(ProjectsView.self, "projects", query: refresh ? ["refresh": "1"] : [:])
    }

    func refreshProjects() async throws -> ProjectsView {
        try await viewAction(ProjectsView.self, "projects", "refresh", json: [:])
    }

    func saveProjects(_ picks: ProjectPicks, rescan: Bool) async throws -> ProjectsSaved {
        try await viewAction(ProjectsSaved.self, "projects", "save", json: picks.body(rescan: rescan))
    }
}

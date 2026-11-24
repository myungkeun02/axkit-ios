import AxKitCore
import SwiftUI

/// 프로젝트 가져오기 (§23): which projects the first look reads, by company. Tick them, fix names, move one to another
/// company or rename a company, then save (and read now, or at the next night's check).
struct ProjectsScreen: View {
    @Environment(AppModel.self) private var model
    @State private var state: Loadable<ProjectsView> = .loading
    @State private var picks = ProjectPicks()
    @State private var saved = ProjectPicks()
    @State private var editing: ProjectsView.Project?
    @State private var renamingCompany: String?
    @State private var companyText = ""
    @State private var saving = false

    private var changed: Bool { picks != saved }

    var body: some View {
        LoadableView(state: state, retry: { await load() }) { data in
            Page {
                scanPanel(data)
                if picks.projects.isEmpty {
                    Panel {
                        Text("아직 찾은 프로젝트가 없어요. 맥의 설정에서 고른 폴더의 git 저장소와 Claude Code·Codex 대화 기록이 있는 폴더를 찾아요.")
                            .font(.subheadline).foregroundStyle(.secondary)
                    }
                }
                ForEach(picks.groups) { group in
                    companyPanel(group.company, group.projects)
                }
                if !picks.projects.isEmpty { saveButtons }
            }
            .refreshable { await refresh() }
        }
        .navigationTitle("프로젝트 가져오기")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .sheet(item: $editing) { p in
            ProjectEditSheet(project: p, name: picks.name(of: p), company: picks.company(of: p),
                             companies: picks.groups.map(\.company)) { name, company in
                picks.rename(p, to: name)
                picks.move(p, to: company)
            }
        }
        .alert("회사 이름 바꾸기", isPresented: Binding(get: { renamingCompany != nil }, set: { if !$0 { renamingCompany = nil } })) {
            TextField("회사 이름", text: $companyText)
            Button("취소", role: .cancel) {}
            Button("바꾸기") { if let old = renamingCompany { picks.renameCompany(old, to: companyText) } }
        } message: {
            Text("이 회사의 프로젝트가 모두 새 이름 아래로 가요. 저장해야 맥에 반영돼요.")
        }
    }

    // MARK: pieces

    private func scanPanel(_ data: ProjectsView) -> some View {
        let scan = data.scan
        return Panel {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    if scan?.running == true { ProgressView().controlSize(.small) }
                    Text(scan?.words ?? "아직 읽지 않았어요").font(.headline)
                    Spacer(minLength: 0)
                    Text("\(picks.picked.count)개 고름").font(.footnote).foregroundStyle(.secondary)
                }
                if let counts = scan?.countWords {
                    Text(counts).font(.footnote).foregroundStyle(.secondary)
                }
                if let at = scan?.finishedAt, scan?.running != true {
                    Text("마지막으로 다 읽은 때: \(Format.relative(at))").font(.footnote).foregroundStyle(.secondary)
                }
                Text("처음 읽을 때는 꼼꼼히 다 읽어서 몇십 분에서 몇 시간 걸릴 수 있어요. 진행 소식은 대화창으로 알려 드려요.")
                    .font(.caption).foregroundStyle(.tertiary)
            }
        }
    }

    private func companyPanel(_ company: String, _ projects: [ProjectsView.Project]) -> some View {
        Panel {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    CardHeader(title: company, subtitle: "\(projects.filter { picks.isPicked($0) }.count) / \(projects.count)개 고름")
                    Spacer(minLength: 0)
                    Button("이름 바꾸기") { companyText = company; renamingCompany = company }
                        .font(.footnote)
                        .accessibilityLabel("\(company) 회사 이름 바꾸기")
                }
                CardList(items: projects) { p in row(p) }
            }
        }
    }

    private func row(_ p: ProjectsView.Project) -> some View {
        let on = picks.isPicked(p)
        let missing = p.lastActive == nil
        return HStack(alignment: .center, spacing: 12) {
            Button { picks.toggle(p) } label: {
                Image(systemName: on ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(on ? Color.accentColor : Color.secondary)
            }
            .buttonStyle(.plain)
            .disabled(missing && !on)
            .accessibilityLabel(on ? "\(picks.name(of: p)) 빼기" : "\(picks.name(of: p)) 고르기")
            VStack(alignment: .leading, spacing: 3) {
                Text(picks.name(of: p)).foregroundStyle(missing ? .secondary : .primary)
                Text(p.display ?? p.path).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                Text(detail(p)).font(.caption).foregroundStyle(missing ? Color.orange : .secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .onTapGesture { picks.toggle(p) }
            Button { editing = p } label: {
                Image(systemName: "pencil").font(.footnote.weight(.semibold))
            }
            .buttonStyle(.bordered)
            .accessibilityLabel("\(picks.name(of: p)) 이름·회사 고치기")
        }
        .padding(.vertical, 8)
        .accessibilityElement(children: .contain)
    }

    private func detail(_ p: ProjectsView.Project) -> String {
        guard let at = p.lastActive else { return "지금은 찾지 못한 폴더예요 · 빼기만 할 수 있어요" }
        var parts = ["\(Format.relative(at)) 작업"]
        if let n = p.claude, n > 0 { parts.append("Claude \(n)") }
        if let n = p.codex, n > 0 { parts.append("Codex \(n)") }
        return parts.joined(separator: " · ")
    }

    private var saveButtons: some View {
        VStack(spacing: 8) {
            if let problem = picks.problem {
                Text(problem).font(.footnote).foregroundStyle(.red)
            }
            Button { Task { await save(rescan: true) } } label: { Text("저장하고 바로 읽기").frame(maxWidth: .infinity) }
                .buttonStyle(.action(.primary))
            Button { Task { await save(rescan: false) } } label: { Text("저장만").frame(maxWidth: .infinity) }
                .buttonStyle(.action(.secondary))
            Text(changed ? "아직 저장하지 않은 바뀐 것이 있어요. '저장만'이면 다음 날 새벽 정기 확인 때 읽어요." : "'저장만'이면 다음 날 새벽 정기 확인 때 읽어요.")
                .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .disabled(saving || picks.problem != nil)
        .padding(.horizontal, 4)
    }

    // MARK: work

    private func show(_ data: ProjectsView) {
        state = .loaded(data)
        picks = ProjectPicks(data)
        saved = picks
    }

    private func load() async {
        guard let client = model.client else { return }
        do { show(try await client.projects()) } catch { state = .failed(error.friendly) }
    }

    private func refresh() async {
        guard let client = model.client else { return }
        if changed { model.toast = "새로 고치면 저장하지 않은 바뀐 것은 사라져요." }
        do { show(try await client.refreshProjects()) } catch { model.toast = error.friendly }
    }

    private func save(rescan: Bool) async {
        guard let client = model.client else { return }
        saving = true
        defer { saving = false }
        do {
            let answer = try await client.saveProjects(picks, rescan: rescan)
            let n = answer.saved ?? picks.picked.count
            model.toast = switch answer.scan {
            case "started": "\(n)개를 저장하고 읽기 시작했어요."
            case "running": "\(n)개를 저장했어요. 지금 읽는 중이라 끝나면 다시 볼게요."
            default: "\(n)개를 저장했어요. 다음 날 새벽에 읽어요."
            }
            await load()
        } catch {
            model.toast = error.friendly
        }
    }
}

/// Fix one project's name, or move it to another company.
private struct ProjectEditSheet: View {
    var project: ProjectsView.Project
    @State var name: String
    @State var company: String
    var companies: [String]
    var onSave: (String, String) -> Void
    @Environment(\.dismiss) private var dismiss

    init(project: ProjectsView.Project, name: String, company: String, companies: [String], onSave: @escaping (String, String) -> Void) {
        self.project = project; self.companies = companies; self.onSave = onSave
        _name = State(initialValue: name); _company = State(initialValue: company)
    }

    private var valid: Bool {
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines), c = company.trimmingCharacters(in: .whitespacesAndNewlines)
        return !n.isEmpty && !c.isEmpty && n.count <= ProjectPicks.nameLimit && c.count <= ProjectPicks.nameLimit
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("프로젝트 이름", text: $name)
                } footer: {
                    Text(project.display ?? project.path)
                }
                Section {
                    TextField("회사 이름", text: $company)
                    ForEach(companies.filter { $0 != company }, id: \.self) { c in
                        Button { company = c } label: { Label(c, systemImage: "arrow.right") }
                    }
                } header: {
                    Text("회사")
                } footer: {
                    Text("다른 회사로 옮기려면 그 회사를 누르거나 새 이름을 쓰세요. 저장해야 맥에 반영돼요.")
                }
            }
            .navigationTitle("프로젝트 고치기")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("취소") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("완료") { onSave(name, company); dismiss() }.disabled(!valid)
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

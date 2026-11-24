import AxKitCore
import SwiftUI

/// 팀 구조 제안 (§24): the teams the Mac wants to build from the work map, by company — each team's purpose, staff
/// roles and routines. While it is a proposal the owner can drop teams and fix names, roles and routines, then build it
/// as is or not at all. Applied or declined plans stay readable as a past record.
struct TeamPlanScreen: View {
    @Environment(AppModel.self) private var model
    @State private var state: Loadable<TeamPlanView> = .loading
    @State private var draft = TeamPlanDraft()
    @State private var saved = TeamPlanDraft()
    @State private var editing: PlanTeam?
    @State private var renamingCompany: String?
    @State private var companyText = ""
    @State private var working = false
    @State private var confirmDecline = false
    @State private var result: String?

    private var changed: Bool { draft != saved }

    var body: some View {
        LoadableView(state: state, retry: { await load() }) { data in
            Page {
                if let plan = data.plan {
                    header(plan)
                    ForEach(draft.groups) { group in companyPanel(group, editable: plan.isProposed) }
                    if plan.isProposed { buttons }
                } else {
                    Panel {
                        Text("지금은 제안된 팀 구조가 없어요. 처음 알아보기가 회사와 프로젝트를 찾으면 여기에 제안이 와요.")
                            .font(.subheadline).foregroundStyle(.secondary)
                    }
                }
            }
            .refreshable { await load() }
        }
        .navigationTitle("팀 구조")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .sheet(item: $editing) { team in
            PlanTeamEditSheet(team: team, companies: draft.groups.map(\.company)) { edited in
                draft.update(edited)
            } onRemove: {
                draft.remove(team.id)
            }
        }
        .alert("회사 이름 바꾸기", isPresented: Binding(get: { renamingCompany != nil }, set: { if !$0 { renamingCompany = nil } })) {
            TextField("회사 이름", text: $companyText)
            Button("취소", role: .cancel) {}
            Button("바꾸기") { if let old = renamingCompany { draft.renameCompany(old, to: companyText) } }
        } message: {
            Text("이 회사의 팀이 모두 새 이름 아래로 가요.")
        }
        .confirmationDialog("이 팀 구조를 만들지 않을까요?", isPresented: $confirmDecline, titleVisibility: .visible) {
            Button("만들지 않기", role: .destructive) { Task { await decline() } }
            Button("취소", role: .cancel) {}
        } message: {
            Text("제안서를 버려요. 팀은 나중에 봇 목록에서 직접 만들 수 있어요.")
        }
        .alert("팀 구조를 만들었어요", isPresented: Binding(get: { result != nil }, set: { if !$0 { result = nil } })) {
            Button("확인", role: .cancel) {}
        } message: {
            Text(result ?? "")
        }
    }

    // MARK: pieces

    private func header(_ plan: TeamPlan) -> some View {
        Panel {
            VStack(alignment: .leading, spacing: 6) {
                if let past = plan.pastWords {
                    Text("지난 팀 구조 제안 · \(past)").font(.headline)
                    if let at = plan.appliedAt.flatMap(ISODates.parse) {
                        Text("만든 때: \(Format.relative(at))").font(.footnote).foregroundStyle(.secondary)
                    }
                    Text("만든 뒤에는 봇 목록과 루틴 화면에서 고쳐요.").font(.footnote).foregroundStyle(.secondary)
                } else {
                    Text("일 지도대로 이렇게 팀을 만들까요?").font(.headline)
                    Text("팀 \(draft.teams.count)개 · 직원 \(draft.teams.reduce(0) { $0 + $1.roles.count })명 · 루틴 \(draft.teams.reduce(0) { $0 + $1.routines.count })개")
                        .font(.footnote).foregroundStyle(.secondary)
                    Text("팀을 빼거나 이름·역할·루틴을 고친 뒤 만들 수 있어요. 개발팀에는 검수 봇이 함께 붙어요.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func companyPanel(_ group: TeamPlanDraft.Group, editable: Bool) -> some View {
        Panel {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    CardHeader(title: group.company, subtitle: "팀 \(group.teams.count)개")
                    Spacer(minLength: 0)
                    if editable {
                        Button("이름 바꾸기") { companyText = group.company; renamingCompany = group.company }
                            .font(.footnote)
                            .accessibilityLabel("\(group.company) 회사 이름 바꾸기")
                    }
                }
                ForEach(group.teams) { team in
                    teamBlock(team, editable: editable)
                    if team.id != group.teams.last?.id { Divider() }
                }
            }
        }
    }

    private func teamBlock(_ team: PlanTeam, editable: Bool) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(team.name).font(.body.weight(.semibold))
                Text(team.isDev ? "개발 · 검수 포함" : "일반")
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 7).padding(.vertical, 2)
                    .background(Color.secondary.opacity(0.12), in: Capsule())
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
                if editable {
                    Button { editing = team } label: { Image(systemName: "pencil").font(.footnote.weight(.semibold)) }
                        .buttonStyle(.bordered)
                        .accessibilityLabel("\(team.name) 고치기")
                }
            }
            if !team.purpose.isEmpty { Text(team.purpose).font(.subheadline).foregroundStyle(.secondary) }
            if let problem = TeamPlanDraft.problem(in: team) {
                Text(problem).font(.footnote).foregroundStyle(.red)
            }
            if !team.roles.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(team.roles) { role in
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Image(systemName: "person.fill").font(.caption2).foregroundStyle(.tertiary)
                            Text(role.title).font(.subheadline.weight(.medium))
                            if !role.does.isEmpty { Text(role.does).font(.footnote).foregroundStyle(.secondary) }
                        }
                    }
                }
            }
            if !team.routines.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(team.routines) { routine in
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Image(systemName: "clock.arrow.circlepath").font(.caption2).foregroundStyle(.tint)
                            VStack(alignment: .leading, spacing: 1) {
                                Text("\(routine.schedule.words) · \(routine.title)").font(.subheadline)
                                Text(routine.instruction).font(.footnote).foregroundStyle(.secondary).lineLimit(2)
                            }
                        }
                    }
                }
            }
            if !team.tasks.isEmpty {
                Text("반복하는 일: " + team.tasks.joined(separator: " · ")).font(.caption).foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 4)
    }

    private var buttons: some View {
        VStack(spacing: 8) {
            if let problem = draft.problem { Text(problem).font(.footnote).foregroundStyle(.red) }
            if draft.teams.isEmpty { Text("팀을 모두 뺐어요. 만들 팀이 없어요.").font(.footnote).foregroundStyle(.secondary) }
            Button { Task { await build() } } label: {
                HStack { if working { ProgressView() }; Text("이대로 만들기") }.frame(maxWidth: .infinity)
            }
            .buttonStyle(.action(.primary))
            .disabled(draft.problem != nil || draft.teams.isEmpty)
            if changed {
                Button { Task { await save() } } label: { Text("고친 것 저장만").frame(maxWidth: .infinity) }
                    .buttonStyle(.action(.secondary))
                    .disabled(draft.problem != nil)
            }
            Button { confirmDecline = true } label: { Text("만들지 않기").frame(maxWidth: .infinity) }
                .buttonStyle(.action(.secondary))
            Text(changed ? "고친 것이 있어요. '이대로 만들기'를 누르면 저장한 뒤 만들어요." : "만든 뒤에는 봇 목록과 루틴 화면에서 고칠 수 있어요.")
                .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .disabled(working)
        .padding(.horizontal, 4)
    }

    // MARK: work

    private func show(_ data: TeamPlanView) {
        state = .loaded(data)
        draft = TeamPlanDraft(teams: data.plan?.teams ?? [])
        saved = draft
    }

    private func load() async {
        guard let client = model.client else { return }
        if changed, case .loaded = state { model.toast = "다시 불러와서 저장하지 않은 고친 것은 사라졌어요." }
        do { show(try await client.teamPlan()) } catch { state = .failed(error.friendly) }
    }

    @discardableResult
    private func save() async -> Bool {
        guard let client = model.client else { return false }
        working = true
        defer { working = false }
        do {
            _ = try await client.saveTeamPlan(draft)
            saved = draft
            model.toast = "고친 것을 저장했어요."
            return true
        } catch {
            model.toast = error.friendly
            return false
        }
    }

    private func build() async {
        guard let client = model.client else { return }
        if changed { guard await save() else { return } }
        working = true
        defer { working = false }
        do {
            let made = try await client.applyTeamPlan()
            result = made.words
            await model.refreshBots()
            if let fresh = try? await client.teamPlan() { show(fresh) }
        } catch {
            model.toast = error.friendly
        }
    }

    private func decline() async {
        guard let client = model.client else { return }
        working = true
        defer { working = false }
        do {
            _ = try await client.declineTeamPlan()
            model.toast = "팀 구조를 만들지 않기로 했어요."
            if let fresh = try? await client.teamPlan() { show(fresh) }
        } catch {
            model.toast = error.friendly
        }
    }
}

/// 더보기 맨 위: "팀 구조 제안" card, shown only when the Mac has a plan (proposed = highlighted; old = a quiet record).
struct TeamPlanEntry: View {
    @Environment(AppModel.self) private var model
    @State private var plan: TeamPlan?

    var body: some View {
        Group {
            if let plan {
                Panel {
                    NavigationLink { TeamPlanScreen() } label: {
                        HStack(spacing: 14) {
                            Image(systemName: "person.3.sequence.fill").font(.title3)
                                .foregroundStyle(plan.isProposed ? Color.white : Color.accentColor)
                                .frame(width: 36, height: 36)
                                .background(plan.isProposed ? Color.accentColor : Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                            VStack(alignment: .leading, spacing: 3) {
                                Text(plan.isProposed ? "팀 구조 제안" : "지난 팀 구조 제안").font(.headline).foregroundStyle(.primary)
                                Text(plan.isProposed ? "팀 \(plan.teams.count)개 · 확인하고 만들어 주세요" : "팀 \(plan.teams.count)개 · \(plan.pastWords ?? "")")
                                    .font(.footnote).foregroundStyle(plan.isProposed ? Color.accentColor : .secondary)
                            }
                            Spacer(minLength: 0)
                            Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                .overlay {
                    if plan.isProposed {
                        RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Color.accentColor.opacity(0.5), lineWidth: 1.5)
                    }
                }
            } else {
                // Something has to be on screen for the load below to run; an empty Group never appears.
                Color.clear.frame(height: 0).accessibilityHidden(true)
            }
        }
        .task(id: model.capabilities.has("team-plan")) { await load() }
        .onAppear { Task { await load() } }
    }

    private func load() async {
        guard model.capabilities.has("team-plan"), let client = model.client else { plan = nil; return }
        if let view = try? await client.teamPlan() { plan = view.plan }
    }
}

/// One team: name, purpose, company, staff roles (up to 6) and routines; or drop the team.
private struct PlanTeamEditSheet: View {
    @State var team: PlanTeam
    var companies: [String]
    var onSave: (PlanTeam) -> Void
    var onRemove: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var confirmRemove = false

    init(team: PlanTeam, companies: [String], onSave: @escaping (PlanTeam) -> Void, onRemove: @escaping () -> Void) {
        _team = State(initialValue: team); self.companies = companies; self.onSave = onSave; self.onRemove = onRemove
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("팀") {
                    TextField("팀 이름", text: $team.name)
                    TextField("목적", text: $team.purpose, axis: .vertical).lineLimit(1...4)
                    TextField("회사", text: $team.company)
                    let others = companies.filter { $0 != team.company }
                    if !others.isEmpty {
                        Menu("다른 회사로 옮기기") {
                            ForEach(others, id: \.self) { c in Button(c) { team.company = c } }
                        }
                    }
                    if team.isDev { Text("개발팀이라 검수 봇이 함께 붙어요.").font(.footnote).foregroundStyle(.secondary) }
                }
                Section {
                    ForEach($team.roles) { $role in
                        VStack(alignment: .leading, spacing: 4) {
                            TextField("역할 이름 (20자까지)", text: $role.title)
                                .font(.body.weight(.medium))
                                .onChange(of: role.title) { _, v in if v.count > TeamPlanDraft.roleTitleLimit { role.title = String(v.prefix(TeamPlanDraft.roleTitleLimit)) } }
                            TextField("하는 일", text: $role.does, axis: .vertical).font(.footnote).lineLimit(1...3)
                        }
                    }
                    .onDelete { team.roles.remove(atOffsets: $0) }
                    if team.roles.count < TeamPlanDraft.maxRoles {
                        Button { team.roles.append(PlanRole(title: "")) } label: { Label("역할 더하기", systemImage: "plus") }
                    }
                } header: {
                    Text("직원 역할 \(team.roles.count)/\(TeamPlanDraft.maxRoles)")
                } footer: {
                    Text("역할마다 직원 봇이 하나씩 생겨요. 밀어서 뺄 수 있어요.")
                }
                Section {
                    ForEach($team.routines) { $routine in RoutineEditor(routine: $routine) }
                        .onDelete { team.routines.remove(atOffsets: $0) }
                } header: {
                    Text("루틴")
                } footer: {
                    Text(team.routines.isEmpty ? "이 팀에 맡길 루틴이 없어요." : "만들 때 이 팀의 팀장에게 맡겨요. 밀어서 뺄 수 있어요.")
                }
                if !team.tasks.isEmpty {
                    Section("반복하는 일 (참고)") {
                        Text(team.tasks.joined(separator: " · ")).font(.footnote).foregroundStyle(.secondary)
                    }
                }
                Section {
                    Button("이 팀 빼기", role: .destructive) { confirmRemove = true }
                }
                if let problem = TeamPlanDraft.problem(in: team) {
                    Section { Text(problem).foregroundStyle(.red) }
                }
            }
            .navigationTitle("팀 고치기")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("취소") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("완료") { onSave(team); dismiss() }.disabled(TeamPlanDraft.problem(in: team) != nil)
                }
            }
            .confirmationDialog("\(team.name) 팀을 뺄까요?", isPresented: $confirmRemove, titleVisibility: .visible) {
                Button("빼기", role: .destructive) { onRemove(); dismiss() }
                Button("취소", role: .cancel) {}
            }
        }
    }
}

/// A routine's title, what it does and when: 매일 · 매주 요일 · N시간마다.
private struct RoutineEditor: View {
    @Binding var routine: PlanRoutine

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("제목", text: $routine.title).font(.body.weight(.medium))
            TextField("하는 일", text: $routine.instruction, axis: .vertical).font(.footnote).lineLimit(1...4)
            Picker("일정", selection: kindBinding) {
                Text("매일").tag("daily")
                Text("매주").tag("weekly")
                Text("몇 시간마다").tag("every")
            }
            .pickerStyle(.segmented)
            if routine.schedule.kind == "weekly" {
                Picker("요일", selection: Binding(get: { routine.schedule.day ?? "mon" }, set: { routine.schedule.day = $0 })) {
                    ForEach(PlanSchedule.days, id: \.self) { d in Text(PlanSchedule.dayWords[d] ?? d).tag(d) }
                }
                .pickerStyle(.segmented)
            }
            if routine.schedule.kind == "every" {
                Stepper("\(routine.schedule.hours ?? 1)시간마다", value: Binding(get: { routine.schedule.hours ?? 1 }, set: { routine.schedule.hours = $0 }), in: 1...24)
            } else {
                DatePicker("시각", selection: timeBinding, displayedComponents: .hourAndMinute)
            }
        }
        .padding(.vertical, 4)
    }

    private var kindBinding: Binding<String> {
        Binding(get: { routine.schedule.kind }, set: { kind in
            var s = routine.schedule
            s.kind = kind
            if kind == "every" { s.hours = s.hours ?? 3 } else { s.at = s.at ?? "09:00" }
            if kind == "weekly" { s.day = s.day ?? "mon" }
            routine.schedule = s.cleaned
        })
    }

    private var timeBinding: Binding<Date> {
        Binding(get: {
            let parts = (routine.schedule.at ?? "09:00").split(separator: ":").compactMap { Int($0) }
            return Calendar.current.date(bySettingHour: parts.first ?? 9, minute: parts.count > 1 ? parts[1] : 0, second: 0, of: Date()) ?? Date()
        }, set: { date in
            let c = Calendar.current.dateComponents([.hour, .minute], from: date)
            routine.schedule.at = String(format: "%02d:%02d", c.hour ?? 9, c.minute ?? 0)
        })
    }
}

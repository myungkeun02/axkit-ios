import AxKitCore
import SwiftUI

/// 처음 알아보기 (§27): the Mac reads folders, projects, Drive and signals once; this shows the progress, then "당신은 이런
/// 사람이고, 이런 조직 분류가 필요해 보여요" as a tree the owner can fix in words before building it.
struct FirstLookScreen: View {
    @Environment(AppModel.self) private var model
    @State private var state: Loadable<FirstLookView> = .loading
    @State private var pollTick = 0
    @State private var reviseText = ""
    @State private var revised: FirstLookRevised?
    @State private var working = false
    @State private var confirmRestart = false
    @State private var result: String?

    var body: some View {
        LoadableView(state: state, retry: { await poll() }) { data in
            Page {
                progressPanel(data)
                if let found = data.result { resultPanels(found, data: data) }
                if !data.isRunning { restartButton(data) }
            }
            .refreshable { await load() }
        }
        .navigationTitle("처음 알아보기")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: pollTick) { await poll() }
        .confirmationDialog("처음 알아보기를 다시 시작할까요?", isPresented: $confirmRestart, titleVisibility: .visible) {
            Button("다시 시작") { Task { await start() } }
            Button("취소", role: .cancel) {}
        } message: {
            Text("폴더와 프로젝트를 처음부터 다시 읽어요. 시간이 좀 걸려요.")
        }
        .alert("팀 구조를 만들었어요", isPresented: Binding(get: { result != nil }, set: { if !$0 { result = nil } })) {
            Button("확인", role: .cancel) {}
        } message: {
            Text(result ?? "")
        }
    }

    // MARK: progress

    private func progressPanel(_ data: FirstLookView) -> some View {
        Panel {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline) {
                    Text(data.statusWords).font(.headline)
                    Spacer(minLength: 0)
                    if data.isRunning || data.isDone { Text("\(data.percent)%").font(.headline.monospacedDigit()).foregroundStyle(.secondary) }
                }
                if data.isRunning || data.isPaused || data.isDone || data.isFailed {
                    ProgressView(value: Double(data.percent), total: 100)
                        .accessibilityLabel("진행")
                        .accessibilityValue("\(data.percent)%")
                }
                if data.isIdle {
                    Text("아직 한 번도 알아보지 않았어요. 시작하면 이 맥의 폴더와 프로젝트를 읽고 당신의 일을 정리해요.")
                        .font(.subheadline).foregroundStyle(.secondary)
                } else {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(data.phases) { phase in phaseRow(phase) }
                    }
                    Text(data.countsText).font(.footnote).foregroundStyle(.secondary)
                    let elapsed = data.elapsedText()
                    if !elapsed.isEmpty { Text("걸린 시간 \(elapsed)").font(.footnote).foregroundStyle(.secondary) }
                }
                if data.isPaused {
                    Text("멈춰 있어요. 오너가 멈췄거나 맥이 다시 켜진 거예요. 이어서 읽을 수 있어요.")
                        .font(.footnote).foregroundStyle(.secondary)
                    Button { Task { await start() } } label: {
                        HStack { if working { ProgressView() }; Text("알아보기 계속") }.frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.action(.primary)).disabled(working)
                }
                if data.isFailed {
                    Text("읽다가 멈췄어요. " + FirstLookView.errorWords(data.error)).font(.footnote).foregroundStyle(.red)
                    Button { Task { await start() } } label: {
                        HStack { if working { ProgressView() }; Text("다시 시작") }.frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.action(.primary)).disabled(working)
                }
                if data.isIdle {
                    Button { Task { await start() } } label: {
                        HStack { if working { ProgressView() }; Text("알아보기 시작") }.frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.action(.primary)).disabled(working)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func phaseRow(_ phase: FirstLookPhase) -> some View {
        HStack(spacing: 8) {
            Image(systemName: phase.state == "done" ? "checkmark.circle.fill" : phase.state == "active" ? "circle.dotted" : "circle")
                .foregroundStyle(phase.state == "done" ? Color.accentColor : phase.state == "active" ? Color.primary : Color.secondary.opacity(0.5))
                .frame(width: 20)
                .accessibilityHidden(true)
            Text(phase.label).font(.subheadline.weight(phase.state == "active" ? .semibold : .regular))
            Spacer(minLength: 0)
            if phase.total > 0 { Text("\(phase.done)/\(phase.total)").font(.footnote.monospacedDigit()).foregroundStyle(.secondary) }
        }
        .accessibilityElement(children: .combine)
        .accessibilityValue(phase.state == "done" ? "끝" : phase.state == "active" ? "읽는 중" : "기다리는 중")
    }

    // MARK: result

    @ViewBuilder
    private func resultPanels(_ found: FirstLookResult, data: FirstLookView) -> some View {
        Panel {
            VStack(alignment: .leading, spacing: 6) {
                Text("당신은 이런 사람이군요").font(.headline)
                Text(found.about.isEmpty ? "아직 한 줄로 정리하지 못했어요." : found.about)
                    .font(.subheadline).foregroundStyle(found.about.isEmpty ? .secondary : .primary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        if found.companies.isEmpty {
            Panel {
                Text("나눌 회사나 프로젝트를 찾지 못했어요.").font(.subheadline).foregroundStyle(.secondary)
            }
        } else {
            Text("이런 조직 분류가 필요해 보여요").font(.subheadline.weight(.semibold)).foregroundStyle(.secondary).padding(.horizontal, 4)
            ForEach(found.companies) { company in companyPanel(company) }
        }
        if data.canBuild { fixAndBuild(found) }
        else if let past = found.plan, past.status != "proposed" {
            Text(past.status == "applied" ? "이 구조로 팀을 이미 만들었어요." : "이 구조는 만들지 않기로 했어요.")
                .font(.footnote).foregroundStyle(.secondary).padding(.horizontal, 4)
        }
    }

    private func companyPanel(_ company: FirstLookCompany) -> some View {
        Panel {
            VStack(alignment: .leading, spacing: 10) {
                CardHeader(title: company.name, subtitle: "\(company.relationWords) · 프로젝트 \(company.projects.count)개")
                ForEach(company.projects) { project in
                    projectBlock(project)
                    if project.id != company.projects.last?.id { Divider() }
                }
            }
        }
    }

    private func projectBlock(_ project: FirstLookProject) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(project.name).font(.body.weight(.semibold))
                Text(project.team.isDev ? "개발팀" : "팀")
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 7).padding(.vertical, 2)
                    .background(Color.secondary.opacity(0.12), in: Capsule())
                    .foregroundStyle(.secondary)
            }
            if !project.purpose.isEmpty { Text(project.purpose).font(.subheadline).foregroundStyle(.secondary) }
            ForEach(project.team.roles) { role in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: "person.fill").font(.caption2).foregroundStyle(.tertiary)
                    Text(role.title).font(.subheadline.weight(.medium))
                    if !role.does.isEmpty { Text(role.does).font(.footnote).foregroundStyle(.secondary) }
                }
            }
            ForEach(project.routines) { routine in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: "clock.arrow.circlepath").font(.caption2).foregroundStyle(.tint)
                    Text(routine.when.isEmpty ? routine.title : "\(routine.when) · \(routine.title)").font(.subheadline)
                }
            }
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private func fixAndBuild(_ found: FirstLookResult) -> some View {
        Panel {
            VStack(alignment: .leading, spacing: 8) {
                Text("말로 고치기").font(.headline)
                Text("틀린 곳을 말하듯 써 주세요. 예: 에이컴퍼니랑 비컴퍼니은 따로야. 쇼핑앱은 비컴퍼니 아래.")
                    .font(.footnote).foregroundStyle(.secondary)
                TextField("어떻게 고칠까요?", text: $reviseText, axis: .vertical)
                    .lineLimit(2...5)
                    .textFieldStyle(.roundedBorder)
                    .onChange(of: reviseText) { _, v in
                        if v.count > FirstLookLimits.reviseMax { reviseText = String(v.prefix(FirstLookLimits.reviseMax)) }
                    }
                Button { Task { await revise() } } label: {
                    HStack { if working { ProgressView() }; Text("고치기") }.frame(maxWidth: .infinity)
                }
                .buttonStyle(.action(.secondary))
                .disabled(working || reviseText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                if let revised { revisedNote(revised) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        Button { Task { await build() } } label: {
            HStack { if working { ProgressView() }; Text("이대로 만들기") }.frame(maxWidth: .infinity)
        }
        .buttonStyle(.action(.primary))
        .disabled(working || found.companies.isEmpty)
        .padding(.horizontal, 4)
    }

    private func revisedNote(_ r: FirstLookRevised) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if !r.text.isEmpty { Text(r.text).font(.subheadline) }
            if !r.changed.isEmpty {
                Text("바꾼 것").font(.footnote.weight(.semibold)).padding(.top, 4)
                ForEach(r.changed, id: \.self) { Text("· \($0)").font(.footnote) }
            }
            if !r.skipped.isEmpty {
                Text("그대로 둔 것").font(.footnote.weight(.semibold)).padding(.top, 4)
                ForEach(r.skipped, id: \.self) { Text("· \($0)").font(.footnote).foregroundStyle(.secondary) }
            }
        }
        .padding(.top, 4)
    }

    private func restartButton(_ data: FirstLookView) -> some View {
        Group {
            if data.isDone {
                Button { confirmRestart = true } label: { Text("다시 시작").frame(maxWidth: .infinity) }
                    .buttonStyle(.action(.secondary))
                    .disabled(working)
                    .padding(.horizontal, 4)
            }
        }
    }

    // MARK: work

    private func load() async {
        guard let client = model.client else { return }
        do {
            let fresh = try await client.firstLook()
            state = .loaded(fresh)
        } catch {
            if case .loaded = state { return }
            state = .failed(error.friendly)
        }
    }

    /// Reads once, then every second while the Mac is reading, every few seconds while paused or not started
    /// (it may be started or resumed from the Mac or the terminal). Cancelled with the screen.
    private func poll() async {
        while !Task.isCancelled {
            await load()
            guard case .loaded(let data) = state else { return }
            if data.isRunning { try? await Task.sleep(for: .seconds(1)) }
            else if data.isPaused || data.isIdle { try? await Task.sleep(for: .seconds(4)) }
            else { return }
        }
    }

    private func start() async {
        guard let client = model.client else { return }
        working = true
        defer { working = false }
        do {
            _ = try await client.startFirstLook()
            revised = nil
            pollTick += 1
        } catch {
            model.toast = error.friendly
        }
    }

    private func revise() async {
        guard let client = model.client else { return }
        let text = reviseText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        working = true
        defer { working = false }
        do {
            let answer = try await client.reviseFirstLook(text)
            revised = answer
            if !answer.changed.isEmpty { reviseText = "" }
            if let fresh = answer.result, case .loaded(var data) = state {
                data.result = fresh
                state = .loaded(data)
            }
        } catch {
            model.toast = error.friendly
        }
    }

    private func build() async {
        guard let client = model.client else { return }
        working = true
        defer { working = false }
        do {
            let made = try await client.applyFirstLook()
            result = made.words
            await model.refreshBots()
            revised = nil
            await load()
        } catch {
            model.toast = error.friendly
        }
    }
}

/// 더보기 맨 위: "처음 알아보기" card — highlighted while reading or while a proposal waits, quiet otherwise.
struct FirstLookEntry: View {
    @Environment(AppModel.self) private var model
    @State private var info: FirstLookView?

    private var highlighted: Bool { info.map { $0.isRunning || $0.canBuild } ?? false }

    var body: some View {
        Group {
            if let info {
                Panel {
                    NavigationLink { FirstLookScreen() } label: {
                        HStack(spacing: 14) {
                            Image(systemName: "binoculars.fill").font(.title3)
                                .foregroundStyle(highlighted ? Color.white : Color.accentColor)
                                .frame(width: 36, height: 36)
                                .background(highlighted ? Color.accentColor : Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                            VStack(alignment: .leading, spacing: 3) {
                                Text("처음 알아보기").font(.headline).foregroundStyle(.primary)
                                Text(subtitle(info)).font(.footnote).foregroundStyle(highlighted ? Color.accentColor : .secondary)
                            }
                            Spacer(minLength: 0)
                            Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                .overlay {
                    if highlighted {
                        RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Color.accentColor.opacity(0.5), lineWidth: 1.5)
                    }
                }
            } else {
                // Something has to be on screen for the load below to run; an empty Group never appears.
                Color.clear.frame(height: 0).accessibilityHidden(true)
            }
        }
        .task(id: model.capabilities.has("first-look")) { await load() }
        .onAppear { Task { await load() } }
    }

    private func subtitle(_ v: FirstLookView) -> String {
        switch v.status {
        case "running": "읽는 중 \(v.percent)%"
        case "paused": "멈춰 있어요 · 이어서 읽을 수 있어요"
        case "failed": "멈췄어요 · 다시 시작할 수 있어요"
        case "done": v.canBuild ? "결과를 보고 팀을 만들어 주세요" : "다 읽었어요"
        default: "아직 시작 전이에요"
        }
    }

    private func load() async {
        guard model.capabilities.has("first-look"), let client = model.client else { info = nil; return }
        if let view = try? await client.firstLook() { info = view }
    }
}

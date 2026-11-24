import AxKitCore
import Charts
import SwiftUI

/// 더보기: settings first, then the things the assistant manages. Rows appear only when the Mac has that view,
/// and server-drawn screens (ui: "blocks") show up under 새 기능 without an app update.
struct MoreView: View {
    @Environment(AppModel.self) private var model
    /// Screens opened by a link (`axkit://open/more?v=jobs`); taps use plain NavigationLinks.
    @State private var path: [String] = []

    private func has(_ view: String) -> Bool { model.capabilities.hasView(view) }

    @ViewBuilder static func screen(_ name: String) -> some View {
        switch name {
        case "settings": SettingsScreen()
        case "recordings": RecordingsScreen()
        case "autonomy": AutonomyScreen()
        case "routines": RoutinesScreen()
        case "jobs": JobsScreen()
        case "spending": SpendingScreen()
        case "usage": UsageScreen()
        case "providers": ProvidersScreen()
        case "modeltiers": ModelTiersScreen()
        case "health": HealthScreen()
        case "hardware": HardwareScreen()
        case "browser-live": BrowserLiveScreen()
        case "projects": ProjectsScreen()
        case "team-plan": TeamPlanScreen()
        case "first-look": FirstLookScreen()
        case "work": WorkScreen()
        case "people": PeopleScreen()
        default: BlocksScreen(name: name)
        }
    }

    var body: some View {
        NavigationStack(path: $path) {
            Page {
                if model.capabilities.has("team-plan") { TeamPlanEntry() }
                if model.capabilities.has("first-look") { FirstLookEntry() }
                Panel {
                    NavigationLink { SettingsScreen() } label: {
                        HStack(spacing: 14) {
                            Image(systemName: "macmini").font(.title3).foregroundStyle(.tint).frame(width: 26)
                            VStack(alignment: .leading, spacing: 3) {
                                Text("설정 및 연결").font(.headline).foregroundStyle(.primary)
                                HStack(spacing: 6) {
                                    Circle().fill(model.connection.color).frame(width: 7, height: 7)
                                    Text("\(model.credentials?.displayHost ?? "") · \(model.connection.label)").font(.footnote).foregroundStyle(.secondary)
                                }
                            }
                            Spacer(minLength: 0)
                            Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                menu("녹음", [
                    model.recordingFeature ? Item("녹음해서 회의록 만들기", "waveform") { AnyView(RecordingsScreen()) } : nil,
                ])
                menu("비서가 챙기는 것", [
                    has("work") ? Item("하고 있는 일", "hourglass") { AnyView(WorkScreen()) } : nil,
                    has("people") ? Item("사람", "person.2") { AnyView(PeopleScreen()) } : nil,
                    has("autonomy") ? Item("알아서 하는 일", "wand.and.stars") { AnyView(AutonomyScreen()) } : nil,
                    has("routines") ? Item("루틴", "clock.arrow.circlepath") { AnyView(RoutinesScreen()) } : nil,
                    has("jobs") ? Item("반복 작업", "repeat") { AnyView(JobsScreen()) } : nil,
                    model.capabilities.has("browser-live") ? Item("브라우저 화면 넘겨받기", "safari") { AnyView(BrowserLiveScreen()) } : nil,
                    has("spending") ? Item("지출 관리", "wonsign.circle") { AnyView(SpendingScreen()) } : nil,
                    model.capabilities.has("projects") ? Item("프로젝트 가져오기", "folder.badge.gearshape") { AnyView(ProjectsScreen()) } : nil,
                ])
                menu("AI", [
                    has("usage") ? Item("봇·AI 사용량", "chart.bar") { AnyView(UsageScreen()) } : nil,
                    has("providers") ? Item("AI 연결하기", "bolt.horizontal.circle") { AnyView(ProvidersScreen()) } : nil,
                    has("modeltiers") ? Item("AI 등급과 용도", "list.number") { AnyView(ModelTiersScreen()) } : nil,
                ])
                menu("맥", [
                    Item("터미널", "apple.terminal") { AnyView(TerminalHostsScreen()) },
                    has("health") ? Item("상태 점검", "stethoscope") { AnyView(HealthScreen()) } : nil,
                    has("hardware") ? Item("맥 상태", "cpu") { AnyView(HardwareScreen()) } : nil,
                ])
                let extras = model.capabilities.views.filter { $0.ui == "blocks" }
                menu("새 기능", extras.map { info in Item(info.title ?? info.name, info.icon ?? "sparkle") { AnyView(BlocksScreen(name: info.name)) } },
                     footer: "비서가 새로 배운 기능이에요. 앱을 업데이트하지 않아도 여기에 생겨요.")
            }
            .recordingBarInset()
            .navigationTitle("더보기")
            .refreshable { await model.refreshBasics() }
            .navigationDestination(for: String.self) { Self.screen($0) }
        }
        .onChange(of: model.moreRoute, initial: true) { _, route in
            guard let route else { return }
            model.moreRoute = nil
            path = [route]
        }
    }

    private struct Item: Identifiable {
        var id: String { title }
        var title: String
        var icon: String
        var destination: () -> AnyView
        init(_ title: String, _ icon: String, destination: @escaping () -> AnyView) { self.title = title; self.icon = icon; self.destination = destination }
    }

    @ViewBuilder private func menu(_ title: String, _ items: [Item?], footer: String? = nil) -> some View {
        let shown = items.compactMap { $0 }
        if !shown.isEmpty {
            Panel(padding: 14) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.footnote.weight(.semibold)).foregroundStyle(.secondary).padding(.horizontal, 4)
                    CardList(items: shown) { item in
                        NavigationLink(destination: item.destination) { MenuRow(icon: item.icon, title: item.title) }
                            .buttonStyle(.plain)
                            .padding(.horizontal, 4)
                    }
                    if let footer { Text(footer).font(.caption).foregroundStyle(.secondary).padding(.horizontal, 4).padding(.top, 4) }
                }
            }
        }
    }
}

// MARK: 반복 작업

struct JobsScreen: View {
    @Environment(AppModel.self) private var model
    @State private var state: Loadable<JobsView> = .loading

    private var canToggle: Bool { model.capabilities.view("jobs")?.actions?.contains("toggle") == true }

    var body: some View {
        LoadableView(state: state, retry: load) { data in
            Page {
                Panel {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("새 반복 작업은 비서에게 말로 부탁하세요. 예: \"매일 아침 8시에 날씨 알려 줘\"")
                            .font(.subheadline).foregroundStyle(.secondary)
                        Button("비서에게 말하러 가기") { model.showRoom("") }.buttonStyle(.action(.primary))
                    }
                }
                ForEach(data.groups) { group in
                    Panel {
                        VStack(alignment: .leading, spacing: 4) {
                            CardHeader(title: group.label)
                            CardList(items: group.jobs) { job in JobRow(job: job, toggle: canToggle && job.canToggle ? { await set(job, $0) } : nil) }
                        }
                    }
                }
            }
            .refreshable { await load() }
        }
        .navigationTitle("반복 작업")
        .task { await load() }
    }

    private func load() async {
        guard let client = model.client else { return }
        do { state = .loaded(try await client.view(JobsView.self, "jobs")) } catch { state = .failed(error.friendly) }
    }

    private struct Toggled: Decodable { var enabled: Bool }

    private func set(_ job: JobsView.Job, _ enabled: Bool) async {
        guard let client = model.client else { return }
        do {
            _ = try await client.viewAction(Toggled.self, "jobs", "toggle", json: ["id": job.id, "enabled": enabled])
            model.toast = enabled ? "'\(job.name)'을 켰어요" : "'\(job.name)'을 껐어요"
        } catch { model.toast = error.friendly }
        await load()
    }
}

private struct JobRow: View {
    var job: JobsView.Job
    var toggle: ((Bool) async -> Void)?
    @State private var on: Bool

    init(job: JobsView.Job, toggle: ((Bool) async -> Void)?) {
        self.job = job
        self.toggle = toggle
        _on = State(initialValue: job.enabled)
    }

    /// One grey line: when it runs and how the last run went. Problems in red.
    private var line: (String, Color) {
        var parts = [job.scheduleLabel ?? ""]
        if job.running == true { parts.append("도는 중") }
        if let run = job.lastRun, let at = run.startedAt {
            if run.ok == false { return ((parts + ["\(Format.relative(at)) 문제: \(run.error ?? "")"]).joined(separator: " · "), .red) }
            parts.append("\(Format.relative(at)) 잘 끝남")
        }
        return (parts.filter { !$0.isEmpty }.joined(separator: " · "), .secondary)
    }

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(job.name)
                Text(line.0).font(.footnote).foregroundStyle(line.1)
            }
            .accessibilityElement(children: .combine)
            Spacer(minLength: 0)
            if let toggle {
                Toggle(job.name, isOn: $on).labelsHidden().tint(.accentColor)
                    .onChange(of: on) { _, value in Task { await toggle(value) } }
            } else {
                Text(job.enabled ? "켜짐" : "꺼짐").font(.footnote).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 10)
    }
}

// MARK: 사용량

struct UsageScreen: View {
    /// "09:00" → "9시", "20" → "20일".
    static func bucketLabel(_ raw: String, day: Bool) -> String {
        if day, let h = Int(raw.prefix(2)) { return "\(h)시" }
        if let d = Int(raw) { return "\(d)일" }
        return raw
    }

    @Environment(AppModel.self) private var model
    @State private var period = "day"
    @State private var state: Loadable<UsageView> = .loading

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Picker("기간", selection: $period) {
                    Text("오늘").tag("day"); Text("최근 7일").tag("week"); Text("이번 달").tag("month")
                }
                .pickerStyle(.segmented)
                LoadableView(state: state, retry: load) { u in content(u) }.frame(minHeight: 300)
            }
            .padding(16)
        }
        .background(Theme.page)
        .navigationTitle("봇·AI 사용량")
        .task(id: period) { await load() }
    }

    @ViewBuilder private func content(_ u: UsageView) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Panel {
                VStack(alignment: .leading, spacing: 6) {
                    Text("AI에게 \(u.totals.calls)번 물어봤어요").font(.title3.bold())
                    Text("쓴 돈: \(Format.dollars(u.totals.costUsd)) (약 \(Format.won(u.totals.costUsd * 1400)))").font(.subheadline)
                    let failRate = u.totals.calls + u.totals.failures == 0 ? 0 : Double(u.totals.failures) / Double(u.totals.calls + u.totals.failures)
                    Text(failRate < 0.05 ? "거의 다 잘 됐어요" : "실패가 조금 많아요 (\(u.totals.failures)번). AI 연결하기를 확인해 보세요.")
                        .font(.footnote).foregroundStyle(.secondary)
                    if let budget = u.budget {
                        let limit = u.period == "month" ? budget.monthlyUsd : budget.dailyUsd
                        if limit > 0 {
                            ProgressView(value: min(u.totals.costUsd / limit, 1)) {
                                Text("예산 \(Format.dollars(limit)) 중 \(Int(u.totals.costUsd / limit * 100))%").font(.caption)
                            }
                            .tint(u.totals.costUsd > limit * 0.8 ? .orange : .accentColor)
                        }
                    }
                }
            }
            if let daily = u.daily, !daily.isEmpty {
                Panel {
                    VStack(alignment: .leading) {
                        Text(u.period == "day" ? "시간별" : "날짜별").font(.headline)
                        // A few buckets would draw one fat bar across the card: keep bars slim and label the ends.
                        Chart(daily, id: \.date) { p in
                            BarMark(x: .value("때", String(p.date.suffix(u.period == "day" ? 5 : 2))), y: .value("횟수", p.calls),
                                    width: .fixed(daily.count < 8 ? 22 : 10))
                                .foregroundStyle(Color.accentColor.gradient)
                        }
                        .chartXAxis {
                            AxisMarks(values: daily.count <= 8 ? daily.map { String($0.date.suffix(u.period == "day" ? 5 : 2)) } : [daily.first, daily.last].compactMap { $0.map { String($0.date.suffix(u.period == "day" ? 5 : 2)) } }) { value in
                                AxisValueLabel { if let v = value.as(String.self) { Text(Self.bucketLabel(v, day: u.period == "day")).font(.caption2) } }
                            }
                        }
                        .frame(height: 160)
                    }
                }
            }
            if let bots = u.byBot, !bots.isEmpty {
                Panel {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("봇별").font(.headline)
                        let maxCalls = Double(bots.map(\.calls).max() ?? 1)
                        ForEach(bots, id: \.botId) { b in
                            VStack(alignment: .leading, spacing: 4) {
                                HStack { Text(b.name); Spacer(); Text("\(b.calls)번 · \(Format.dollars(b.costUsd))").foregroundStyle(.secondary) }.font(.subheadline)
                                ProgressView(value: Double(b.calls) / maxCalls)
                            }
                            .accessibilityElement(children: .combine)
                        }
                    }
                }
            }
            Panel {
                VStack(alignment: .leading, spacing: 4) {
                    CardHeader(title: "AI 모델별")
                    CardList(items: u.byModel.map { KV(title: $0.model, value: "\($0.calls)번 · \(Format.dollars($0.costUsd))") }) { row in
                        CardRow(title: Self.modelName(row.title), detail: Self.providerName(u.byModel.first { $0.model == row.title }?.providerId)) {
                            Text(row.value).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
    }

    /// "claude-sonnet-5-5" → "Claude Sonnet 5.5", "gpt-5.4-mini" → "GPT 5.4 mini".
    static func modelName(_ id: String) -> String {
        var parts = id.split(separator: "-").map(String.init)
        var out: [String] = []
        var digits: [String] = []
        for p in parts where !p.isEmpty {
            if p.allSatisfy(\.isNumber) { digits.append(p); continue }
            if !digits.isEmpty { out.append(digits.joined(separator: ".")); digits = [] }
            let known = ["gpt": "GPT", "deepseek": "DeepSeek", "mini": "mini", "nano": "nano", "pro": "Pro"]
            out.append(known[p.lowercased()] ?? (p.first!.isNumber ? p : p.prefix(1).uppercased() + p.dropFirst()))
        }
        if !digits.isEmpty { out.append(digits.joined(separator: ".")) }
        parts = out
        return parts.joined(separator: " ")
    }

    static func providerName(_ id: String?) -> String? {
        guard let id else { return nil }
        return ["anthropic": "Claude", "openai": "ChatGPT", "deepseek": "DeepSeek", "google": "Gemini", "gemini": "Gemini", "ollama": "맥 안의 AI"][id] ?? id
    }

    private func load() async {
        guard let client = model.client else { return }
        do { state = .loaded(try await client.view(UsageView.self, "usage", query: ["period": period])) } catch { state = .failed(error.friendly) }
    }
}

// MARK: AI 연결하기

struct ProvidersScreen: View {
    @Environment(AppModel.self) private var model
    @State private var state: Loadable<ProvidersView> = .loading
    @State private var connecting: ProvidersView.Provider?
    @State private var disconnecting: ProvidersView.Provider?

    var body: some View {
        LoadableView(state: state, retry: load) { data in
            Page {
                Text("비서가 쓸 AI를 연결해요. 여러 개를 연결하면 일에 맞게 골라 쓰고, 하나가 막히면 다른 걸 써요.")
                    .font(.subheadline).foregroundStyle(.secondary).padding(.horizontal, 4)
                Panel {
                    CardList(items: data.providers) { p in
                        CardRow(title: p.label, detail: [p.detail ?? (p.connected ? "연결됨" : "연결 안 됨"), p.kind == "subscription" ? "로그인은 맥에서 해요" : nil].compactMap { $0 }.joined(separator: " · ")) {
                            if p.kind == "api_key" {
                                if p.connected {
                                    Button("끊기") { disconnecting = p }.buttonStyle(.action(.danger, fullWidth: false, small: true))
                                } else {
                                    Button("연결") { connecting = p }.buttonStyle(.action(.primary, fullWidth: false, small: true))
                                }
                            } else {
                                let color: Color = !p.connected ? Color(.systemGray3) : p.status == "error" ? .red : p.status == "warn" || p.status == "degraded" ? .orange : .green
                                Circle().fill(color).frame(width: 8, height: 8)
                                    .accessibilityLabel(!p.connected ? "연결 안 됨" : p.status == "error" ? "문제 있음" : "잘 됨")
                            }
                        }
                    }
                }
            }
            .refreshable { await load() }
        }
        .navigationTitle("AI 연결하기")
        .task { await load() }
        .sheet(item: $connecting) { p in ProviderKeySheet(provider: p) { await load() } }
        .confirmationDialog("\(disconnecting?.label ?? "") 연결을 끊을까요?", isPresented: Binding(get: { disconnecting != nil }, set: { if !$0 { disconnecting = nil } }), titleVisibility: .visible) {
            Button("연결 끊기", role: .destructive) {
                guard let p = disconnecting, let client = model.client else { return }
                Task {
                    do { try await client.disconnectProvider(p.id); model.toast = "\(p.label) 연결을 끊었어요" } catch { model.toast = error.friendly }
                    await load()
                }
            }
        } message: { Text("맥에 저장된 키가 지워져요. 비서는 다른 AI를 써요.") }
    }

    private func load() async {
        guard let client = model.client else { return }
        do { state = .loaded(try await client.view(ProvidersView.self, "providers")) } catch { state = .failed(error.friendly) }
    }
}

private struct ProviderKeySheet: View {
    var provider: ProvidersView.Provider
    var done: () async -> Void
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var key = ""
    @State private var saving = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("\(provider.label) 사이트에서 만든 API 키를 붙여 넣어 주세요.")
                    if let help = provider.help { Text(help).font(.footnote).foregroundStyle(.secondary) }
                }
                Section {
                    SecureField("API 키", text: $key).textContentType(.password).autocorrectionDisabled().textInputAutocapitalization(.never)
                } footer: {
                    Text("키는 이 아이폰에 남지 않고, 맥의 키체인에만 저장돼요. 다시 보여 주지도 않아요.")
                }
            }
            .navigationTitle("\(provider.label) 연결")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("취소") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("맥에 저장") {
                        saving = true
                        Task {
                            defer { saving = false }
                            do {
                                try await model.client?.connectProvider(provider.id, apiKey: key.trimmingCharacters(in: .whitespacesAndNewlines))
                                key = ""
                                model.toast = "\(provider.label)을 연결했어요"
                                await done()
                                dismiss()
                            } catch { model.toast = error.friendly }
                        }
                    }
                    .disabled(key.trimmingCharacters(in: .whitespaces).count < 8 || saving)
                }
            }
        }
    }
}

// MARK: 맥 상태

struct HardwareScreen: View {
    @Environment(AppModel.self) private var model
    @State private var state: Loadable<HardwareView> = .loading

    private func thermalWords(_ s: String?) -> (String, Color) {
        switch s {
        case "nominal": ("시원해요", .green)
        case "fair": ("조금 따뜻해요", .yellow)
        case "serious": ("뜨거워요 — 일이 느려질 수 있어요", .orange)
        case "critical": ("너무 뜨거워요!", .red)
        default: ("알 수 없어요", .secondary)
        }
    }

    var body: some View {
        LoadableView(state: state, retry: load) { h in
            Page {
                Panel {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(h.machine.name).font(.title3.bold())
                        if let summary = h.summary { Text(summary).foregroundStyle(.secondary) }
                    }
                }
                Panel {
                    VStack(alignment: .leading, spacing: 12) {
                        CardHeader(title: "지금")
                        if let cpu = h.cpuPercent { meter("일하는 정도(CPU)", cpu / 100, "\(Int(cpu))%") }
                        if let m = h.memory { meter("기억 공간(메모리)", m.used / m.total, "\(fmt(m.used)) / \(fmt(m.total)) \(m.unit)") }
                        if let d = h.disk { meter("저장 공간", d.used / d.total, "\(fmt(d.total - d.used)) \(d.unit) 남음") }
                    }
                }
                let t = thermalWords(h.thermal)
                KVCard(title: "맥", items: [
                    KV(title: "온도", value: t.0, color: t.1),
                    h.power.map { KV(title: "전원", value: $0) },
                    h.machine.model.map { KV(title: "기종", value: $0) },
                    h.machine.os.map { KV(title: "운영체제", value: $0) },
                    h.machine.uptimeSec.map { KV(title: "켜진 지", value: Format.duration(seconds: $0)) },
                ].compactMap { $0 })
                if let net = h.network, !net.isEmpty {
                    KVCard(title: "네트워크", items: net.sorted(by: { $0.key < $1.key }).map { KV(title: label($0.key), value: $0.value) })
                }
                if let server = h.server, !server.isEmpty {
                    KVCard(title: "비서 프로그램", items: server.sorted(by: { $0.key < $1.key }).map { KV(title: label($0.key), value: $0.value) })
                }
                if let at = h.checkedAt { Text("\(Format.relative(at)) 확인").font(.footnote).foregroundStyle(.secondary).padding(.horizontal, 4) }
            }
            .refreshable { await load() }
        }
        .navigationTitle("맥 상태")
        .task {
            while !Task.isCancelled {
                await load()
                try? await Task.sleep(nanoseconds: 15_000_000_000)
            }
        }
    }

    private func label(_ key: String) -> String {
        ["tailscale": "Tailscale", "internet": "인터넷", "version": "버전", "uptime": "켜진 지", "stop": "전체 정지 스위치"][key] ?? key
    }

    private func fmt(_ v: Double) -> String { v == v.rounded() ? String(Int(v)) : String(format: "%.1f", v) }

    private func meter(_ title: String, _ value: Double, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack { Text(title); Spacer(); Text(detail).foregroundStyle(.secondary) }.font(.subheadline)
            ProgressView(value: min(max(value, 0), 1)).tint(value > 0.85 ? .orange : .accentColor)
        }
        .accessibilityElement(children: .combine)
    }

    private func load() async {
        guard let client = model.client else { return }
        do { state = .loaded(try await client.view(HardwareView.self, "hardware")) }
        catch { if state.value == nil { state = .failed(error.friendly) } }
    }
}

// MARK: server-drawn screen

struct BlocksScreen: View {
    var name: String
    @Environment(AppModel.self) private var model
    @State private var state: Loadable<BlocksView> = .loading

    var body: some View {
        LoadableView(state: state, retry: load) { v in
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(Array(v.blocks.enumerated()), id: \.offset) { _, block in blockView(block) }
                }
                .padding(16)
            }
            .background(Theme.page)
            .navigationTitle(v.title)
            .refreshable { await load() }
        }
        .task { await load() }
    }

    @ViewBuilder private func blockView(_ b: BlocksView.Block) -> some View {
        switch b.kind {
        case "text": MarkdownText(b.text ?? "").font(.subheadline).foregroundStyle(.secondary).padding(.horizontal, 4)
        case "stat":
            Panel { VStack(alignment: .leading, spacing: 4) { Text(b.title ?? "").font(.subheadline).foregroundStyle(.secondary); Text(b.value ?? "").font(.title.bold()) } }
        case "list":
            Panel {
                VStack(alignment: .leading, spacing: 4) {
                    if let title = b.title { CardHeader(title: title) }
                    CardList(items: (b.rows ?? []).enumerated().map { KV(title: "\($0.offset)", value: "") }) { kv in
                        let r = (b.rows ?? [])[Int(kv.title) ?? 0]
                        CardRow(title: r.title, detail: r.detail) {
                            if let t = r.trailing { Text(t).font(.footnote).foregroundStyle(.secondary) }
                        }
                        .contextMenu {
                            // §20: a site the assistant remembers can be forgotten — asked in the chat, where ways.forget_site runs.
                            if name == "ways", ["사이트", "Sites"].contains(b.title ?? ""),
                               case let host = r.detail?.components(separatedBy: " · ").first.flatMap({ $0.contains(".") ? $0 : nil }) ?? r.title {
                                Button(role: .destructive) {
                                    model.send("\(host) 사이트(\(r.title))는 이제 잊어 줘", in: "")
                                    model.toast = "비서에게 잊어 달라고 했어요"
                                } label: { Label("이 사이트 잊기", systemImage: "trash") }
                            }
                        }
                    }
                }
            }
        case "note":
            Label(b.text ?? "", systemImage: "info.circle").font(.footnote).foregroundStyle(.secondary)
        case "ask":
            // Only sends a chat message: anything with effects still goes through the assistant and its cards.
            Button {
                model.send(b.message ?? b.title ?? "", in: "")
                model.toast = "비서에게 부탁했어요"
            } label: { Text(b.title ?? "비서에게 부탁하기") }
            .buttonStyle(.action(.primary))
        default: EmptyView()
        }
    }

    private func load() async {
        guard let client = model.client else { return }
        do { state = .loaded(try await client.view(BlocksView.self, name)) } catch { state = .failed(error.friendly) }
    }
}

/// 상태 점검: the Mac checks itself (safe checks only) and says in plain words what needs a look. Problems first.
struct HealthScreen: View {
    @Environment(AppModel.self) private var model
    @State private var state: Loadable<HealthView> = .loading

    @State private var showFine = false

    private func rank(_ s: String) -> Int { ["error": 0, "warn": 1, "ok": 3][s] ?? 2 }

    private func checkRow(_ c: HealthView.Check) -> some View {
        let l = look(c.status)
        return HStack(alignment: .top, spacing: 12) {
            Image(systemName: l.icon).foregroundStyle(l.color).frame(width: 22)
            VStack(alignment: .leading, spacing: 3) {
                Text(c.label).fixedSize(horizontal: false, vertical: true)
                if let d = c.detail { Text(d).font(.footnote).foregroundStyle(.secondary) }
                if let g = c.group { Text(g).font(.caption).foregroundStyle(.tertiary) }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 6)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(c.label), \(l.word)" + (c.detail.map { ", \($0)" } ?? ""))
    }

    private func look(_ s: String) -> (icon: String, color: Color, word: String) {
        switch s {
        case "ok": ("checkmark.circle.fill", .green, "괜찮아요")
        case "warn": ("exclamationmark.triangle.fill", .orange, "봐 주세요")
        case "error": ("xmark.octagon.fill", .red, "문제가 있어요")
        default: ("questionmark.circle", .secondary, "알 수 없어요")
        }
    }

    var body: some View {
        LoadableView(state: state, retry: load) { h in
            Page {
                let bad = h.checks.filter { $0.status != "ok" }.count
                Panel {
                    HStack(spacing: 14) {
                        let top = look(bad == 0 ? "ok" : (h.checks.contains { $0.status == "error" } ? "error" : "warn"))
                        Image(systemName: top.icon).font(.largeTitle).foregroundStyle(top.color)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(h.summary ?? (bad == 0 ? "모두 괜찮아요" : "\(h.checks.count)가지 중 \(bad)가지를 봐 주세요")).font(.headline)
                            if let at = h.checkedAt { Text("\(Format.relative(at)) 점검").font(.footnote).foregroundStyle(.secondary) }
                        }
                        Spacer(minLength: 0)
                    }
                }
                let problems = h.checks.filter { $0.status != "ok" }.sorted { rank($0.status) < rank($1.status) }
                if !problems.isEmpty {
                    Panel {
                        VStack(alignment: .leading, spacing: 4) {
                            CardHeader(title: "봐야 할 것")
                            CardList(items: problems) { c in checkRow(c) }
                        }
                    }
                }
                let fine = h.checks.filter { $0.status == "ok" }
                if !fine.isEmpty {
                    Panel {
                        DisclosureGroup(isExpanded: $showFine) {
                            CardList(items: fine) { c in checkRow(c) }
                        } label: {
                            Text("괜찮은 것 \(fine.count)개").font(.headline).foregroundStyle(.primary)
                        }
                    }
                }
                if bad > 0 {
                    Button("비서에게 고쳐 달라고 하기") {
                        let items = h.checks.filter { $0.status != "ok" }.map { $0.label + ($0.detail.map { "(\($0))" } ?? "") }
                        model.send("상태 점검에서 봐야 할 것이 있어요: " + items.joined(separator: ", ") + ". 고칠 수 있는 건 고쳐 주세요.", in: "")
                        model.toast = "비서에게 보냈어요."
                    }
                    .buttonStyle(.action(.primary))
                }
            }
            .refreshable { await load() }
        }
        .navigationTitle("상태 점검")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
    }

    private func load() async {
        guard let client = model.client else { return }
        do { state = .loaded(try await client.view(HealthView.self, "health")) } catch { state = .failed(error.friendly) }
    }
}

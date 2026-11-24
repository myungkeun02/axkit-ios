import AxKitCore
import SwiftUI

let tierChoices = ["S", "A", "B", "C"]

func tierWords(_ tier: String) -> String {
    switch tier {
    case "S": "S · 가장 똑똑함"
    case "A": "A · 똑똑하고 빠름"
    case "B": "B · 싸고 빠름"
    default: "C · 아주 쌈"
    }
}

/// Grade picker in the app's button style: four small segments.
struct TierPicker: View {
    var title: String
    @Binding var tier: String
    var body: some View {
        HStack {
            Text(title)
            Spacer()
            Picker(title, selection: $tier) { ForEach(tierChoices, id: \.self) { Text($0).tag($0) } }
                .pickerStyle(.segmented)
                .frame(width: 180)
        }
    }
}

/// 팀 추가: every team is a lead + staff (+ reviewers). The owner sets the size and each role's AI grade,
/// or lets the assistant decide.
struct AddTeamSheet: View {
    var opened: (String) -> Void
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var groupId = ""
    @State private var newGroup = ""
    @State private var name = ""
    @State private var purpose = ""
    @State private var isDev = false
    @State private var auto = false
    @State private var staff = 3
    @State private var reviewers = 0
    @State private var leadTier = "A"
    @State private var staffTier = "B"
    @State private var reviewerTier = "S"
    @State private var saving = false

    private struct Made: Decodable { var teamId: String; var channel: String }

    private var ready: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty && (groupId != "" ? true : !newGroup.trimmingCharacters(in: .whitespaces).isEmpty)
    }

    var body: some View {
        NavigationStack {
            Page {
                Panel {
                    VStack(alignment: .leading, spacing: 12) {
                        Picker("어느 회사", selection: $groupId) {
                            ForEach(model.bots?.groups ?? []) { Text($0.label).tag($0.id) }
                            Text("새 회사…").tag("")
                        }
                        .pickerStyle(.menu)
                        if groupId == "" {
                            TextField("새 회사 이름", text: $newGroup)
                        }
                        Divider()
                        TextField("팀 이름 (예: 디자인)", text: $name).font(.headline)
                        TextField("하는 일 (예: 화면 시안을 만들어요)", text: $purpose)
                        Divider()
                        Toggle("개발팀 (끝난 일을 검수해요)", isOn: $isDev).tint(.accentColor)
                            .onChange(of: isDev) { _, dev in reviewers = dev ? max(reviewers, 1) : 0 }
                    }
                }
                Panel {
                    VStack(alignment: .leading, spacing: 12) {
                        Picker("정하는 사람", selection: $auto) {
                            Text("직접 정하기").tag(false)
                            Text("AI에게 맡기기").tag(true)
                        }
                        .pickerStyle(.segmented)
                        if auto {
                            Text("비서가 팀이 할 일을 보고 직원 수, 검수 수, AI 등급을 정해요. 나중에 팀 설정에서 바꿀 수 있어요.")
                                .font(.subheadline).foregroundStyle(.secondary)
                        } else {
                            Text("팀장 1명").font(.subheadline.weight(.semibold))
                            Stepper("직원 \(staff)명", value: $staff, in: 1...6)
                            Stepper("검수 \(reviewers)명", value: $reviewers, in: 0...3)
                            Divider()
                            Text("AI 등급").font(.subheadline.weight(.semibold))
                            TierPicker(title: "팀장", tier: $leadTier)
                            TierPicker(title: "직원", tier: $staffTier)
                            if reviewers > 0 { TierPicker(title: "검수", tier: $reviewerTier) }
                            Text("S가 가장 똑똑하고 비싸요. 보통 팀장 A, 직원 B, 검수 S로 시작해요.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                Button {
                    Task { await save() }
                } label: {
                    HStack { Text("팀 만들기"); if saving { Spacer(); ProgressView().tint(.white) } }
                }
                .buttonStyle(.action(.primary))
                .disabled(!ready || saving)
            }
            .navigationTitle("팀 추가")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("취소") { dismiss() } } }
            .onAppear { if groupId == "", let first = model.bots?.groups.first { groupId = first.id } }
        }
    }

    private func save() async {
        guard let client = model.client else { return }
        saving = true
        defer { saving = false }
        var body: [String: Any] = ["name": name.trimmingCharacters(in: .whitespaces), "kind": isDev ? "dev" : "general"]
        if !purpose.isEmpty { body["purpose"] = purpose }
        if groupId.isEmpty { body["newGroupLabel"] = newGroup.trimmingCharacters(in: .whitespaces) } else { body["group"] = groupId }
        if auto {
            body["auto"] = true
        } else {
            body["staffCount"] = staff
            body["reviewerCount"] = reviewers
            var tiers: [String: String] = ["lead": leadTier, "staff": staffTier]
            if reviewers > 0 { tiers["reviewer"] = reviewerTier }
            body["tiers"] = tiers
        }
        do {
            let made = try await client.viewAction(Made.self, "bots", "createTeam", json: body)
            await model.refreshBasics()
            model.toast = "팀을 만들었어요"
            dismiss()
            opened(made.channel)
        } catch {
            model.toast = error.friendly
        }
    }
}

/// 팀 설정: who is in the team and each role's AI grade (changeable any time).
struct TeamSheet: View {
    var team: BotsView.Team
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var tiers: [String: String] = [:]

    private struct Ack: Decodable {}

    private var members: [BotsView.Bot] { model.bots?.members(of: team) ?? [] }
    private let order = ["lead", "staff", "reviewer"]
    private func rankWords(_ rank: String?) -> String {
        switch rank { case "lead": "팀장"; case "reviewer": "검수"; default: "직원" }
    }

    var body: some View {
        NavigationStack {
            Page {
                if team.decidedBy == "ai" {
                    Panel {
                        VStack(alignment: .leading, spacing: 4) {
                            CardHeader(title: "AI가 정한 구성이에요", subtitle: team.reason)
                            Text("아래에서 바꾸면 그다음부터는 정한 대로 해요.").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                Panel {
                    VStack(alignment: .leading, spacing: 4) {
                        CardHeader(title: "팀원 \(members.count)명", subtitle: team.purpose)
                        CardList(items: members) { bot in
                            NavigationLink { BotInstructionsScreen(botId: bot.id) } label: {
                                HStack(spacing: 12) {
                                    BotAvatar(icon: nil, name: bot.name, size: 32, avatar: bot.avatar, status: bot.status)
                                    CardRow(title: bot.name, detail: rankWords(bot.rank) + " · 일하는 방식 보기") {
                                        HStack(spacing: 8) {
                                            Text(bot.tier.map { "\($0) 등급" } ?? "").foregroundStyle(.secondary)
                                            Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
                                        }
                                    }
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                Panel {
                    VStack(alignment: .leading, spacing: 12) {
                        CardHeader(title: "역할별 AI 등급")
                        ForEach(order.filter { rank in members.contains { $0.rank == rank } }, id: \.self) { rank in
                            TierPicker(title: rankWords(rank), tier: Binding(
                                get: { tiers[rank] ?? members.first { $0.rank == rank }?.tier ?? "B" },
                                set: { value in tiers[rank] = value; Task { await save(rank, value) } }))
                        }
                    }
                }
            }
            .navigationTitle(team.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("닫기") { dismiss() } } }
        }
    }

    private func save(_ rank: String, _ tier: String) async {
        do {
            _ = try await model.client?.viewAction(Ack.self, "bots", "setTiers", json: ["teamId": team.id, "tiers": [rank: tier]])
            await model.refreshBasics()
        } catch { model.toast = error.friendly }
    }
}

/// Title bar of a team or meeting room: faces + name; tap for team settings, or open a meeting.
struct RoomHeader: View {
    var room: String
    @Environment(AppModel.self) private var model
    @State private var showTeam = false
    @State private var askingTopic = false
    @State private var topic = ""

    private struct Ack: Decodable {}

    var body: some View {
        let bots = model.bots
        if let team = bots?.team(forChannel: room) {
            let members = bots?.members(of: team) ?? []
            Button { showTeam = true } label: {
                HStack(spacing: 8) {
                    AvatarStack(names: members.map(\.name), size: 24, working: members.first?.status == "working")
                    VStack(alignment: .leading, spacing: 0) {
                        Text(team.name).font(.headline).foregroundStyle(.primary)
                        Text("팀원 \(members.count)명 · 설정").font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }
            .buttonStyle(.plain)
            .sheet(isPresented: $showTeam) { TeamSheet(team: team) }
        } else if let group = bots?.group(forMeeting: room) {
            let canStart = model.capabilities.hasAction("bots", "meeting")
            Button { askingTopic = true } label: {
                HStack(spacing: 8) {
                    AvatarStack(names: group.bots.filter { $0.rank == "lead" }.map(\.name), size: 22)
                    VStack(alignment: .leading, spacing: 0) {
                        Text("팀장회의").font(.headline).foregroundStyle(.primary)
                        Text(canStart ? "눌러서 회의 열기" : "팀장 \(group.bots.filter { $0.rank == "lead" }.count)명")
                            .font(.caption2).foregroundStyle(canStart ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                    }
                }
            }
            .buttonStyle(.plain)
            .disabled(!canStart)
            .alert("무엇에 대해 회의할까요?", isPresented: $askingTopic) {
                TextField("예: 다음 달 신메뉴", text: $topic)
                Button("회의 열기") {
                    let t = topic; topic = ""
                    Task {
                        do { _ = try await model.client?.viewAction(Ack.self, "bots", "meeting", json: ["group": group.id, "topic": t]) }
                        catch { model.toast = error.friendly }
                    }
                }
                Button("취소", role: .cancel) {}
            }
        } else {
            let bot = bots?.bot(forChannel: room)
            HStack(spacing: 8) {
                BotAvatar(icon: nil, name: bot?.name ?? model.roomTitle(room), size: 28, avatar: bot?.avatar, status: bot?.status)
                VStack(alignment: .leading, spacing: 0) {
                    Text(model.roomTitle(room)).font(.headline).lineLimit(1)
                    if let bot {
                        Text(bot.status == "working" ? "일하는 중" : ChatText.preview(bot.role ?? "", limit: 30))
                            .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
            }
        }
    }
}

/// 이 봇이 일하는 방식: the bot's role prompt, who wrote it, and an editor. The Mac refuses text that would skip 결재.
struct BotInstructionsScreen: View {
    var botId: String
    @Environment(AppModel.self) private var model
    @State private var text = ""
    @State private var editing = false
    @State private var saving = false
    @State private var confirmReset = false

    private struct Ack: Decodable {}
    private var bot: BotsView.Bot? { model.bots?.bot(id: botId) }

    private var authorWords: (String, String) {
        switch bot?.instructionsBy {
        case "owner": ("직접 고친 글", "대표님이 고친 글이에요. AI가 바꾸지 않아요.")
        case "ai": ("AI가 쓴 글", "팀이 하는 일에 맞춰 AI가 썼어요. 고치면 그 뒤로는 고친 대로 해요.")
        default: ("기본 글", "처음 정해진 글이에요. 고치면 그 뒤로는 고친 대로 해요.")
        }
    }

    var body: some View {
        Page {
            if let bot {
                Panel {
                    HStack(spacing: 12) {
                        BotAvatar(icon: nil, name: bot.name, size: 44, avatar: bot.avatar, status: bot.status)
                        CardHeader(title: bot.name, subtitle: [bot.role, bot.tier.map { "\($0) 등급" }].compactMap { $0 }.joined(separator: " · "))
                    }
                }
                Panel {
                    VStack(alignment: .leading, spacing: 10) {
                        CardHeader(title: authorWords.0, subtitle: authorWords.1)
                        if editing {
                            TextField("이 봇이 어떻게 일하면 좋을지 써 주세요", text: $text, axis: .vertical)
                                .lineLimit(6...16)
                                .padding(12)
                                .background(Color(.systemBackground), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color(.separator)))
                            HStack {
                                Text("\(text.count) / 1500").font(.caption.monospacedDigit()).foregroundStyle(text.count > 1500 ? .red : .secondary)
                                Spacer()
                                Text("보내기·결제·삭제는 어떤 글이든 늘 결재를 받아요.").font(.caption).foregroundStyle(.secondary)
                            }
                        } else {
                            Text(bot.instructions ?? "아직 정해진 글이 없어요.")
                                .foregroundStyle(bot.instructions == nil ? .secondary : .primary)
                                .textSelection(.enabled)
                        }
                    }
                }
                if editing {
                    Button { Task { await save(text) } } label: {
                        HStack { Text("저장"); if saving { Spacer(); ProgressView().tint(.white) } }
                    }
                    .buttonStyle(.action(.primary))
                    .disabled(saving || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || text.count > 1500)
                    Button("취소") { editing = false }.buttonStyle(.action(.secondary))
                } else {
                    Button("고치기") { text = bot.instructions ?? ""; editing = true }.buttonStyle(.action(.primary))
                    if bot.instructionsBy == "owner" {
                        Button("기본 글로 되돌리기") { confirmReset = true }.buttonStyle(.action(.danger))
                    }
                }
            }
        }
        .navigationTitle("일하는 방식")
        .navigationBarTitleDisplayMode(.inline)
        .task { await model.refreshBasics() }
        .refreshable { await model.refreshBasics() }
        .confirmationDialog("기본 글로 되돌릴까요?", isPresented: $confirmReset, titleVisibility: .visible) {
            Button("되돌리기", role: .destructive) { Task { await save(nil) } }
        } message: { Text("직접 고친 글은 사라지고, 다시 AI나 기본 글을 따라요.") }
    }

    private func save(_ value: String?) async {
        guard let client = model.client else { return }
        saving = true
        defer { saving = false }
        do {
            _ = try await client.viewAction(Ack.self, "bots", "setInstructions", json: ["botId": botId, "text": value.map { $0 as Any } ?? NSNull()])
            await model.refreshBasics()
            editing = false
            model.toast = value == nil ? "기본 글로 되돌렸어요" : "저장했어요. 다음 일부터 이렇게 해요."
        } catch {
            model.toast = error.friendly
        }
    }
}

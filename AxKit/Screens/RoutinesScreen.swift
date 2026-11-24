import AxKitCore
import SwiftUI

/// 루틴 (§17): things the assistant or a bot does on a schedule ("매일 아침 9시에 …"). New ones are made by asking
/// in the chat; here they are switched on/off or removed.
struct RoutinesScreen: View {
    @Environment(AppModel.self) private var model
    @State private var state: Loadable<RoutinesView> = .loading
    @State private var removing: RoutinesView.Routine?

    private struct Ack: Decodable {}

    var body: some View {
        LoadableView(state: state, retry: load) { data in
            Page {
                Panel {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("새 루틴은 비서에게 말로 부탁하세요. 예: \"매일 아침 9시에 오늘 일정 알려 줘\"")
                            .font(.subheadline).foregroundStyle(.secondary)
                        Button("비서에게 말하러 가기") { model.showRoom("") }.buttonStyle(.action(.primary))
                    }
                }
                Panel {
                    VStack(alignment: .leading, spacing: 4) {
                        CardHeader(title: "루틴 \(data.routines.count)개", subtitle: data.limit.map { "\($0)개까지 만들 수 있어요" })
                        if data.routines.isEmpty { Text("아직 루틴이 없어요").foregroundStyle(.secondary).padding(.vertical, 8) }
                        CardList(items: data.routines) { r in RoutineRow(routine: r, toggle: { await set(r, $0) }, remove: { removing = r }) }
                    }
                }
                if let follow = data.followUps, !follow.isEmpty {
                    Panel {
                        VStack(alignment: .leading, spacing: 4) {
                            CardHeader(title: "봇이 나중에 다시 볼 것")
                            CardList(items: follow) { f in
                                CardRow(title: f.what, detail: [f.bot?.name, f.dueAt.map { Format.deadline($0) }].compactMap { $0 }.joined(separator: " · "))
                            }
                        }
                    }
                }
            }
            .refreshable { await load() }
        }
        .navigationTitle("루틴")
        .task { await load() }
        .confirmationDialog("'\(removing?.title ?? "")' 루틴을 지울까요?", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }), titleVisibility: .visible) {
            Button("지우기", role: .destructive) {
                guard let r = removing else { return }
                Task {
                    do { _ = try await model.client?.viewAction(Ack.self, "routines", "remove", json: ["id": r.id]); model.toast = "루틴을 지웠어요" }
                    catch { model.toast = error.friendly }
                    await load()
                }
            }
        } message: { Text("다시는 돌지 않아요. 잠깐 쉬게 하려면 지우지 말고 스위치를 꺼 주세요.") }
    }

    private func load() async {
        guard let client = model.client else { return }
        do { state = .loaded(try await client.view(RoutinesView.self, "routines")) } catch { state = .failed(error.friendly) }
    }

    private func set(_ r: RoutinesView.Routine, _ enabled: Bool) async {
        do { _ = try await model.client?.viewAction(Ack.self, "routines", "toggle", json: ["id": r.id, "enabled": enabled]) }
        catch { model.toast = error.friendly }
        await load()
    }
}

private struct RoutineRow: View {
    var routine: RoutinesView.Routine
    var toggle: (Bool) async -> Void
    var remove: () -> Void
    @State private var on: Bool

    init(routine: RoutinesView.Routine, toggle: @escaping (Bool) async -> Void, remove: @escaping () -> Void) {
        self.routine = routine; self.toggle = toggle; self.remove = remove
        _on = State(initialValue: routine.enabled)
    }

    private var line: (String, Color) {
        var parts = [routine.scheduleLabel ?? ""]
        if let bot = routine.bot { parts.append(bot.name) }
        if !routine.enabled { parts.append("꺼짐") }
        if let at = routine.lastRun {
            if routine.lastOk == false { return ((parts + ["\(Format.relative(at)) 실패"]).filter { !$0.isEmpty }.joined(separator: " · "), .red) }
            parts.append("\(Format.relative(at)) 했어요")
        }
        return (parts.filter { !$0.isEmpty }.joined(separator: " · "), .secondary)
    }

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(routine.title)
                Text(line.0).font(.footnote).foregroundStyle(line.1)
                if let result = routine.lastResult, !result.isEmpty {
                    Text(result).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
            }
            .accessibilityElement(children: .combine)
            Spacer(minLength: 0)
            Toggle(routine.title, isOn: $on).labelsHidden().tint(.accentColor)
                .onChange(of: on) { _, value in Task { await toggle(value) } }
        }
        .padding(.vertical, 10)
        .contextMenu { Button("루틴 지우기", role: .destructive, action: remove) }
        .swipeActions { Button("지우기", role: .destructive, action: remove) }
        .accessibilityAction(named: "루틴 지우기", remove)
    }
}

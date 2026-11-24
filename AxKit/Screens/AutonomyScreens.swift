import AxKitCore
import SwiftUI

/// 알아서 하는 일: rules the owner granted from a card ("앞으로는 알아서"). Any of them can be taken back here.
struct AutonomyScreen: View {
    @Environment(AppModel.self) private var model
    @State private var state: Loadable<AutonomyView> = .loading
    @State private var stopping: AutonomyView.Rule?

    var body: some View {
        LoadableView(state: state, retry: load) { data in
            Page {
                Text("결재에서 '앞으로는 알아서'를 고르면 여기에 생겨요. 한 일은 캘린더의 '한 일'에 남아요.")
                    .font(.subheadline).foregroundStyle(.secondary).padding(.horizontal, 4)
                Panel {
                    VStack(alignment: .leading, spacing: 4) {
                        CardHeader(title: "묻지 않고 하는 일")
                        if data.rules.isEmpty { Text("아직 없어요").foregroundStyle(.secondary).padding(.vertical, 8) }
                        CardList(items: data.rules) { rule in
                            CardRow(title: rule.label,
                                    detail: [rule.since.map { "\(Format.relative($0))부터" }, rule.uses.map { "\($0)번 했어요" }].compactMap { $0 }.joined(separator: " · ")) {
                                Button("그만") { stopping = rule }.buttonStyle(.action(.danger, fullWidth: false, small: true))
                            }
                        }
                    }
                }
                if let always = data.alwaysAsk, !always.isEmpty {
                    Panel {
                        VStack(alignment: .leading, spacing: 4) {
                            CardHeader(title: "이건 언제나 물어봐요")
                            CardList(items: always.map { KV(title: $0, value: "") }) { CardRow(title: $0.title) }
                        }
                    }
                }
            }
            .refreshable { await load() }
        }
        .navigationTitle("알아서 하는 일")
        .task { await load() }
        .confirmationDialog("'\(stopping?.label ?? "")'를 그만할까요?", isPresented: Binding(get: { stopping != nil }, set: { if !$0 { stopping = nil } }), titleVisibility: .visible) {
            Button("그만하고 다시 물어보기", role: .destructive) {
                guard let rule = stopping else { return }
                Task {
                    do { _ = try await model.client?.viewAction(Ack.self, "autonomy", "revoke", json: ["id": rule.id]); model.toast = "다음부터 다시 물어볼게요" }
                    catch { model.toast = error.friendly }
                    await load()
                }
            }
        }
    }

    private struct Ack: Decodable {}

    private func load() async {
        guard let client = model.client else { return }
        do { state = .loaded(try await client.view(AutonomyView.self, "autonomy")) } catch { state = .failed(error.friendly) }
    }
}

/// AI 등급과 용도: which models count as S/A/B/C (best first inside each), and which grade each job uses.
struct ModelTiersScreen: View {
    @Environment(AppModel.self) private var model
    @State private var state: Loadable<ModelTiersView> = .loading
    @State private var reordering = false

    private struct Indexed: Identifiable { var index: Int; var model: ModelTiersView.Model; var id: String { model.id } }

    var body: some View {
        LoadableView(state: state, retry: load) { data in
            Page {
                Text("일마다 어느 등급의 AI를 쓸지 정해요. 같은 등급 안에서는 위에 있는 모델부터 쓰고, 막히면 다음 모델로 넘어가요.")
                    .font(.subheadline).foregroundStyle(.secondary).padding(.horizontal, 4)
                if let changes = data.changes, !changes.isEmpty {
                    Panel {
                        VStack(alignment: .leading, spacing: 4) {
                            CardHeader(title: "AI가 최근 바꾼 것", subtitle: data.changedAt.map { "\(Format.relative($0)) · 새 모델과 사용량을 보고 정했어요" })
                            CardList(items: changes) { CardRow(title: $0.text, detail: $0.at.map { Format.relative($0) }) }
                        }
                    }
                }
                Panel {
                    VStack(alignment: .leading, spacing: 4) {
                        CardHeader(title: "용도별 등급")
                        CardList(items: data.purposes) { purpose in
                            CardRow(title: purpose.label, detail: purpose.calls7d.map { "최근 7일 \($0)번" }) {
                                Menu {
                                    ForEach(data.tiers) { tier in
                                        Button { Task { await setPurpose(purpose, tier.id) } } label: {
                                            if tier.id == purpose.tier { Label(tier.label, systemImage: "checkmark") } else { Text(tier.label) }
                                        }
                                    }
                                } label: {
                                    Text(data.tiers.first { $0.id == purpose.tier }?.label ?? purpose.tier)
                                        .font(.subheadline.weight(.semibold))
                                        .foregroundStyle(ActionKind.secondary.foreground)
                                        .padding(.horizontal, 12).padding(.vertical, 7)
                                        .background(ActionKind.secondary.background, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                                }
                                .accessibilityLabel("\(purpose.label) 등급 바꾸기")
                            }
                        }
                    }
                }
                ForEach(data.tiers) { tier in
                    Panel {
                        VStack(alignment: .leading, spacing: 4) {
                            CardHeader(title: tier.label, subtitle: tier.summary)
                            CardList(items: Array(tier.models.enumerated()).map { Indexed(index: $0.offset, model: $0.element) }) { item in
                                CardRow(title: "\(item.index + 1). \(item.model.label)",
                                        detail: [item.model.provider, item.model.available == false ? "연결 안 됨" : nil, item.model.note].compactMap { $0 }.joined(separator: " · "),
                                        titleColor: item.model.available == false ? .secondary : .primary) {
                                    if reordering {
                                        HStack(spacing: 6) {
                                            Button { Task { await move(tier, IndexSet([item.index]), item.index - 1) } } label: { Image(systemName: "chevron.up") }
                                                .buttonStyle(.action(.secondary, fullWidth: false, small: true))
                                                .disabled(item.index == 0)
                                                .accessibilityLabel("\(item.model.label) 위로")
                                            Button { Task { await move(tier, IndexSet([item.index]), item.index + 2) } } label: { Image(systemName: "chevron.down") }
                                                .buttonStyle(.action(.secondary, fullWidth: false, small: true))
                                                .disabled(item.index == tier.models.count - 1)
                                                .accessibilityLabel("\(item.model.label) 아래로")
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
            .refreshable { await load() }
        }
        .navigationTitle("AI 등급과 용도")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button(reordering ? "완료" : "순서 바꾸기") { withAnimation { reordering.toggle() } }
            }
        }
        .task { await load() }
    }

    private struct Ack: Decodable {}

    private func load() async {
        guard let client = model.client else { return }
        do { state = .loaded(try await client.view(ModelTiersView.self, "modeltiers")) } catch { state = .failed(error.friendly) }
    }

    private func setPurpose(_ purpose: ModelTiersView.Purpose, _ tier: String) async {
        do { _ = try await model.client?.viewAction(Ack.self, "modeltiers", "purpose", json: ["id": purpose.id, "tier": tier]) }
        catch { model.toast = error.friendly }
        await load()
    }

    private func move(_ tier: ModelTiersView.Tier, _ from: IndexSet, _ to: Int) async {
        var ids = tier.models.map(\.id)
        ids.move(fromOffsets: from, toOffset: to)
        do { _ = try await model.client?.viewAction(Ack.self, "modeltiers", "rank", json: ["tier": tier.id, "order": ids]) }
        catch { model.toast = error.friendly }
        await load()
    }
}

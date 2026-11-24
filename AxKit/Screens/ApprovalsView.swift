import AxKitCore
import SwiftUI

/// 결재: everything the assistant or a bot is asking the owner — "할까요?" — answered with one tap (네/아니요/…),
/// or with "다른 지시 쓰기" for anything else.
struct ApprovalsView: View {
    @Environment(AppModel.self) private var model
    @State private var showDone = false
    @State private var showAuto = false

    private var open: [CardEvent] { model.timeline.openCards() }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    StopBanner()
                    if open.isEmpty {
                        EmptyStateView(icon: "checkmark.seal", title: "지금은 결재할 게 없어요",
                                       message: "비서나 봇이 \"이거 해도 될까요?\" 하고 물어보면 여기에 올라와요.")
                            .padding(.top, 40)
                    } else {
                        ForEach(open) { card in
                            CardPanel(card: card)
                        }
                    }
                    let done = model.timeline.finishedCards()
                    if !done.isEmpty {
                        DisclosureGroup(isExpanded: $showDone) {
                            VStack(spacing: 10) { ForEach(done) { CardPanel(card: $0, compact: true) } }.padding(.top, 8)
                        } label: {
                            Text("지난 결재 \(done.count)개").font(.headline)
                        }
                        .padding(.top, 10)
                    }
                }
                .padding(16)
            }
            .background(Theme.page)
            .recordingBarInset()
            .navigationTitle("결재")
            .toolbar {
                if model.capabilities.hasView("autonomy") {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button { showAuto = true } label: { Label("자동 승인", systemImage: "checkmark.circle.badge.questionmark").labelStyle(.titleOnly) }
                            .accessibilityHint("묻지 않고 알아서 하는 일 목록을 열어요")
                    }
                }
            }
            .sheet(isPresented: $showAuto) {
                NavigationStack {
                    AutonomyScreen()
                        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("닫기") { showAuto = false } } }
                }
            }
            .refreshable { await model.refreshBasics() }
        }
    }
}

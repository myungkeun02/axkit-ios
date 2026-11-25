import AxKitCore
import SwiftUI

struct RootView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Group {
            if model.isPaired {
                TabView(selection: $model.tab) {
                    HomeView()
                        .tabItem { Label("홈", systemImage: "bubble.left.and.bubble.right") }
                        .tag(Tab.home)
                    ApprovalsView()
                        .tabItem { Label("결재", systemImage: "checkmark.seal") }
                        .badge(model.openCardCount)
                        .tag(Tab.approvals)
                    DocsView()
                        .tabItem { Label("문서", systemImage: "doc.text") }
                        .tag(Tab.docs)
                    CalendarScreen()
                        .tabItem { Label("캘린더", systemImage: "calendar") }
                        .tag(Tab.calendar)
                    MoreView()
                        .tabItem { Label("더보기", systemImage: "ellipsis") }
                        .tag(Tab.more)
                }
            } else {
                NavigationStack { PairView(isOnboarding: true) }
            }
        }
        .overlay(alignment: .top) { ToastView() }
    }
}

struct ToastView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if let text = model.toast {
            Text(text)
                .font(.subheadline.weight(.semibold))
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .background(.regularMaterial, in: Capsule())
                .shadow(color: .black.opacity(0.12), radius: 10, y: 4)
                .padding(.top, 8)
                .padding(.horizontal, 24)
                .transition(.move(edge: .top).combined(with: .opacity))
                .task(id: text) {
                    try? await Task.sleep(nanoseconds: 2_800_000_000)
                    withAnimation { model.toast = nil }
                }
                .onTapGesture { model.toast = nil }
                .accessibilityAddTraits(.isStaticText)
        }
    }
}

/// The global stop switch is on: say so everywhere, plainly.
struct StopBanner: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        if model.stopped {
            Label("전체 정지 중이에요. 보내기·결제·삭제는 맥에서 막혀 있어요.", systemImage: "hand.raised.fill")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.white)
                .padding(10)
                .frame(maxWidth: .infinity)
                .background(.red)
        }
    }
}

/// Shown on 홈 only when the Mac can't be reached; tapping opens 설정 및 연결.
struct ConnectionBanner: View {
    @Environment(AppModel.self) private var model
    @State private var showSettings = false
    var body: some View {
        if model.connection != .live && (model.showsConnectionTrouble || model.connection == .unauthorized) {
            Button { showSettings = true } label: {
                HStack {
                    Circle().fill(model.connection.color).frame(width: 8, height: 8)
                    Text(model.connection == .connecting ? "맥에 다시 연결하는 중" : model.connection.label).font(.footnote.weight(.semibold))
                    Spacer()
                    Text("설정 보기").font(.footnote.weight(.semibold)).foregroundStyle(.tint)
                }
                .padding(.horizontal, 14).padding(.vertical, 10)
                .background(Theme.cardBackground, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .padding(.horizontal, 14).padding(.top, 6)
            }
            .buttonStyle(.plain)
            .sheet(isPresented: $showSettings) { NavigationStack { SettingsScreen(inSheet: true) } }
        }
    }
}

/// 홈 › 오늘: today's plans, to-dos and how many 결재 are waiting.
struct TodaySheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var state: Loadable<TodayView> = .loading

    var body: some View {
        LoadableView(state: state, retry: load) { today in
            List {
                if model.openCardCount > 0 {
                    Section {
                        Button { dismiss(); model.tab = .approvals } label: {
                            HStack { Text("결재 기다리는 것 \(model.openCardCount)개"); Spacer(); Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary) }
                        }
                    }
                }
                Section("일정") {
                    if let events = today.events, !events.isEmpty {
                        ForEach(events, id: \.self) { e in
                            HStack(alignment: .firstTextBaseline, spacing: 12) {
                                Text(e.allDay == true ? "종일" : ISODates.parse(e.start).map { Format.clock($0) } ?? "")
                                    .font(.subheadline.monospacedDigit()).foregroundStyle(.secondary).frame(width: 76, alignment: .leading)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(ChatText.preview(e.title, limit: 80))
                                    // §36: which calendar, when the owner has more than one.
                                    if let cal = e.calendar, !cal.isEmpty {
                                        Text(verbatim: cal).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                    }
                                }
                            }
                        }
                    } else {
                        Text(today.events == nil ? "캘린더가 아직 연결되지 않았어요" : "남은 일정이 없어요").foregroundStyle(.secondary)
                    }
                }
                Section("할 일") {
                    if let todos = today.todos, !todos.isEmpty {
                        ForEach(todos, id: \.self) { todo in
                            VStack(alignment: .leading, spacing: 4) {
                                ExpandableText(text: ChatText.clean(todo.text), limit: 3)
                                if let due = todo.due, let words = Self.dueWords(due, today: today.date) {
                                    Text(words.0).font(.caption.weight(.semibold)).foregroundStyle(words.1 ? Color.red : .secondary)
                                }
                            }
                            .padding(.vertical, 2)
                        }
                    } else {
                        Text("오늘 할 일이 없어요").foregroundStyle(.secondary)
                    }
                }
            }
            .refreshable { await load() }
        }
        .navigationTitle("오늘")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("닫기") { dismiss() } } }
        .task { await load() }
    }

    /// "2026-10-19" on 2026-11-20 → ("32일 지남", true); today → ("오늘까지", false).
    static func dueWords(_ due: String, today: String) -> (String, Bool)? {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = Format.seoul
        f.dateFormat = "yyyy-MM-dd"
        guard let d = f.date(from: String(due.prefix(10))), let t = f.date(from: String(today.prefix(10))) else { return nil }
        let days = Int((t.timeIntervalSince(d) / 86_400).rounded())
        if days > 0 { return ("\(days)일 지남", true) }
        if days == 0 { return ("오늘까지", false) }
        if days == -1 { return ("내일까지", false) }
        return ("\(Format.monthDay(d))까지", false)
    }

    private func load() async {
        guard let client = model.client else { return }
        do { state = .loaded(try await client.view(TodayView.self, "today")) } catch { state = .failed(error.friendly) }
    }
}

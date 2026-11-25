import AxKitCore
import SwiftUI

enum Route: Hashable { case room(String) }

/// 홈: the main chat. The button at the top left slides the room list in over the chat (the assistant on top,
/// then each company's rooms); the list comes from the Mac, so new bots appear without an app update.
/// No dragging: the old drag-to-open sheet fought the chat's scrolling and the back swipe, could stay half open,
/// and switched rooms when a drag ended over a row. Now a room changes only on a tap while the list is open.
struct HomeView: View {
    @Environment(AppModel.self) private var model
    @State private var path: [Route] = []
    @State private var picker = RoomPicker()

    var body: some View {
        GeometryReader { geo in
            let width = min(geo.size.width * 0.84, 340)
            NavigationStack(path: $path) {
                VStack(spacing: 0) {
                    StopBanner()
                    ConnectionBanner()
                    ChatRoomView(room: "")
                }
                .recordingBarInset()
                .navigationTitle(model.assistantName)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button { withAnimation(.snappy) { picker.open() } } label: {
                            ZStack(alignment: .topTrailing) {
                                Image(systemName: "person.2.fill")
                                if unreadInBots > 0 { Circle().fill(.red).frame(width: 9, height: 9).offset(x: 4, y: -3) }
                            }
                        }
                        .accessibilityLabel("방 목록 열기" + (unreadInBots > 0 ? ", 새 글 \(unreadInBots)개" : ""))
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("오늘") { model.showingToday = true }.accessibilityHint("오늘 일정과 할 일을 봐요")
                    }
                }
                .navigationDestination(for: Route.self) { route in
                    switch route {
                    case .room(let room):
                        ChatRoomView(room: room)
                            .navigationTitle(model.roomTitle(room))
                            .navigationBarTitleDisplayMode(.inline)
                            .toolbar {
                                ToolbarItem(placement: .principal) { RoomHeader(room: room) }
                                ToolbarItem(placement: .topBarTrailing) { ShortViewToggle(room: room) }
                            }
                    }
                }
            }
            .accessibilityHidden(picker.isOpen)
            .overlay {
                if picker.isOpen {
                    // Dim the chat underneath; tapping it closes the list without changing the room.
                    Color.black.opacity(0.25)
                        .ignoresSafeArea()
                        .onTapGesture { withAnimation(.snappy) { picker.close() } }
                        .accessibilityHidden(true)
                        .transition(.opacity)
                }
            }
            .overlay(alignment: .leading) {
                if picker.isOpen {
                    VStack(spacing: 0) {
                        HStack {
                            Text("방 목록").font(.headline)
                            Spacer()
                            Button { withAnimation(.snappy) { picker.close() } } label: {
                                Image(systemName: "xmark").font(.body.weight(.semibold)).padding(8).contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("방 목록 닫기")
                        }
                        .padding(.horizontal, 20)
                        .padding(.top, 6)
                        BotDrawer { room in pick(room) }
                    }
                    .frame(width: width)
                    .frame(maxHeight: .infinity, alignment: .top)
                    .background(Color(.systemBackground).ignoresSafeArea())
                    .overlay(alignment: .trailing) { Rectangle().fill(Color(.separator)).frame(width: 0.5).ignoresSafeArea() }
                    .shadow(color: .black.opacity(0.18), radius: 12, x: 4)
                    .transition(.move(edge: .leading))
                    .accessibilityAddTraits(.isModal)
                    .accessibilityAction(.escape) { withAnimation(.snappy) { picker.close() } }
                }
            }
        }
        .sheet(isPresented: Bindable(model).showingToday) { NavigationStack { TodaySheet() } }
        .onChange(of: model.openRoomList) { _, on in
            guard on else { return }
            model.openRoomList = false
            path = []
            withAnimation(.snappy) { picker.open() }
        }
        .onChange(of: model.openRoom) { _, room in
            guard let room else { return }
            model.openRoom = nil
            picker.close()
            path = room.isEmpty ? [] : [.room(room)]
        }
    }

    private func pick(_ room: String) {
        var next = picker
        guard let rooms = next.pick(room) else { return }
        withAnimation(.snappy) { picker = next }
        path = rooms.map { .room($0) }
    }

    private var unreadInBots: Int {
        model.roomSections.flatMap(\.rooms).reduce(0) { $0 + $1.unread }
    }
}

/// The left sheet: the assistant on top, then each company's rooms (팀장회의, each team or bot) newest first like a
/// messenger, each with its last line and an unread dot. Quiet rooms fold away; read-only notice rooms are not shown.
/// Rooms open with `safeTap`, not Button: a Button fires when the finger lifts inside it even after sliding
/// sideways, so a sideways swipe across a row switched the chat to that room.
struct BotDrawer: View {
    var open: (String) -> Void
    @Environment(AppModel.self) private var model
    @State private var addingTeam = false
    @State private var showQuiet: Set<String> = []

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Group {
                    HStack(spacing: 12) {
                        BotAvatar(icon: nil, name: model.assistantName, size: 52)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(model.assistantName).font(.title3.bold()).foregroundStyle(.primary)
                            Text(model.bots?.main?.subtitle ?? "무엇이든 먼저 여기에 말하세요").font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                }
                .safeTap { open("") }
                .padding(.top, 8)

                ForEach(model.roomSections) { section in
                    let quiet = section.rooms.filter { $0.last == nil }
                    let active = section.rooms.filter { $0.last != nil }
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text(section.label).font(.headline)
                            if let summary = section.summary, !summary.isEmpty { Text(summary).font(.caption).foregroundStyle(.secondary) }
                        }
                        .accessibilityAddTraits(.isHeader)
                        .padding(.bottom, 2)
                        ForEach(active) { room in
                            RoomRow(room: room).safeTap { open(room.id) }
                        }
                        if !quiet.isEmpty {
                            let shown = showQuiet.contains(section.id)
                            Button {
                                withAnimation(.snappy) { if shown { showQuiet.remove(section.id) } else { showQuiet.insert(section.id) } }
                            } label: {
                                HStack(spacing: 6) {
                                    Text(shown ? "조용한 방 접기" : "아직 이야기가 없는 방 \(quiet.count)개")
                                    Image(systemName: shown ? "chevron.up" : "chevron.down").font(.caption.weight(.semibold))
                                }
                                .font(.footnote.weight(.medium))
                                .foregroundStyle(.secondary)
                                .padding(.vertical, 8)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            if shown {
                                ForEach(quiet) { room in
                                    RoomRow(room: room).safeTap { open(room.id) }
                                }
                            }
                        }
                    }
                }
                if model.capabilities.has("bot-teams") {
                    Button("팀 추가") { addingTeam = true }
                        .buttonStyle(.action(.secondary))
                        .padding(.top, 4)
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
        }
        .frame(maxHeight: .infinity)
        .sheet(isPresented: $addingTeam) { AddTeamSheet { channel in open(channel) } }
    }
}

/// One room in the list: faces, name, a status chip, the last line ("Leo: …") and when, an unread dot.
private struct RoomRow: View {
    var room: AppModel.RoomListItem
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 12) {
            Group {
                if room.faces.count > 1 {
                    AvatarStack(names: room.faces, size: 28, working: room.status == "working")
                } else {
                    BotAvatar(icon: nil, name: room.faces.first ?? room.title, size: 40, avatar: room.avatar, status: room.status)
                }
            }
            .frame(width: 48, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(room.title).font(.body.weight(room.unread > 0 ? .bold : .semibold)).lineLimit(1)
                    ForEach(room.chips, id: \.self) { Chip(text: $0) }
                    Spacer(minLength: 4)
                    if let at = room.last?.at {
                        Text(Format.relative(at)).font(.caption).foregroundStyle(room.unread > 0 ? Color.accentColor : .secondary)
                    }
                }
                HStack(alignment: .top, spacing: 6) {
                    if let busy = model.activity[room.id] {
                        // §4 `activity`: the assistant is answering in this room right now.
                        Text(busy.words + "…")
                            .font(.subheadline).foregroundStyle(Color.accentColor)
                            .lineLimit(1)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                    Text(room.last?.text ?? room.subtitle ?? "")
                        .font(.subheadline)
                        .foregroundStyle(room.unread > 0 ? .primary : .secondary)
                        .lineLimit(2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    if room.unread > 0 {
                        Circle().fill(Color.accentColor).frame(width: 9, height: 9).padding(.top, 5)
                    }
                }
            }
        }
        .padding(.vertical, 7)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityValue(room.unread > 0 ? "새 글 \(room.unread)개" : "")
    }
}

struct AvatarStack: View {
    var names: [String]
    var size: CGFloat
    var working = false
    var body: some View {
        HStack(spacing: -size * 0.35) {
            ForEach(Array(names.prefix(3).enumerated()), id: \.offset) { i, name in
                BotAvatar(icon: nil, name: name, size: size, status: i == 0 && working ? "working" : nil)
                    .background(Circle().fill(Color(.systemBackground)).padding(-1.5))
            }
        }
        .frame(width: size * (1 + 0.65 * CGFloat(max(min(names.count, 3), 1) - 1)), alignment: .leading)
    }
}

struct UnreadBadge: View {
    var count: Int
    var body: some View {
        if count > 0 {
            Text("\(count)").font(.caption.bold()).foregroundStyle(.white).padding(.horizontal, 7).padding(.vertical, 3).background(.red, in: Capsule())
                .accessibilityLabel("새 글 \(count)개")
        }
    }
}

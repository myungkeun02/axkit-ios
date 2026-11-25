import AxKitCore
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

/// One room: the main chat ("") or a bot's channel. Same look everywhere.
struct ChatRoomView: View {
    var room: String
    @Environment(AppModel.self) private var model
    @FocusState private var focused: Bool
    /// The laid-out rows, rebuilt only when this room (or who speaks for it) changes — not on every redraw.
    @State private var feed = FeedCache()

    private var items: [Timeline.Item] { model.timeline.items(in: room) }
    private var bot: BotsView.Bot? { model.bots?.bot(forChannel: room) }
    @State private var openFolds: Set<String> = []
    /// The newest line is on screen; new lines scroll into view only then.
    @State private var atBottom = true
    @State private var unseenBelow = false

    /// Who speaks for this room when a line has no author: the team lead, else the assistant.
    private var lead: RoomFeed.Speaker? {
        guard !room.isEmpty, model.bots?.group(forMeeting: room) == nil, let bot else { return nil }
        return RoomFeed.Speaker(id: bot.id, name: bot.name, avatar: bot.avatar)
    }

    var body: some View {
        let rows = feed.rows(items, room: room, lead: lead, assistant: model.assistantName, timeline: model.timeline,
                             short: room.isEmpty || model.shortRooms.contains(room))
        let recent = Set(items.suffix(2).map(\.seq))
        let asking = Timeline.openQuestion(items)
        let waiting = model.pendingMessages(in: room)
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    if items.isEmpty && waiting.isEmpty { intro.padding(.top, 40) }
                    if model.oldestSeq > 1, let first = items.first, first.seq <= model.oldestSeq + 1 {
                        Text("이전 기록은 맥에 없어요").font(.caption).foregroundStyle(.tertiary).frame(maxWidth: .infinity).padding(.vertical, 6)
                    }
                    ForEach(rows) { row in
                        self.row(row, recent: recent, asking: asking).id(row.id)
                    }
                    ForEach(waiting) { message in
                        PendingBubble(message: message)
                    }
                    if room.isEmpty {
                        ForEach(model.waitingFiles, id: \.self) { name in
                            OwnerBubble(text: "파일 · \(name)", footnote: "맥이 연결되면 보낼게요")
                        }
                    }
                    if let busy = model.activity[room] {
                        BusyRow(busy: busy).transition(.opacity)
                    }
                    Color.clear.frame(height: 1).id("bottom")
                        .onAppear { atBottom = true; unseenBelow = false; model.markRead(room) }
                        .onDisappear { atBottom = false }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
            }
            .scrollDismissesKeyboard(.interactively)
            .simultaneousGesture(TapGesture().onEnded { focused = false })
            .defaultScrollAnchor(.bottom)
            .animation(.easeOut(duration: 0.2), value: model.activity[room])
            .onChange(of: model.activity[room] != nil) { _, busy in
                if busy, atBottom { withAnimation { proxy.scrollTo("bottom", anchor: .bottom) } }
            }
            // The work strip above the box came or went: the box got taller or shorter, keep the last line in view.
            .onChange(of: model.work.flatMap(WorkSheet.strip) != nil) {
                if atBottom { proxy.scrollTo("bottom", anchor: .bottom) }
            }
            .onChange(of: waiting.count) { before, after in
                // The owner just sent something: always show it.
                if after > before { withAnimation { proxy.scrollTo("bottom", anchor: .bottom) } }
            }
            .onChange(of: items.last?.seq) {
                // Reading further up: leave the place alone and say there is more below.
                if atBottom {
                    // A long answer opens at its first line, not its last.
                    if case .message(let m)? = items.last, m.role != .owner, m.text.count > 600 {
                        withAnimation { proxy.scrollTo("e-\(m.seq)", anchor: .top) }
                    } else {
                        withAnimation { proxy.scrollTo("bottom", anchor: .bottom) }
                    }
                    model.markRead(room)
                } else {
                    unseenBelow = true
                }
            }
            .onAppear { model.markRead(room) }
            .overlay(alignment: .bottom) {
                if unseenBelow {
                    Text("새 글 ↓")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 14).padding(.vertical, 8)
                        .background(Color.accentColor, in: Capsule())
                        .padding(.bottom, 8)
                        .safeTap { withAnimation { proxy.scrollTo("bottom", anchor: .bottom) }; unseenBelow = false }
                        .accessibilityLabel("새 글 보기")
                        .accessibilityAddTraits(.isButton)
                        .transition(.opacity)
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            if model.canWrite(in: room) {
                VStack(spacing: 0) {
                    WorkStrip()
                    ChatComposer(room: room, placeholder: placeholder, focused: $focused)
                }
            } else {
                Text("이 방은 보기만 해요. 지시는 \(model.assistantName)에게 해 주세요.")
                    .font(.footnote).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity).padding(.vertical, 12).background(.bar)
            }
        }
        .background(Theme.page)
    }

    @ViewBuilder private var intro: some View {
        if let group = model.bots?.group(forMeeting: room) {
            VStack(spacing: 8) {
                AvatarStack(names: group.bots.filter { $0.rank == "lead" }.map(\.name), size: 44)
                Text("\(group.label) 팀장회의").font(.title3.bold())
                Text("팀장들이 모여 이야기하는 방이에요. 여기에 쓰면 다음 회의 주제가 돼요.")
                    .font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
        } else if let bot {
            VStack(spacing: 8) {
                BotAvatar(icon: nil, name: bot.name, size: 88, avatar: bot.avatar, status: bot.status)
                Text(bot.name).font(.title3.bold())
                if let role = bot.role { Text(role).foregroundStyle(.secondary) }
                Text("아직 나눈 이야기가 없어요. 여기에 쓰면 \(bot.name)에게 바로 가요.").font(.footnote).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
        } else if room.isEmpty {
            EmptyStateView(icon: "bubble.left", title: "무엇이든 말해 보세요",
                           message: "예: \"내일 일정 알려 줘\", \"앱 버그 고쳐 줘\", \"원두 주문해 줘\"\n알맞은 봇이 있으면 \(model.assistantName)가 알아서 맡겨요.")
        } else {
            EmptyStateView(icon: "bubble.left.and.bubble.right", title: "아직 조용해요", message: "새 이야기가 생기면 여기에 보여요.")
        }
    }

    @ViewBuilder private func row(_ row: RoomFeed.Row, recent: Set<Int>, asking: Int?) -> some View {
        switch row {
        case .day(let label):
            DayLine(label: label)
        case .entry(let entry):
            FeedEntry(entry: entry, room: room, showFace: !room.isEmpty, showChoices: recent.contains(entry.seq), asking: asking == entry.seq)
        case .folded(let fold):
            FoldedRun(fold: fold, room: room, isOpen: openFolds.contains(fold.id)) {
                withAnimation(.snappy) {
                    if openFolds.contains(fold.id) { openFolds.remove(fold.id) } else { openFolds.insert(fold.id) }
                }
            }
        case .system(let item):
            switch item {
            case .notice(let n): NoticeRow(notice: n, room: room, showChoices: asking == n.seq)
            case .card(let id, _):
                if let card = model.timeline.card(id), !model.timeline.isDuplicate(id) { CardLine(card: card) }
            case .delegation(let d): DelegationRow(event: d)
            case .message: EmptyView()
            }
        }
    }

    private var placeholder: String {
        if model.bots?.group(forMeeting: room) != nil { return "팀장들에게 한마디 하기" }
        if let bot { return "\(bot.name)에게 바로 지시하기" }
        return "\(model.assistantName)에게 무엇이든 말해 보세요"
    }

    /// Photos go as JPEG, made smaller until they fit the Mac's 12 MB limit.
    static func photoForSending(_ data: Data) -> (Data, String) {
        guard var image = UIImage(data: data) else { return (data, "image/png") }
        let limit = 12 * 1024 * 1024
        var out = image.jpegData(compressionQuality: 0.85) ?? data
        while out.count > limit, max(image.size.width, image.size.height) > 800 {
            let scale = 0.7
            let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
            image = UIGraphicsImageRenderer(size: size).image { _ in image.draw(in: CGRect(origin: .zero, size: size)) }
            out = image.jpegData(compressionQuality: 0.8) ?? out
        }
        return (out, "image/jpeg")
    }
}

/// Remembers the rows of one room; RoomFeed.build runs again only when the room's items or speaker change.
@MainActor final class FeedCache {
    private struct Key: Equatable {
        var count: Int, first: Int?, last: Int?, cards: Int, lead: RoomFeed.Speaker?, assistant: String, day: Int, short: Bool
    }
    private var key: Key?
    private var cached: [RoomFeed.Row] = []

    func rows(_ items: [Timeline.Item], room: String, lead: RoomFeed.Speaker?, assistant: String, timeline: Timeline, short: Bool) -> [RoomFeed.Row] {
        let now = Date()
        // The day is in the key so "오늘" turns into "어제" after midnight.
        let key = Key(count: items.count, first: items.first?.seq, last: items.last?.seq, cards: timeline.cards.count,
                      lead: lead, assistant: assistant, day: Int(now.timeIntervalSince1970 + 9 * 3600) / 86_400, short: short)
        if key == self.key { return cached }
        self.key = key
        cached = RoomFeed.build(items, room: room, lead: lead, assistant: assistant, cardDates: timeline.cards.mapValues(\.at), now: now, short: short)
        return cached
    }
}

/// The input box. Its own view, so typing a letter redraws only the box and not the whole room.
struct ChatComposer: View {
    var room: String
    var placeholder: String
    var focused: FocusState<Bool>.Binding
    @Environment(AppModel.self) private var model
    @State private var draft = ""
    @State private var draftLoaded = false
    @State private var dictation = Dictation()
    /// When dictated words last landed in the box: the send button takes that spot, so a second tap on the
    /// stop button must not send them unread.
    @State private var dictatedAt = Date.distantPast
    /// When the box was last sent: the mic takes the send button's spot, so a double tap must not start a recording.
    @State private var sentAt = Date.distantPast
    @State private var photoPicks: [PhotosPickerItem] = []
    @State private var pickingPhotos = false
    @State private var pickingFiles = false

    private var isEmpty: Bool { draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    /// §30: only when the Mac says it can write speech down.
    private var canDictate: Bool { model.capabilities.has("dictation") }

    /// "@" typed in the main conversation: the bots to offer.
    private var mentionChoices: [BotsView.Bot] {
        guard room.isEmpty, let bots = model.bots, let query = Mentions.query(in: draft) else { return [] }
        return Mentions.candidates(bots.allBots, query: query)
    }

    var body: some View {
        VStack(spacing: 0) {
        let choices = mentionChoices
        if !choices.isEmpty {
            MentionBar(bots: choices) { bot in draft = Mentions.insert(bot.name, into: draft) }
        }
        HStack(alignment: .bottom, spacing: 8) {
            // §37: team and bot rooms too, when the Mac puts a file in the room it came from (`share-rooms`).
            if model.canAttach(in: room) && !dictation.isBusy {
                Menu {
                    Button { pickingPhotos = true } label: { Label("사진 보내기", systemImage: "photo") }
                    Button { pickingFiles = true } label: { Label("파일 보내기", systemImage: "doc") }
                } label: {
                    Image(systemName: model.sendingFiles > 0 ? "arrow.up.doc" : "plus.circle")
                        .font(.system(size: 26))
                        .foregroundStyle(.secondary)
                        .frame(height: 40)
                        .symbolEffect(.pulse, isActive: model.sendingFiles > 0)
                }
                .accessibilityLabel(model.sendingFiles > 0 ? "보내는 중" : "사진이나 파일 보내기")
            }
            if dictation.isRecording {
                DictationStrip(dictation: dictation)
            } else {
                TextField(dictation.phase == .transcribing ? "맥이 받아쓰는 중…" : placeholder, text: $draft, axis: .vertical)
                    .lineLimit(1...6)
                    .focused(focused)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(Theme.cardBackground, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                    .submitLabel(.send)
                    .accessibilityIdentifier("composer")
            }
            if canDictate {
                switch dictation.phase {
                case .recording:
                    // Tap again: stop and let the Mac write it down.
                    Button { dictation.finish() } label: {
                        Image(systemName: "stop.circle.fill").font(.system(size: 34)).foregroundStyle(.red)
                    }
                    .accessibilityLabel("말하기 끝내고 받아쓰기")
                case .transcribing:
                    Button { dictation.cancel() } label: {
                        ZStack {
                            ProgressView()
                            Image(systemName: "xmark").font(.system(size: 9, weight: .bold)).foregroundStyle(.secondary)
                        }
                        .frame(width: 34, height: 34)
                        .background(Theme.cardBackground, in: Circle())
                    }
                    .accessibilityLabel("받아쓰는 중, 누르면 취소")
                case .idle:
                    Button {
                        guard Date().timeIntervalSince(sentAt) > 1.2 else { return }
                        focused.wrappedValue = false
                        Task { await dictation.start() }
                    } label: {
                        Image(systemName: "mic.circle").font(.system(size: isEmpty ? 34 : 28))
                            .foregroundStyle(isEmpty ? Color.accentColor : .secondary)
                    }
                    .disabled(model.recorder.isRecording)
                    .accessibilityLabel("말로 입력하기")
                }
            }
            if !dictation.isBusy && (!isEmpty || !canDictate) {
                Button {
                    guard Date().timeIntervalSince(dictatedAt) > 1.2 else { return }
                    // The last Hangul syllable may still be in composition: finish it, then send the whole text once.
                    sentAt = Date()
                    TextComposition.finish {
                        model.send(draft, in: room)
                        draft = ""
                        sentAt = Date()
                    }
                } label: {
                    Image(systemName: "arrow.up.circle.fill").font(.system(size: 34))
                }
                .disabled(isEmpty)
                .accessibilityLabel("보내기")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
        }
        .onAppear { dictation.onText = { words in draft = DictationRules.insert(words, into: draft); dictatedAt = Date() } }
        .onChange(of: dictation.problem) { _, problem in
            guard let problem else { return }
            model.toast = problem
            dictation.problem = nil
        }
        .onDisappear { dictation.cancel() }
        // What was typed stays with its room, across room changes and launches.
        .onAppear { if !draftLoaded { draft = model.drafts[room] ?? ""; draftLoaded = true } }
        .onChange(of: draft) { _, text in
            let kept = text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : text
            if model.drafts[room] != kept { model.drafts[room] = kept }
        }
        .photosPicker(isPresented: $pickingPhotos, selection: $photoPicks, maxSelectionCount: 5, matching: .images)
        .onChange(of: photoPicks) { _, picks in
            guard !picks.isEmpty else { return }
            photoPicks = []
            Task {
                for (i, pick) in picks.enumerated() {
                    guard let data = try? await pick.loadTransferable(type: Data.self) else { continue }
                    // Decoding and shrinking a 48 MP photo takes a while: never on the main thread.
                    let (bytes, type) = await Task.detached(priority: .userInitiated) { ChatRoomView.photoForSending(data) }.value
                    model.sendFile(bytes, in: room, name: "사진-\(Int(Date().timeIntervalSince1970))-\(i + 1).\(type == "image/jpeg" ? "jpg" : "png")", contentType: type)
                }
            }
        }
        .fileImporter(isPresented: $pickingFiles, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
            guard case .success(let urls) = result else { return }
            for url in urls {
                let name = url.lastPathComponent
                let type = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
                Task {
                    // Size first (a 2 GB video is never read into memory), then read off the main thread.
                    let read: Result<Data, AttachError> = await Task.detached(priority: .userInitiated) {
                        let scoped = url.startAccessingSecurityScopedResource()
                        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                        if let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size > AppModel.fileLimit { return .failure(.tooBig) }
                        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return .failure(.unreadable) }
                        return .success(data)
                    }.value
                    switch read {
                    case .success(let data): model.sendFile(data, in: room, name: name, contentType: type)
                    case .failure(.tooBig): model.toast = AppModel.tooBigWords
                    case .failure(.unreadable): model.toast = "\(name)을(를) 열지 못했어요."
                    }
                }
            }
        }
    }

}

enum AttachError: Error { case tooBig, unreadable }

/// The owner's own line: right side, a light bubble so bots' words stay the focus.
struct OwnerBubble: View {
    var text: String
    var footnote: String?
    var time: Date? = nil
    var body: some View {
        VStack(alignment: .trailing, spacing: 3) {
            ExpandableText(text: text, limit: 12)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .foregroundStyle(.primary)
                .background(Theme.ownerBubble, in: RoundedRectangle(cornerRadius: Theme.corner, style: .continuous))
                .opacity(footnote == nil ? 1 : 0.6)
            if let footnote { Text(footnote).font(.caption2).foregroundStyle(.secondary) }
            else if let time { Text(Format.clock(time)).font(.caption2).foregroundStyle(.tertiary) }
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
        .padding(.leading, 48)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("나: \(text)" + (footnote.map { ", \($0)" } ?? ""))
    }
}

/// A message that has not reached the Mac (or just did and is on its way back): never lost, never shown twice.
struct PendingBubble: View {
    var message: PendingMessage
    @Environment(AppModel.self) private var model
    @State private var confirmDelete = false

    var body: some View {
        let sent = model.isSent(message)
        let note = sent ? "보냄" : message.showsFailed ? nil : (model.connection == .live ? "보내는 중…" : "맥이 연결되면 보낼게요")
        VStack(alignment: .trailing, spacing: 4) {
            OwnerBubble(text: message.text, footnote: note)
            if message.showsFailed && !sent {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.red)
                    Text(message.failed.map { "보내지 못했어요 · \($0)" } ?? "보내지 못했어요").foregroundStyle(.secondary).lineLimit(2)
                    Text("다시 보내기").fontWeight(.semibold).foregroundStyle(.tint)
                        .safeTap { model.resend(message) }
                        .accessibilityAddTraits(.isButton)
                }
                .font(.caption)
                .multilineTextAlignment(.trailing)
            }
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
        .contextMenu {
            // Already at the Mac (or on its way): nothing to resend or delete there.
            if !sent && message.showsFailed {
                Button { model.resend(message) } label: { Label("다시 보내기", systemImage: "arrow.clockwise") }
            }
            Button { UIPasteboard.general.string = message.text } label: { Label("복사", systemImage: "doc.on.doc") }
            if !sent {
                Button(role: .destructive) { model.discard(message) } label: { Label("삭제", systemImage: "trash") }
            }
        }
    }
}

/// "오늘", "11월 18일 화요일" between days.
struct DayLine: View {
    var label: String
    var body: some View {
        HStack(spacing: 10) {
            Rectangle().fill(Color(.separator)).frame(height: 0.5)
            Text(label).font(.caption.weight(.medium)).foregroundStyle(.secondary).fixedSize()
            Rectangle().fill(Color(.separator)).frame(height: 0.5)
        }
        .padding(.vertical, 8)
        .accessibilityAddTraits(.isHeader)
    }
}

/// Long text shows its first lines and a "더 보기" that opens the rest in place.
struct ExpandableText: View {
    var text: String
    var limit = 10
    var font: Font = .body
    @State private var open = false

    private var isLong: Bool { text.count > limit * 38 || text.components(separatedBy: "\n").count > limit }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            MarkdownText(text)
                .font(font)
                .lineLimit(open || !isLong ? nil : limit)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            if isLong {
                Button(open ? "접기" : "더 보기") { withAnimation(.snappy) { open.toggle() } }
                    .font(.footnote.weight(.semibold))
                    .buttonStyle(.plain)
                    .foregroundStyle(.tint)
            }
        }
    }
}

/// One line in a room: face and name on the first of a run, who it was said to, the bubble, then any replies folded below.
struct FeedEntry: View {
    var entry: RoomFeed.Entry
    var room: String
    /// Faces in bot rooms; the main room is a one-to-one chat with the assistant.
    var showFace: Bool
    /// Reaction buttons (the newest lines).
    var showChoices: Bool
    /// This line's 선택지 are the room's open question.
    var asking = false
    var compact = false
    @Environment(AppModel.self) private var model
    @State private var repliesOpen = false

    private let face: CGFloat = 34

    var body: some View {
        if entry.speaker.isOwner {
            OwnerBubble(text: entry.text, footnote: nil, time: entry.showHeader ? entry.at : nil)
        } else {
            HStack(alignment: .top, spacing: 8) {
                if showFace {
                    if entry.showHeader {
                        BotAvatar(icon: nil, name: entry.speaker.name, size: compact ? 26 : face, avatar: avatarRef)
                    } else {
                        Color.clear.frame(width: compact ? 26 : face, height: 1)
                    }
                }
                VStack(alignment: .leading, spacing: 4) {
                    if entry.showHeader && (showFace || entry.to != nil) { header }
                    else if entry.isNotice {
                        Chip(text: noticeKind.flatMap(WorkNotice.label) ?? "알림")
                    }
                    if let title = entry.threadTitle, !entry.replies.isEmpty || entry.thread != nil {
                        Label(ChatText.preview(title, limit: 60), systemImage: "text.bubble")
                            .font(.footnote.weight(.semibold)).foregroundStyle(.secondary)
                    }
                    bubble
                    if let counts = model.timeline.reactions[entry.seq], !counts.isEmpty {
                        HStack(spacing: 4) {
                            ForEach(counts.sorted { $0.value > $1.value }, id: \.key) { emoji, n in
                                Text(n > 1 ? "\(emoji) \(n)" : emoji).font(.caption)
                                    .padding(.horizontal, 7).padding(.vertical, 3)
                                    .background(Theme.cardBackground, in: Capsule())
                            }
                        }
                        .accessibilityElement(children: .combine)
                        .accessibilityLabel("반응 " + counts.map { "\($0.key) \($0.value)개" }.joined(separator: ", "))
                    }
                    media
                    if model.capabilities.has("browser-live"), offersBrowser {
                        // §22: the errand stopped at a page the owner finishes in the app.
                        Button { model.open(URL(string: "axkit://open/more?v=browser-live")!) } label: {
                            Label("브라우저 화면 열기", systemImage: "safari")
                        }
                        .buttonStyle(.action(.primary))
                    }
                    if model.capabilities.hasView("work"), WorkNotice.label(noticeKind) != nil || startsJob {
                        // §28: a long job's result — the list of what is running and what finished.
                        Label("하고 있는 일 보기", systemImage: "hourglass")
                            .font(.footnote.weight(.semibold)).foregroundStyle(.tint)
                            .safeTap { model.open(URL(string: "axkit://open/more?v=work")!) }
                            .accessibilityAddTraits(.isButton)
                    }
                    if !entry.replies.isEmpty { replies }
                    if entry.source.reactable, model.canReact, showChoices || model.reactions[entry.seq] != nil {
                        ReactionButtons(seq: entry.seq)
                    }
                }
                .contextMenu {
                    if entry.source.reactable, model.canReact {
                        Button { model.react(entry.seq, "👍") } label: { Label("좋아요 · 이런 거 더", systemImage: "hand.thumbsup") }
                        Button { model.react(entry.seq, "👎") } label: { Label("별로예요 · 이런 거 덜", systemImage: "hand.thumbsdown") }
                    }
                    Button { UIPasteboard.general.string = entry.text } label: { Label("복사", systemImage: "doc.on.doc") }
                }
                Spacer(minLength: 28)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, entry.showHeader ? 6 : 0)
            .accessibilityElement(children: .contain)
        }
    }

    private var startsJob: Bool {
        if case .message(let m) = entry.source, m.role == .assistant { return WorkNotice.startsJob(m.text) }
        return false
    }

    private var noticeKind: String? {
        if case .notice(let n) = entry.source { return n.kind }
        return nil
    }

    private var offersBrowser: Bool {
        switch entry.source {
        case .message(let m): BrowserLiveHint.offers(m)
        case .notice(let n): BrowserLiveHint.offers(n)
        default: false
        }
    }

    private var avatarRef: String? {
        entry.speaker.avatar ?? model.bots?.allBots.first { $0.name == entry.speaker.name }?.avatar
    }

    private var header: some View {
        HStack(spacing: 5) {
            Text(entry.speaker.name).font(.subheadline.weight(.semibold)).foregroundStyle(.primary)
            if let to = entry.to {
                Image(systemName: "arrow.right").font(.caption2.weight(.semibold)).foregroundStyle(.tertiary)
                Text(to).font(.subheadline).foregroundStyle(.secondary)
            }
            if let label = entry.label { Chip(text: label) }
            Text(Format.clock(entry.at)).font(.caption2).foregroundStyle(.tertiary)
        }
        .lineLimit(1)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(entry.to.map { "\(Format.subject(entry.speaker.name)) \($0)에게" } ?? entry.speaker.name)
    }

    @ViewBuilder private var bubble: some View {
        if noticeKind == WorkNotice.overnight {
            // "밤사이 소식 N건": one bubble, one row per piece of news.
            let digest = WorkNotice.digest(entry.text)
            VStack(alignment: .leading, spacing: 8) {
                Text(digest.title).font(.subheadline.weight(.semibold))
                ForEach(Array(digest.lines.enumerated()), id: \.offset) { _, line in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("•").font(.subheadline).foregroundStyle(.secondary)
                        MarkdownText(line).font(.subheadline).fixedSize(horizontal: false, vertical: true)
                    }
                }
                buttonsInside
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
            .background(Theme.assistantBubble, in: RoundedRectangle(cornerRadius: Theme.corner, style: .continuous))
        } else if !entry.text.isEmpty || !(choices ?? []).isEmpty {
            // A line that asks something: one bubble, its buttons inside (§ chat like a chat).
            VStack(alignment: .leading, spacing: 10) {
                if !entry.text.isEmpty {
                    HStack(alignment: .lastTextBaseline, spacing: 6) {
                        ExpandableText(text: entry.text, limit: entry.isStatus ? 4 : 10, font: entry.isStatus ? .subheadline : .body)
                            .foregroundStyle(entry.isStatus ? .secondary : .primary)
                        if entry.repeats > 1 { Text("×\(entry.repeats)").font(.caption.weight(.semibold)).foregroundStyle(.secondary) }
                    }
                }
                buttonsInside
            }
            .padding(.horizontal, 14)
            .padding(.vertical, entry.isStatus ? 8 : 10)
            .background(entry.isStatus ? Theme.statusBubble : Theme.assistantBubble,
                        in: RoundedRectangle(cornerRadius: Theme.corner, style: .continuous))
        }
    }

    @ViewBuilder private var media: some View {
        switch entry.source {
        case .message(let m):
            AttachedImages(attachments: m.attachments, imageUrl: m.imageUrl, height: 180)
            AttachedFiles(attachments: m.attachments)
            LinkList(links: m.links)
        case .notice(let n):
            AttachedImages(attachments: n.attachments, imageUrl: n.imageUrl, height: 160)
            AttachedFiles(attachments: n.attachments)
            LinkList(links: n.links)
        default: EmptyView()
        }
    }

    /// Every line keeps its buttons: the room's open question can be tapped; answered or older ones are dimmed.
    @ViewBuilder private var buttonsInside: some View {
        if let choices, !choices.isEmpty {
            ChoiceButtons(choices: choices, seq: entry.seq, room: room,
                          state: ChatChoices.state(seq: entry.seq, live: asking ? entry.seq : nil, picked: model.chosen[entry.seq]))
        }
    }

    private var choices: [Choice]? {
        switch entry.source {
        case .message(let m): m.choices
        case .notice(let n): n.choices
        default: nil
        }
    }

    /// "답글 1개 · Mia: 방향은 승인해요…" — tap to read the whole answer under the question.
    @ViewBuilder private var replies: some View {
        VStack(alignment: .leading, spacing: 6) {
            if repliesOpen {
                ForEach(entry.replies) { reply in
                    HStack(alignment: .top, spacing: 6) {
                        Rectangle().fill(Color(.separator)).frame(width: 2).padding(.vertical, 2)
                        FeedEntry(entry: reply, room: room, showFace: true, showChoices: false, compact: true)
                    }
                }
            }
            Button {
                withAnimation(.snappy) { repliesOpen.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: repliesOpen ? "chevron.up" : "arrowshape.turn.up.left").font(.caption.weight(.semibold))
                    if repliesOpen {
                        Text("답글 접기")
                    } else {
                        Text("답글 \(entry.replies.count)개").fontWeight(.semibold)
                        if let last = entry.replies.last {
                            Text("\(last.speaker.name): \(ChatText.preview(last.text, limit: 40))").foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                }
                .font(.footnote)
                .foregroundStyle(.tint)
                .padding(.vertical, 4)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint(repliesOpen ? "답글을 접어요" : "답글을 펼쳐요")
        }
    }
}

/// Many lines folded into one: "Leo·Mia·Victor의 대화 6개 ›". Opens in place.
struct FoldedRun: View {
    var fold: RoomFeed.Folded
    var room: String
    var isOpen: Bool
    var toggle: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button(action: toggle) {
                HStack(spacing: 8) {
                    AvatarStack(names: Array(fold.names.prefix(3)), size: 22)
                    Text(fold.title).font(.footnote.weight(.semibold)).foregroundStyle(.primary).lineLimit(1)
                    Spacer(minLength: 0)
                    Text(isOpen ? "접기" : "펼치기").font(.footnote).foregroundStyle(.tint)
                    Image(systemName: isOpen ? "chevron.up" : "chevron.down").font(.caption.weight(.semibold)).foregroundStyle(.tint)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(Theme.cardBackground, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint(isOpen ? "접어요" : "펼쳐서 다 봐요")
            if isOpen {
                ForEach(fold.entries) { entry in
                    FeedEntry(entry: entry, room: room, showFace: true, showChoices: false)
                }
            }
        }
        .padding(.vertical, 2)
    }
}

/// https links under a message (never opened by themselves).
struct LinkList: View {
    var links: [EventLink]?
    var body: some View {
        if let links, !links.isEmpty {
            ForEach(links, id: \.url) { link in
                if let url = URL(string: link.url), url.scheme == "https" {
                    Link(destination: url) { Label(ChatText.preview(link.label, limit: 40), systemImage: "link") }.font(.subheadline)
                }
            }
        }
    }
}

/// Two quiet buttons under a bot's message: more like this / less like this.
struct ReactionButtons: View {
    var seq: Int
    @Environment(AppModel.self) private var model
    var body: some View {
        let picked = model.reactions[seq]
        HStack(spacing: 6) {
            button("👍", "hand.thumbsup", "좋아요", picked)
            button("👎", "hand.thumbsdown", "별로예요", picked)
        }
    }
    private func button(_ emoji: String, _ icon: String, _ label: String, _ picked: String?) -> some View {
        let on = picked == emoji
        return Image(systemName: on ? icon + ".fill" : icon)
            .font(.footnote)
            .foregroundStyle(on ? Color.accentColor : .secondary)
            .frame(width: 34, height: 28)
            .background(on ? ActionKind.secondary.background : Theme.cardBackground, in: Capsule())
            .safeTap { if !on { model.react(seq, emoji) } }
            .accessibilityLabel(label)
            .accessibilityAddTraits(on ? .isSelected : [])
    }
}

struct ChoiceButtons: View {
    var choices: [Choice]
    /// The line the buttons belong to.
    var seq: Int
    var room: String
    var state: ChatChoices.State = .live
    @Environment(AppModel.self) private var model
    var body: some View {
        // Wraps onto more lines as needed (a row of numbered buttons never overflows its bubble).
        FlowLayout(spacing: 8) { buttons }
    }
    @ViewBuilder private var buttons: some View {
        // Once one is tapped they all turn off (no second tap sends it twice) and the pick stays marked; a line the
        // talk moved past keeps its buttons, dimmed.
        let picked: String? = if case .done(let p) = state { p } else { nil }
        let live = state == .live
        ForEach(choices) { choice in
            let on = picked == choice.id
            HStack(spacing: 4) {
                if on { Image(systemName: "checkmark").font(.caption.weight(.bold)) }
                Text(choice.label)
            }
            .font(.subheadline.weight(.medium))
            .foregroundStyle(on ? AnyShapeStyle(.white) : live ? AnyShapeStyle(.tint) : AnyShapeStyle(.tertiary))
            .padding(.horizontal, 14).padding(.vertical, 8)
            .background(on ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(ActionKind.secondary.background), in: Capsule())
            .opacity(live || on ? 1 : 0.6)
            .safeTap { if live { model.choose(choice, of: seq, in: room) } }
            .accessibilityAddTraits(on ? [.isButton, .isSelected] : .isButton)
            .accessibilityHint(live ? "" : "지난 질문이에요")
        }
    }
}

struct NoticeRow: View {
    var notice: NoticeEvent
    var room: String
    var showChoices: Bool
    @Environment(AppModel.self) private var model
    var body: some View {
        VStack(spacing: 8) {
            ExpandableText(text: ChatText.clean(notice.text), limit: 6, font: .footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            if let choices = notice.choices, !choices.isEmpty {
                ChoiceButtons(choices: choices, seq: notice.seq, room: room,
                              state: ChatChoices.state(seq: notice.seq, live: showChoices ? notice.seq : nil, picked: model.chosen[notice.seq]))
            }
        }
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity)
    }
}

/// One quiet line: "개발 봇에게 맡겼어요 · 로그인 고치기 ›" — tap to open that bot's room.
struct DelegationRow: View {
    var event: DelegationEvent
    @Environment(AppModel.self) private var model

    private var headline: String {
        switch event.state {
        case .started: "\(event.bot.name)에게 맡겼어요"
        case .done: "\(Format.subject(event.bot.name)) 끝냈어요"
        case .failed: "\(Format.subject(event.bot.name)) 막혔어요"
        }
    }

    var body: some View {
        ChatLineCard(title: headline, text: ChatText.clean(event.summary ?? event.task),
                     titleColor: event.state == .failed ? .red : .primary)
        .safeTap { model.showRoom(event.botChannel) }
        .accessibilityHint("\(event.bot.name) 방을 열어요")
    }
}

/// A 결재 in the chat reads like the assistant asking: a bubble with a 결재 요청 chip, the context and question, and its
/// buttons inside. Answering here shows the pick as the owner's line; the buttons stay, dimmed. Cards with a menu or an
/// input window are answered in the 결재 tab (the bubble says so).
struct CardLine: View {
    var card: CardEvent
    @Environment(AppModel.self) private var model
    @State private var busy: String?

    private var options: [CardOption] { card.options?.isEmpty == false ? card.options! : CardWords.defaultOptions(for: card) }
    /// Buttons that answer in one tap; menus and input windows need the 결재 tab.
    private var answersHere: Bool { card.form == nil && (card.selects ?? []).isEmpty }

    var body: some View {
        let open = model.timeline.isOpen(card.cardId)
        let closure = model.timeline.closure(of: card.cardId)
        let picked = ChatChoices.answeredOption(card, closure)
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Chip(text: open ? "결재 요청" : "결재 끝")
                    if !open, ChatChoices.cardEcho(card, closure) == nil {
                        Text(CardWords.closedLabel(closure, expired: closure == nil)).font(.caption).foregroundStyle(.secondary)
                    }
                }
                VStack(alignment: .leading, spacing: 10) {
                    MarkdownText(CardWords.chatLine(card))
                        .font(.body)
                        .fixedSize(horizontal: false, vertical: true)
                    AttachedImages(attachments: card.attachments, imageUrl: card.imageUrl, height: 160)
                    if answersHere {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(options) { option in button(option, open: open, picked: picked) }
                        }
                    }
                    if open {
                        Label(answersHere ? "결재 탭에서 직접 쓰기·자세히" : "결재 탭에서 답하기", systemImage: "checkmark.seal")
                            .font(.footnote.weight(.semibold)).foregroundStyle(.tint)
                            .safeTap { model.tab = .approvals }
                            .accessibilityAddTraits(.isButton)
                    }
                }
                .padding(.horizontal, 14).padding(.vertical, 10)
                .background(Theme.assistantBubble, in: RoundedRectangle(cornerRadius: Theme.corner, style: .continuous))
                .opacity(open ? 1 : 0.8)
            }
            .padding(.trailing, 28)
            if let echo = ChatChoices.cardEcho(card, closure) {
                OwnerBubble(text: echo, footnote: nil)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func button(_ option: CardOption, open: Bool, picked: String?) -> some View {
        let on = picked == option.id
        let kind: ActionKind = switch option.tone { case .primary: .primary; case .danger: .danger; default: .secondary }
        return HStack(spacing: 6) {
            if on { Image(systemName: "checkmark").font(.caption.weight(.bold)) }
            Text(option.label).font(.subheadline.weight(.semibold)).multilineTextAlignment(.leading)
            Spacer(minLength: 0)
            if busy == option.id { ProgressView().tint(kind.foreground) }
        }
        .foregroundStyle(open ? kind.foreground : on ? Color.primary : Color.secondary)
        .padding(.horizontal, 14).padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(open ? kind.background : on ? ActionKind.secondary.background : Theme.cardBackground,
                    in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .opacity(open || on ? 1 : 0.55)
        .safeTap { if open { choose(option) } }
        .accessibilityLabel(option.label)
        .accessibilityHint(open ? option.detail ?? "" : "끝난 결재예요")
        .accessibilityAddTraits(on ? [.isButton, .isSelected] : .isButton)
    }

    private func choose(_ option: CardOption) {
        guard busy == nil else { return }
        if card.isTeamPlan, CardEvent.teamPlanFixInApp.contains(option.id), model.capabilities.has("team-plan") {
            model.tab = .more
            model.moreRoute = "team-plan"
            return
        }
        busy = option.id
        Task {
            await model.answer(card, CardWords.answer(for: option))
            busy = nil
        }
    }
}

/// Small white card in the chat for things that aren't messages (맡김, 결재 요청). Tap opens where it points.
struct ChatLineCard: View {
    var title: String
    var text: String
    var titleColor: Color = .primary
    var showsChevron = true
    /// nil = the whole text (a 결재's context is never cut).
    var lineLimit: Int? = 3
    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.footnote.weight(.semibold)).foregroundStyle(titleColor)
                Text(text).font(.subheadline).foregroundStyle(.primary).multilineTextAlignment(.leading).lineLimit(lineLimit)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            if showsChevron { Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary) }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(Theme.cardBackground, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}

/// §4 `activity`: "생각하는 중…" (or the step, "메일 보는 중…") under the chat while the assistant works on it.
struct BusyRow: View {
    var busy: ActivityBoard.Busy
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 8) {
            Text(busy.words).font(.subheadline).foregroundStyle(.secondary)
            if reduceMotion {
                Text("…").font(.subheadline).foregroundStyle(.secondary)
            } else {
                TimelineView(.periodic(from: .now, by: 0.35)) { context in
                    let tick = Int(context.date.timeIntervalSinceReferenceDate / 0.35) % 3
                    HStack(spacing: 4) {
                        ForEach(0..<3, id: \.self) { i in
                            Circle().fill(Color.secondary).frame(width: 6, height: 6).opacity(i == tick ? 1 : 0.3)
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(Theme.cardBackground, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(busy.words + "이에요")
    }
}

/// While talking: a red dot, the time, bars that move with the voice (so a dead mic shows), and a way to throw it away.
struct DictationStrip: View {
    var dictation: Dictation

    var body: some View {
        HStack(spacing: 10) {
            Circle().fill(.red).frame(width: 8, height: 8)
            Text(DictationRules.clock(dictation.elapsed))
                .font(.subheadline.monospacedDigit())
            LevelBars(level: dictation.level)
                .frame(height: 22)
                .accessibilityHidden(true)
            Spacer(minLength: 0)
            Button("취소") { dictation.cancel() }
                .font(.subheadline)
                .accessibilityLabel("말한 것 버리기")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(Theme.cardBackground, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(Color.red.opacity(0.6), lineWidth: 1.5))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("듣고 있어요, \(DictationRules.clock(dictation.elapsed))")
    }
}

private struct LevelBars: View {
    var level: Double
    private let shape: [Double] = [0.45, 0.75, 1, 0.8, 0.55, 0.9, 0.6]

    var body: some View {
        HStack(alignment: .center, spacing: 3) {
            ForEach(shape.indices, id: \.self) { i in
                Capsule()
                    .fill(level > 0.05 ? Color.red.opacity(0.8) : Color.secondary.opacity(0.4))
                    .frame(width: 3, height: max(3, 22 * min(1, level * 1.4) * shape[i]))
            }
        }
        .animation(.easeOut(duration: 0.08), value: level)
    }
}

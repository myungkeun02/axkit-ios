import AxKitCore
import Foundation
import Network
import Observation
import SwiftUI
import UserNotifications

extension APIError: APIErrorFriendly {}

enum Tab: Hashable { case home, approvals, docs, calendar, more }

enum Connection: Equatable {
    case unpaired
    case connecting
    case live
    case offline(String)
    case unauthorized

    var label: String {
        switch self {
        case .unpaired: "연결 안 됨"
        case .connecting: "연결하는 중"
        case .live: "연결됨"
        case .offline: "맥에 닿지 않아요"
        case .unauthorized: "다시 연결이 필요해요"
        }
    }

    var color: Color {
        switch self {
        case .live: .green
        case .connecting: .orange
        default: .red
        }
    }
}

/// Everything the screens share: pairing, the live event stream, the timeline and the outbox.
@MainActor @Observable
final class AppModel {
    private(set) var credentials: ServerCredentials?
    private(set) var client: APIClient?
    private(set) var capabilities = Capabilities()
    private(set) var assistantName = "비서"
    private(set) var connection: Connection = .unpaired
    private(set) var stopped = false
    var timeline = Timeline()
    private(set) var pending: [PendingMessage] = []
    private(set) var bots: BotsView?
    /// §7.2 (ax-hq): rooms such as 결재·브리핑·장애·로그 — some read-only.
    private(set) var channels: ChannelsView?
    var toast: String?
    var tab: Tab = .home
    /// A room the home tab should open (from a delegation line or a card).
    var openRoom: String?

    private let store: CredentialStore
    private let outbox: Outbox
    private let timelines: TimelineStore
    let recorder = Recorder()
    /// Sends the phone's place when the Mac lists the `location` feature.
    let location = LocationReporter()
    let signals = SignalsReporter()
    /// A double tap on 보내기 sends once.
    private var repeatGuard = RepeatGuard()
    let recordings: RecordingQueue
    private(set) var pendingRecordings: [PendingRecording] = []
    private var uploadingRecordings = false
    private var stream: EventStreamClient?
    private var running = false

    static let mockLink = "axkit://pair?u=http%3A%2F%2F127.0.0.1%3A47790&n=dev&c=123456"

    /// One model for the app and the notification delegate: a lock-screen 승인 can arrive (cold launch, in the
    /// background) before any screen exists, and must still be sent.
    static let shared = AppModel()

    weak var push: PushDelegate? {
        didSet { if push != nil, capabilities.has("push") { Task { await push?.enable(for: self) } } }
    }

    init(store: CredentialStore = SharedPlace.credentialStore()) {
        self.store = store
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        outbox = Outbox(fileURL: dir.appendingPathComponent("outbox.json"))
        recordings = RecordingQueue(folder: dir.appendingPathComponent("recordings", isDirectory: true))
        if ProcessInfo.processInfo.arguments.contains("-resetPairing") { store.clear() }
        timelines = TimelineStore(dir: dir)
        if let saved = store.load() { adopt(saved); restoreTimeline() }
        // Relaunched in the background for a move: keep listening and send it (capabilities load later).
        if LocationReporter.macWantsIt { location.update(client: client, wanted: true, active: false) }
    }

    var isPaired: Bool { credentials != nil }
    var openCardCount: Int { timeline.openCards().count }

    private func adopt(_ credentials: ServerCredentials) {
        self.credentials = credentials
        client = APIClient(credentials: credentials)
        connection = .connecting
    }

    // MARK: lifecycle

    func start() {
        guard let client, !running else { return }
        running = true
        location.appOpened()
        Task { await signals.check() }
        watchNetwork()
        Task {
            pending = await outbox.pending
            pendingRecordings = await recordings.pending
            waitingFiles = SharedPlace.queued().compactMap { $0.0.fileName }
            await refreshBasics()
            // Catch up page by page first, then stream from where that ended — not both at once from 0.
            await catchUp()
            // The widget and the app badge count open cards: only once the timeline is up to date.
            await refreshWidget()
            guard running, self.client === client else { return }
            startStream()
            await flushOutbox()
            await uploadRecordings()
        }
    }

    /// (Re)opens the live stream from where the timeline ends.
    private func startStream() {
        guard running, let client else { return }
        stream?.stop()
        let stream = EventStreamClient(client: client)
        self.stream = stream
        stream.start(
            lastSeq: { [weak self] in await self?.cursor() ?? 0 },
            onState: { [weak self] state in await self?.streamState(state) },
            onEvent: { [weak self] event in await self?.receive(event) },
            onActivity: { [weak self] activity in await self?.receive(activity) }
        )
    }

    /// Wi-Fi ↔ cellular, Tailscale up: a stream waiting out a long backoff reconnects now.
    private var pathMonitor: NWPathMonitor?
    private var lastPath: String?

    private func watchNetwork() {
        guard pathMonitor == nil else { return }
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            // Only what matters for reaching the Mac: up or down, and Wi-Fi / cellular / wired / other.
            let kind: String = path.usesInterfaceType(.wifi) ? "wifi" : path.usesInterfaceType(.cellular) ? "cell"
                : path.usesInterfaceType(.wiredEthernet) ? "wired" : "other"
            let key = "\(path.status)|\(kind)"
            let usable = path.status == .satisfied
            Task { @MainActor in self?.networkChanged(key, usable: usable) }
        }
        monitor.start(queue: .global(qos: .utility))
        pathMonitor = monitor
    }

    private func networkChanged(_ key: String, usable: Bool) {
        defer { lastPath = key }
        guard let lastPath, lastPath != key, usable, running else { return }
        // A live stream is fine; only one sitting out a backoff is restarted.
        guard case .offline = connection else { return }
        startStream()
        Task { await flushOutbox() }
    }

    private func cursor() -> Int { timeline.lastSeq }

    func stop() {
        running = false
        location.appClosed()
        activity.clear()
        stream?.stop()
        stream = nil
        pathMonitor?.cancel()
        pathMonitor = nil
        lastPath = nil
        retryTask?.cancel()
        retryTask = nil
        flushIncoming()
        // Going to the background: finish the save, and try once more to send what is waiting.
        let task = UIApplication.shared.beginBackgroundTask(withName: "save-and-send")
        Task {
            await saveTimelineNow()
            if !pending.filter({ !$0.showsFailed }).isEmpty { await flushOutbox() }
            UIApplication.shared.endBackgroundTask(task)
        }
    }

    // MARK: history kept on the phone

    /// Which Mac this history belongs to: its own id once `status` gave one, else its address. Kept per pairing
    /// so the file is found at launch before the Mac answers.
    private var timelineKey: String? {
        guard let credentials else { return nil }
        if let saved = UserDefaults.standard.string(forKey: "timelineKey." + credentials.deviceId) { return saved }
        return TimelineStore.key(credentials.baseURL.host ?? credentials.baseURL.absoluteString)
    }

    private func adoptServerId(_ id: String?) {
        guard let id, !id.isEmpty, let credentials else { return }
        let key = TimelineStore.key("id:" + id)
        guard key != timelineKey else { return }
        UserDefaults.standard.set(key, forKey: "timelineKey." + credentials.deviceId)
        timelineSave.request { [weak self] in await self?.saveTimelineNow() }
    }

    private func restoreTimeline() {
        guard let key = timelineKey, let data = try? Data(contentsOf: timelines.url(key)),
              let snapshot = try? JSONDecoder().decode(Timeline.Snapshot.self, from: data) else { return }
        timeline = Timeline(snapshot)
    }

    private let timelineSave = Throttle(seconds: 10)

    /// The snapshot and the file it belongs to are taken now; encoding and writing happen in the store, one at a time.
    private func saveTimelineNow() async {
        guard let key = timelineKey else { return }
        let snapshot = timeline.snapshot()
        let store = timelines
        let generation = await store.current()
        await store.save(snapshot, key: key, generation: generation)
    }

    /// The Mac's oldest seq still in its log (0 = all of it). Older lines are only on this phone, if anywhere.
    private(set) var oldestSeq = 0

    /// After the Mac built teams (team plan or first look applied): show the new rooms and bots.
    func refreshBots() async {
        guard let client else { return }
        if capabilities.hasView("bots"), let fresh = try? await client.view(BotsView.self, "bots") { bots = fresh }
        if capabilities.has("channels"), capabilities.hasView("channels"), let fresh = try? await client.view(ChannelsView.self, "channels") { channels = fresh }
    }

    private var basicsAt: Date?

    func refreshBasics() async {
        guard let client else { return }
        basicsAt = Date()
        do {
            capabilities = try await client.capabilities()
            location.update(client: client, wanted: capabilities.has("location"), active: UIApplication.shared.applicationState == .active)
            let status = try await client.status()
            // A server whose log started over (new install, wiped data): start the timeline over too.
            if status.lastSeq < timeline.lastSeq {
                let read = timeline.readUpTo
                timeline = Timeline()
                if status.lastSeq > 0 { timeline.restoreRead(read.filter { $0.value <= status.lastSeq }) }
            }
            adoptServerId(status.serverId)
            assistantName = status.assistant.name
            stopped = status.stopped ?? false
            if capabilities.hasView("bots") { bots = try? await client.view(BotsView.self, "bots") }
            if capabilities.has("channels"), capabilities.hasView("channels") { channels = try? await client.view(ChannelsView.self, "channels") }
            // Asking for notification permission waits for the owner to answer: never hold up catch-up and the stream on it.
            if capabilities.has("push"), let push { Task { await push.enable(for: self) } }
            Task { await sendSharedWhileOffline() }
        } catch let error as APIError {
            handle(error)
        } catch {}
    }

    private func catchUp() async {
        guard let client else { return }
        for _ in 0..<10 {
            guard let page = try? await client.events(after: timeline.lastSeq) else { break }
            oldestSeq = page.oldestSeq
            absorb(page.events.sorted { $0.seq < $1.seq })
            if page.events.count < 200 { break }
        }
        // Anything acknowledged with an older seq (a `duplicate:true` retry) has arrived by now.
        pruneSent(caughtUp: true)
    }

    /// The "맥에 닿지 않아요" banner: only after two failed tries or a few seconds without the Mac, then it stays
    /// through the retries (connecting → waiting → connecting) instead of blinking with each one.
    private(set) var showsConnectionTrouble = false
    private var failedTries = 0
    private var troubleTimer: Task<Void, Never>?

    private func noteTrouble() {
        // One failed request while the stream is live says nothing about the connection.
        guard connection != .live else { return }
        failedTries += 1
        if failedTries >= 2 { showsConnectionTrouble = true; return }
        guard troubleTimer == nil else { return }
        troubleTimer = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            guard !Task.isCancelled, let self, self.connection != .live else { return }
            self.showsConnectionTrouble = true
        }
    }

    private func noteConnected() {
        failedTries = 0
        troubleTimer?.cancel()
        troubleTimer = nil
        showsConnectionTrouble = false
    }

    private func streamState(_ state: StreamState) async {
        switch state {
        case .connecting: if connection != .live { connection = .connecting }
        case .live:
            connection = .live
            noteConnected()
            // A new connection sends each busy room once more; what was shown before may have finished meanwhile.
            activity.clear()
            // The rest runs on its own: the stream goes on reading events meanwhile.
            // Launched offline: capabilities were never read (cards fell back to "[결재 답: …]"). Read them now,
            // at most every 30 seconds however often the connection flaps.
            let stale = capabilities.features.isEmpty || basicsAt.map({ Date().timeIntervalSince($0) > 30 }) ?? true
            Task {
                if stale { await refreshBasics() } else { await sendSharedWhileOffline() }
                await flushOutbox()
                await uploadRecordings()
            }
        case .waiting:
            connection = .offline("다시 연결할게요")
            // Cut off from the Mac: "생각하는 중…" can't be known any more (a reconnect sends it again).
            activity.clear()
            noteTrouble()
        case .unauthorized:
            connection = .unauthorized
            showsConnectionTrouble = true
        }
    }

    /// Events from the stream wait here a moment and go into the timeline together, so a burst (a reconnect replaying
    /// hundreds) redraws the screens a few times instead of once per event. The stream never waits on the network.
    private var incoming: [AppEvent] = []
    private var incomingFlush: Task<Void, Never>?

    /// §4 `activity`: rooms where the assistant is thinking or working right now ("생각하는 중…" under the chat).
    private(set) var activity = ActivityBoard()
    private var activitySweep: Task<Void, Never>?

    private func receive(_ event: ActivityEvent) {
        guard capabilities.has("activity") else { return }
        activity.apply(event)
        // Nothing heard for 3 minutes: the server has forgotten it, so the app lets it go too.
        activitySweep?.cancel()
        guard !activity.rooms.isEmpty else { return }
        activitySweep = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(ActivityBoard.forgetAfter + 1) * 1_000_000_000)
            guard !Task.isCancelled, let self else { return }
            self.activity.forgetStale()
        }
    }

    private func receive(_ event: AppEvent) {
        incoming.append(event)
        guard incomingFlush == nil else { return }
        incomingFlush = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 100_000_000)
            self?.flushIncoming()
        }
    }

    private func flushIncoming() {
        incomingFlush?.cancel()
        incomingFlush = nil
        guard !incoming.isEmpty else { return }
        let batch = incoming
        incoming = []
        absorb(batch)
    }

    /// Every event goes in here, from the stream and from catch-up alike, so both do the same follow-up.
    /// Bumped when a long job's result arrives (§28): the 하고 있는 일 screen reads again.
    private(set) var workTick = 0

    /// §28/§31 what the assistant is doing in the background (for the strip above the chat box and its sheet).
    private(set) var work: WorkView?

    /// Reads `views/work` again; keeps the last good answer when the Mac can't be reached.
    @discardableResult
    func loadWork() async -> WorkView? {
        guard capabilities.hasView("work"), let client else { work = nil; return nil }
        if let fresh = try? await client.work() { work = fresh }
        return work
    }

    private func absorb(_ batch: [AppEvent]) {
        guard !batch.isEmpty else { return }
        var changedCards = false, delegated = false, work = false
        var copy = timeline
        for event in batch where copy.apply(event) {
            if case .message(let m) = event, m.role == .assistant, activity[event.channel] != nil { activity.answered(in: event.channel, at: m.at) }
            switch event {
            case .card, .cardClosed: changedCards = true
            case .delegation: delegated = true; work = true
            // §31: any notice may mean a job started, moved or finished (bot hand-offs, team work, results).
            case .notice: work = true
            case .message(let m): if m.role == .assistant, WorkNotice.startsJob(m.text) { work = true }
            default: break
            }
        }
        timeline = copy
        pruneSent()
        if work { workTick += 1 }
        timelineSave.request { [weak self] in await self?.saveTimelineNow() }
        if changedCards { widgetRefresh.request { [weak self] in await self?.refreshWidget() } }
        if delegated, capabilities.hasView("bots") {
            botsRefresh.request { [weak self] in
                guard let self, let client = self.client else { return }
                if let fresh = try? await client.view(BotsView.self, "bots") { self.bots = fresh }
            }
        }
    }

    /// The widget and the bot list are fetched at most once every 2 seconds, however many events ask for it.
    private let widgetRefresh = Throttle(seconds: 2)
    private let botsRefresh = Throttle(seconds: 2)

    private func handle(_ error: APIError) {
        switch error {
        case .unauthorized: connection = .unauthorized; showsConnectionTrouble = true
        case .offline:
            // The stream is the judge of the connection; a live one stays live.
            if connection != .live { connection = .offline(error.friendlyMessage) }
            noteTrouble()
        default: break
        }
    }

    // MARK: pairing

    func pair(link raw: String) async throws {
        let link = try PairingLink.parse(raw)
        let credentials = try await APIClient.pair(link)
        // Same Mac = same install id (or, from a server without one, the same address).
        let newStatus = try? await APIClient(credentials: credentials).status()
        let oldKey = timelineKey
        let newKey = newStatus?.serverId.map { TimelineStore.key("id:" + $0) }
            ?? TimelineStore.key(credentials.baseURL.host ?? credentials.baseURL.absoluteString)
        let sameMac = oldKey == newKey
        try store.save(credentials)
        stop()
        await timelines.cancelPending()
        await forgetPairing(keepOutbox: sameMac)
        UserDefaults.standard.set(newKey, forKey: "timelineKey." + credentials.deviceId)
        adopt(credentials)
        restoreTimeline()
        start()
    }

    func unpair() async {
        try? await client?.unpair()
        stop()
        store.clear()
        if let credentials { UserDefaults.standard.removeObject(forKey: "timelineKey." + credentials.deviceId) }
        // Every Mac's history goes: nothing of a past pairing stays on the phone.
        await timelines.forget(key: nil)
        await forgetPairing(keepOutbox: false)
        drafts = [:]
        signals.reset()
        location.setOwnerSwitch(false)
        credentials = nil
        client = nil
        connection = .unpaired
    }

    /// Nothing from the previous pairing carries over: its rooms, bots, reactions, activity, pictures. Messages
    /// typed for the same Mac still go (its new token sends them); for another Mac they are dropped with it.
    private func forgetPairing(keepOutbox: Bool) async {
        if !keepOutbox {
            await outbox.clear()
            await recordings.clear()
        }
        pending = await outbox.pending
        pendingRecordings = await recordings.pending
        sent = [:]
        timeline = Timeline()
        oldestSeq = 0
        bots = nil
        channels = nil
        reactions = [:]
        tapped = [:]
        activity.clear()
        avatarCache = [:]
        capabilities = Capabilities()
        location.update(client: nil, wanted: false, active: false)
        basicsAt = nil
        retryBackoff.reset()
        noteConnected()
    }

    // MARK: chat

    func send(_ text: String, in room: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, repeatGuard.allow(trimmed, in: room) else { return }
        Task {
            await outbox.enqueue(text: String(trimmed.prefix(8000)), channel: room)
            pending = await outbox.pending
            await flushOutbox()
        }
    }

    /// 선택지 the owner tapped this session (message seq → choice id). Together with the outbox (which keeps
    /// `choiceSeq` on disk) it marks the picked button and keeps the others off.
    private var tapped: [Int: String] = [:]

    /// Line seq → the choice id picked there (tapped now, waiting in the outbox, or sent and on its way back).
    var chosen: [Int: String] {
        var all = tapped
        for m in pending { if let seq = m.choiceSeq, let id = m.choice { all[seq] = id } }
        for (_, s) in sent { if let seq = s.message.choiceSeq, let id = s.message.choice { all[seq] = id } }
        return all
    }

    /// Goes through the outbox like typed text (once, in order, kept while offline).
    func choose(_ choice: Choice, of seq: Int, in room: String) {
        guard chosen[seq] == nil else { return }
        tapped[seq] = choice.id
        Task {
            await outbox.enqueue(text: choice.label, channel: room, choice: choice.id, choiceSeq: seq)
            pending = await outbox.pending
            await flushOutbox()
        }
    }

    /// A choice sent late, after a newer question came: the Mac would match it to the newest one, so it goes as the
    /// button's words instead (what the owner meant, in plain text).
    private func sendsAsChoice(_ message: PendingMessage) -> Bool {
        guard message.choice != nil else { return false }
        guard let seq = message.choiceSeq else { return true }
        return timeline.openQuestion(in: message.channel) == seq
    }

    /// Sent and acknowledged (id → seq) but not on the timeline yet: still shown, so the bubble never blinks out.
    private var sent: [String: (message: PendingMessage, seq: Int)] = [:]

    /// `caughtUp`: right after catch-up — a seq at or below the newest one seen has arrived, even if it was an old
    /// line this phone never kept (a `duplicate:true` answer gives the first send's seq).
    private func pruneSent(caughtUp: Bool = false) {
        guard !sent.isEmpty else { return }
        let last = timeline.lastSeq
        sent = sent.filter { !timeline.has(seq: $0.value.seq) && !(caughtUp && $0.value.seq <= last) }
    }

    private func noteSent(_ message: PendingMessage, seq: Int) {
        if !timeline.has(seq: seq) { sent[message.id] = (message, seq) }
    }

    /// The message went to the Mac and is on its way back (shown as "보냄", no delete).
    func isSent(_ message: PendingMessage) -> Bool { sent[message.id] != nil }

    /// What was typed and not sent, per room (kept across launches).
    var drafts: [String: String] = (UserDefaults.standard.dictionary(forKey: "drafts") as? [String: String]) ?? [:] {
        didSet { UserDefaults.standard.set(drafts, forKey: "drafts") }
    }

    private var retryTask: Task<Void, Never>?
    private var retryBackoff = Backoff()

    func flushOutbox() async {
        guard let client else { return }
        let result = await outbox.flush { [weak self] message in
            let asChoice = await self?.sendsAsChoice(message) ?? false
            let answer = try await client.sendMessage(text: asChoice ? nil : message.text, choice: asChoice ? message.choice : nil,
                                                      channel: message.channel, clientId: message.id)
            await self?.noteSent(message, seq: answer.seq)
            await self?.refreshPending()
        }
        pending = await outbox.pending
        if result.unauthorized { connection = .unauthorized }
        if !result.sent.isEmpty {
            retryBackoff.reset()
            // It went through while the stream looked down: the stream is the stale one, so reopen it now.
            if connection != .live { startStream() }
            await catchUp()
        }
        scheduleRetry(result)
    }

    private func refreshPending() async { pending = await outbox.pending }

    /// Waiting messages are tried again by themselves, 2 s doubling to a minute, until they go or the owner deletes them.
    private func scheduleRetry(_ result: FlushResult) {
        retryTask?.cancel()
        retryTask = nil
        guard running, result.retrying > 0, !result.unauthorized else { return }
        let wait = retryBackoff.fail()
        retryTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await self?.flushOutbox()
        }
    }

    /// 다시 보내기 under a message that did not go.
    func resend(_ message: PendingMessage) {
        Task {
            await outbox.retry(message.id)
            pending = await outbox.pending
            retryBackoff.reset()
            await flushOutbox()
        }
    }

    /// 삭제 (long press) on a message that did not go.
    func discard(_ message: PendingMessage) {
        Task {
            await outbox.remove(message.id)
            pending = await outbox.pending
            if let seq = message.choiceSeq { tapped[seq] = nil }
        }
    }

    /// Waiting, failed, and sent-but-not-back-yet messages of a room, oldest first. Choices show as the button's label.
    func pendingMessages(in room: String) -> [PendingMessage] {
        let waiting = pending.filter { $0.channel == room && sent[$0.id] == nil }
        let arriving = sent.values.filter { $0.message.channel == room && !timeline.has(seq: $0.seq) }.map(\.message)
        return (arriving + waiting).sorted { $0.createdAt < $1.createdAt }
    }

    // MARK: recordings (R14)

    var recordingFeature: Bool { capabilities.has("recordings") || capabilities.hasView("recordings") }

    func startRecording() async {
        await recorder.start(into: recordings.folder)
        if let problem = recorder.problem { toast = problem; recorder.problem = nil }
    }

    func stopRecording() {
        guard let recording = recorder.stop() else {
            if let problem = recorder.problem { toast = problem; recorder.problem = nil }
            return
        }
        Task {
            await recordings.add(recording)
            pendingRecordings = await recordings.pending
            toast = "녹음을 맥으로 보낼게요. 정리되면 문서에 생겨요."
            await uploadRecordings()
        }
    }

    func uploadRecordings() async {
        guard let client, !uploadingRecordings else { return }
        uploadingRecordings = true
        defer { uploadingRecordings = false }
        let queue = recordings
        _ = await queue.upload { recording, index, data in
            let result = try await client.uploadRecordingChunk(recording, index: index, bytes: data)
            await MainActor.run { [weak self] in
                Task { self?.pendingRecordings = await queue.pending }
            }
            return result
        }
        pendingRecordings = await recordings.pending
    }

    // MARK: cards

    var cardReplyAllowed: Bool { capabilities.has("card-reply") }

    /// Returns the server's one-line reply, if any.
    @discardableResult
    func answer(_ card: CardEvent, _ answer: CardAnswer, remember: Bool = false) async -> Bool {
        guard let client else { return false }
        // A server without `card-reply` (today's ax-kit): answer "edit" (this action is declined, the assistant asks
        // what to change) and send the owner's words to the same room so nothing typed is lost.
        if case .text(let text) = answer, !cardReplyAllowed {
            do {
                let result = try await client.answerCard(card.cardId, .decision("edit"))
                timeline.closeLocally(card.cardId, state: result.state, answer: text)
                send("[결재 답: \(card.summary)] \(text)", in: card.channel ?? "")
                return true
            } catch {
                toast = error.friendly
                return false
            }
        }
        do {
            let result = try await client.answerCard(card.cardId, answer, remember: remember)
            if result.state == "open" {
                // The Mac may re-send this card with more to fill in (an input window); only say something if it did.
                if let reply = result.reply, !Self.echoes(reply, answer) { toast = reply }
                return false
            }
            var label: String? = result.answer
            if label == nil, case .text(let text) = answer { label = text }
            // The button tapped here, by name (an older Mac sends no `answer`; the chat shows it as the owner's line).
            if label == nil, case .option(let id) = answer { label = card.options?.first { $0.id == id }?.label }
            timeline.closeLocally(card.cardId, state: result.state, answer: label)
            if remember { toast = "앞으로 이런 일은 알아서 할게요" } else if let reply = result.reply, !Self.echoes(reply, answer) { toast = reply }
            return true
        } catch APIError.gone {
            timeline.closeLocally(card.cardId, state: "closed")
            toast = APIError.gone.friendlyMessage
            return false
        } catch {
            toast = error.friendly
            return false
        }
    }

    /// A reply that only repeats what the owner wrote ("답함: …") says nothing new: no toast.
    static func echoes(_ reply: String, _ answer: CardAnswer) -> Bool {
        guard case .text(let text) = answer else { return false }
        let r = reply.trimmingCharacters(in: .whitespacesAndNewlines), t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return r == t || r.hasSuffix(": " + t) || r.hasSuffix(" " + t) || r.contains("“\(t)”") || r.contains("\"\(t)\"")
    }

    // MARK: bot pictures

    /// Place of a name in the bot list (assistant first), so neighbouring bots get different colours and faces.
    func characterOrdinal(_ name: String) -> Int? {
        if name == assistantName { return 0 }
        guard let index = bots?.allBots.firstIndex(where: { $0.name == name }) else { return nil }
        return index + 1
    }

    private var avatarCache: [String: UIImage] = [:]

    /// https pictures load directly; `files/<id>` ones need the device token.
    func avatarImage(_ ref: String?) async -> UIImage? {
        guard let ref, !ref.isEmpty else { return nil }
        if let cached = avatarCache[ref] { return cached }
        var data: Data?
        if ref.hasPrefix("https://"), let url = URL(string: ref) {
            data = try? await URLSession.shared.data(from: url).0
        } else if ref.hasPrefix("files/") {
            data = try? await client?.file(ref)
        }
        guard let data else { return nil }
        // Decoded (and made ready to draw) off the main thread.
        let decoded = await Task.detached(priority: .utility) { UIImage(data: data)?.preparingForDisplay() ?? UIImage(data: data) }.value
        guard let image = decoded else { return nil }
        avatarCache[ref] = image
        return image
    }

    // MARK: notifications, share extension, widget

    /// A lock-screen 승인/거절. iOS gives a background answer about 30 seconds: each try gets 8, the whole thing 25.
    /// If it can't be sent, or the Mac wants more than a yes/no, a local notification says so.
    func answerFromNotification(cardId: String, _ answer: CardAnswer, title: String? = nil) async {
        guard let client else { return }
        let deadline = Date().addingTimeInterval(25)
        var problem = "알림에서 고른 답을 맥에 보내지 못했어요. 앱의 결재에서 다시 골라 주세요."
        while Date() < deadline {
            do {
                let result = try await Self.withTimeout(seconds: 8) { try await client.answerCard(cardId, answer) }
                if result.state == "open" {
                    // The Mac wants more (an input window): the card stays and it will be asked again in the app.
                    problem = result.reply.map { "\($0) 앱에서 이어서 답해 주세요." } ?? "맥이 더 물어볼 게 있어요. 앱의 결재에서 이어서 답해 주세요."
                    break
                }
                timeline.closeLocally(cardId, state: result.state)
                // The badge is the number of open cards: count them from an up-to-date timeline.
                if Date().addingTimeInterval(8) < deadline { _ = try? await Self.withTimeout(seconds: 8) { await self.catchUp() } }
                await refreshWidget()
                return
            } catch APIError.gone {
                timeline.closeLocally(cardId, state: "closed")
                await refreshWidget()
                return
            } catch let error as APIError where error.isTransient {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            } catch is TimedOut {
                continue
            } catch {
                break
            }
        }
        await Self.notifyLocally(title: title ?? "결재", body: problem, cardId: cardId)
    }

    struct TimedOut: Error {}

    /// Runs `work`, giving up after `seconds` (the work is cancelled).
    nonisolated static func withTimeout<T: Sendable>(seconds: Double, _ work: @escaping @Sendable () async throws -> T) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await work() }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                throw TimedOut()
            }
            defer { group.cancelAll() }
            guard let first = try await group.next() else { throw TimedOut() }
            return first
        }
    }

    static func notifyLocally(title: String, body: String, cardId: String) async {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        content.userInfo = ["cardId": cardId]
        content.categoryIdentifier = "AX_OPEN"
        let request = UNNotificationRequest(identifier: "answer-failed-" + cardId, content: content, trigger: nil)
        try? await UNUserNotificationCenter.current().add(request)
    }

    /// Things the share extension could not send (Mac out of reach) go now.
    private var sendingShared = false

    /// Files picked while the Mac was out of reach (shown as waiting bubbles in the main chat).
    private(set) var waitingFiles: [String] = []

    func sendSharedWhileOffline() async {
        guard let client, !sendingShared else { return }
        sendingShared = true
        defer {
            sendingShared = false
            waitingFiles = SharedPlace.queued().compactMap { $0.0.fileName }
        }
        for (item, bytes) in SharedPlace.queued() {
            do {
                if let bytes, let name = item.fileName {
                    _ = try await client.share(bytes, name: name, contentType: item.contentType ?? "application/octet-stream")
                } else if let text = item.text {
                    _ = try await client.sendMessage(text: text, clientId: item.id)
                }
                SharedPlace.remove(item)
            } catch let error as APIError where error.isTransient { return }
            catch { SharedPlace.remove(item) }
        }
    }

    /// Writes what the home-screen widget shows, then asks it to redraw.
    func refreshWidget() async {
        var events: [SharedPlace.Snapshot.Event] = []
        if let client, capabilities.hasView("today"), let today = try? await client.view(TodayView.self, "today") {
            events = (today.events ?? []).prefix(4).map { .init(title: $0.title, start: ISODates.parse($0.start), allDay: $0.allDay == true) }
        }
        let open = timeline.openCards()
        SharedPlace.save(.init(updatedAt: Date(), openCards: open.count, firstCard: open.first?.summary, events: events))
        WidgetBridge.reload()
        // The app icon's number = 결재 waiting.
        try? await UNUserNotificationCenter.current().setBadgeCount(open.count)
    }

    // MARK: rooms

    func roomTitle(_ room: String) -> String {
        if room.isEmpty { return assistantName }
        if let team = bots?.team(forChannel: room) { return team.name }
        if let group = bots?.group(forMeeting: room) { return "\(group.label) 팀장회의" }
        if let channel = channels?.channels.first(where: { $0.id == room }) { return channel.label }
        return bots?.bot(forChannel: room)?.name ?? room
    }

    func markRead(_ room: String) {
        let before = timeline.readUpTo[room] ?? 0
        timeline.markRead(room)
        let upTo = timeline.readUpTo[room] ?? 0
        if upTo > before { timelineSave.request { [weak self] in await self?.saveTimelineNow() } }
        // §21.4: tell the Mac so the other devices clear this room too.
        guard upTo > before, capabilities.has("read-sync"), let client else { return }
        Task { try? await client.markRead(channel: room, upTo: upTo) }
    }

    /// A picture or file from the chat box goes to the assistant (`POST share`, 12 MB at most).
    var canAttach: Bool { capabilities.has("share") }
    private(set) var sendingFiles = 0

    nonisolated static let fileLimit = 12 * 1024 * 1024
    nonisolated static let tooBigWords = "12MB보다 큰 파일은 맥에서 직접 넣어 주세요."

    /// The + in a room: the main chat always (with `share`), team and bot rooms only when the Mac knows `share-rooms`
    /// (an older Mac would drop the file in the main chat).
    func canAttach(in room: String) -> Bool {
        canAttach && (room.isEmpty || capabilities.has("share-rooms"))
    }

    /// 짧게 보기 in team and bot rooms (off by default: every line in order), remembered per room.
    var shortRooms: Set<String> = Set(UserDefaults.standard.stringArray(forKey: "shortRooms") ?? []) {
        didSet { UserDefaults.standard.set(Array(shortRooms), forKey: "shortRooms") }
    }

    func sendFile(_ bytes: Data, in room: String = "", name: String, contentType: String) {
        guard let client else { return }
        guard bytes.count <= Self.fileLimit else { toast = Self.tooBigWords; return }
        sendingFiles += 1
        Task {
            defer { sendingFiles -= 1 }
            do { _ = try await client.share(bytes, name: name, contentType: contentType, channel: room.isEmpty ? nil : room) }
            catch let error as APIError where !room.isEmpty {
                // A room's file isn't queued: the share queue only knows the main chat.
                toast = "\(name)을(를) 보내지 못했어요. \(error.friendly)"
            }
            catch let error as APIError where !error.isFinalRefusal && error != .unauthorized {
                // Mac out of reach: kept with what the share extension queues, sent when the connection is back.
                let item = SharedPlace.SharedItem(fileName: name, contentType: contentType)
                await Task.detached(priority: .utility) { SharedPlace.queue(item, bytes: bytes) }.value
                waitingFiles.append(name)
            }
            catch { toast = "\(name)을(를) 보내지 못했어요. \(error.friendly)" }
        }
    }

    /// 👍 / 👎 the owner gave a bot's message this session (seq → emoji). The Mac keeps the real record.
    private(set) var reactions: [Int: String] = [:]
    var canReact: Bool { capabilities.has("reactions") }

    func react(_ seq: Int, _ emoji: String) {
        guard let client else { return }
        let before = reactions[seq]
        reactions[seq] = emoji
        Task {
            do {
                try await client.react(seq: seq, emoji: emoji)
                toast = emoji == "👍" ? "좋았다고 전했어요. 이런 걸 더 할게요." : "별로였다고 전했어요. 이런 건 덜 할게요."
            } catch {
                reactions[seq] = before
                toast = error.friendly
            }
        }
    }

    struct RoomListItem: Identifiable {
        var id: String
        var title: String
        var subtitle: String?
        var faces: [String]
        var avatar: String?
        var status: String?
        var chips: [String] = []
        var last: (text: String, at: Date)?
        var unread: Int
    }

    struct RoomSection: Identifiable {
        var id: String
        var label: String
        var summary: String?
        var rooms: [RoomListItem]
    }

    /// The room list: per company its 팀장회의 and teams (or bots), newest first; then other rooms the owner can write in
    /// (개발 세션 …). Read-only notice rooms (결재·브리핑·장애·로그·알림) are not rooms to the owner and are left out.
    var roomSections: [RoomSection] {
        var sections: [RoomSection] = []
        var seen = Set<String>([""])
        func item(_ id: String, title: String, subtitle: String?, faces: [String], avatar: String? = nil, status: String? = nil, chips: [String] = []) -> RoomListItem {
            seen.insert(id)
            return RoomListItem(id: id, title: title, subtitle: subtitle.map { ChatText.preview($0, limit: 80) }, faces: faces, avatar: avatar, status: status,
                                chips: chips, last: roomPreview(id), unread: timeline.unreadCount(in: id))
        }
        func newestFirst(_ rooms: [RoomListItem]) -> [RoomListItem] {
            rooms.enumerated().sorted { a, b in
                switch (a.element.last?.at, b.element.last?.at) {
                case let (x?, y?): return x > y
                case (_?, nil): return true
                case (nil, _?): return false
                default: return a.offset < b.offset
                }
            }.map(\.element)
        }
        for group in bots?.groups ?? [] {
            var rooms: [RoomListItem] = []
            let leads = group.bots.filter { $0.rank == "lead" }
            if let meeting = group.meetingChannel, leads.count > 1 {
                rooms.append(item(meeting, title: "팀장회의", subtitle: "팀장 \(leads.count)명이 모여 이야기해요", faces: leads.map(\.name)))
            }
            if let teams = group.teams, !teams.isEmpty {
                for team in teams where !seen.contains(team.channel) {
                    let members = bots?.members(of: team) ?? []
                    let lead = members.first { $0.rank == "lead" }
                    var chips: [String] = []
                    if lead?.isNew == true { chips.append("새 팀") }
                    if lead?.status == "working" { chips.append("일하는 중") }
                    rooms.append(item(team.channel, title: team.name, subtitle: lead?.statusText.map(Self.statusLine) ?? team.purpose,
                                      faces: members.map(\.name), status: lead?.status, chips: chips))
                }
            } else {
                for bot in group.bots where !seen.contains(bot.channel) {
                    var chips: [String] = []
                    if bot.isNew == true { chips.append("새 봇") }
                    if bot.status == "working" { chips.append("일하는 중") }
                    rooms.append(item(bot.channel, title: roomTitle(bot.channel), subtitle: bot.statusText.map(Self.statusLine) ?? bot.role,
                                      faces: [bot.name], avatar: bot.avatar, status: bot.status, chips: chips))
                }
            }
            sections.append(RoomSection(id: group.id, label: group.label, summary: group.summary, rooms: newestFirst(rooms)))
        }
        let others = (channels?.channels ?? []).filter { c in
            !seen.contains(c.id) && !Self.isHiddenRoom(c) && (c.writable == true || c.kind == "team" || !timeline.items(in: c.id).isEmpty)
        }
        // Grouped by what the Mac says (§21.2 `group`), in the order it lists them.
        var groupOrder: [String] = []
        var byGroup: [String: [RoomListItem]] = [:]
        for c in others {
            let label = c.group ?? "그 밖의 방"
            if byGroup[label] == nil { groupOrder.append(label) }
            byGroup[label, default: []].append(item(c.id, title: c.label, subtitle: c.id == "dev-session" ? "이 맥의 개발 세션과 바로 이야기해요" : nil,
                                                    faces: [c.lead?.name ?? c.label]))
        }
        for label in groupOrder { sections.append(RoomSection(id: "_g:" + label, label: label, rooms: newestFirst(byGroup[label] ?? []))) }
        // Sections follow the Mac's room order (§21.2: 결재 · 팀장회의 · 팀 · 브리핑 · 장애 · 개발 세션).
        let order = (channels?.channels ?? []).enumerated().reduce(into: [String: Int]()) { $0[$1.element.id] = $1.offset }
        if !order.isEmpty {
            sections = sections.enumerated().sorted { a, b in
                let x = a.element.rooms.compactMap { order[$0.id] }.min() ?? Int.max
                let y = b.element.rooms.compactMap { order[$0.id] }.min() ?? Int.max
                return x != y ? x < y : a.offset < b.offset
            }.map(\.element)
        }
        return sections
    }

    /// "[AX] [개선] improve… 하는 중" → "improve… 하는 중": tags in brackets mean nothing in a status line.
    static func statusLine(_ text: String) -> String {
        text.replacingOccurrences(of: #"^(\s*\[[^\]]{1,16}\]\s*)+"#, with: "", options: .regularExpression)
    }

    /// Rooms that only carry notices: never shown as rooms, even when an older Mac still lists them.
    /// Rooms the owner never sees (§21.1–21.2): the old log room and any "알림 방" an older Mac still lists.
    /// Read-only rooms (결재·브리핑·장애) show only when they have something in them.
    static func isHiddenRoom(_ c: ChannelsView.Channel) -> Bool {
        let name = c.label.replacingOccurrences(of: " ", with: "")
        return c.id == "로그" || name == "로그" || name.contains("알림방") || name == "알림"
    }

    /// The last line of a room for the list, with who said it: "Leo: …", "Leo → Mia: …", "나: …".
    func roomPreview(_ room: String) -> (text: String, at: Date)? {
        for item in timeline.items(in: room).reversed() {
            switch item {
            case .message(let m):
                let who = m.role == .owner ? "나" : m.author?.name ?? (room.isEmpty ? assistantName : nil)
                let text = ChatText.preview(m.text, limit: 90)
                if text.isEmpty { continue }
                return (who.map { "\($0): \(text)" } ?? text, m.at)
            case .notice(let n):
                if let talk = BotTalk.parse(n.text) { return ("\(talk.from) → \(talk.to): \(ChatText.preview(talk.text, limit: 90))", n.at) }
                let text = ChatText.preview(n.text, limit: 90)
                if text.isEmpty { continue }
                return (n.author.map { "\($0.name): \(text)" } ?? text, n.at)
            case .delegation(let d):
                return (ChatText.preview(d.summary ?? d.task, limit: 90), d.at)
            case .card(let id, _):
                if let c = timeline.card(id) { return ("결재: " + ChatText.preview(ChatText.cardTitle(summary: c.summary, note: c.note), limit: 80), c.at) }
            }
        }
        return nil
    }

    /// false for read-only rooms (no input box).
    func canWrite(in room: String) -> Bool {
        channels?.channels.first(where: { $0.id == room })?.writable ?? true
    }

    func showRoom(_ room: String) {
        tab = .home
        openRoom = room
    }

    /// Asks the home tab to slide the room list out.
    var openRoomList = false
    /// The 오늘 sheet on 홈 (a link can open or close it).
    var showingToday = false
    /// Document bodies read for search (key = source:id), kept for the session.
    private(set) var docBodies: [String: String] = [:]
    private(set) var docBodiesLoading: (done: Int, total: Int)?
    private(set) var docBodiesFailed = 0

    /// Reads every document not read yet, six at a time, so search can look inside them.
    func loadDocBodies(_ docs: [DocShelf.Doc]) async {
        guard docBodiesLoading == nil, let client else { return }
        let todo = docs.filter { docBodies[$0.key] == nil }
        guard !todo.isEmpty else { return }
        docBodiesLoading = (0, todo.count)
        docBodiesFailed = 0
        defer { docBodiesLoading = nil }
        var index = 0
        await withTaskGroup(of: (String, String?).self) { group in
            func add() {
                guard index < todo.count else { return }
                let d = todo[index]; index += 1
                group.addTask { (d.key, try? await client.view(DocumentEnvelope.self, d.source, query: ["doc": d.id]).document?.markdown) }
            }
            for _ in 0..<6 { add() }
            for await (key, body) in group {
                if let body { docBodies[key] = body } else { docBodiesFailed += 1 }
                docBodiesLoading = ((docBodiesLoading?.done ?? 0) + 1, todo.count)
                add()
            }
        }
    }

    /// A search to start in 문서.
    var docQuery: String?
    /// A document to open in 문서.
    var docRoute: String?
    /// A 더보기 screen to push (`MoreView.Route` raw value).
    var moreRoute: String?

    /// `axkit://open/...` links (widget, notifications, screenshots). Only opens screens; never acts.
    func open(_ url: URL) {
        showingToday = url.path == "/today"
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func q(_ name: String) -> String? { query.first { $0.name == name }?.value }
        switch url.path {
        case "/approvals": tab = .approvals
        case "/docs": tab = .docs; docQuery = q("q")
        case "/doc": tab = .docs; docRoute = q("id")
        case "/calendar": tab = .calendar
        case "/room": showRoom(q("id") ?? "")
        case "/rooms": tab = .home; openRoomList = true
        case "/today": showRoom("")
        case "/more": tab = .more; moreRoute = q("v")
        default: showRoom("")
        }
    }
}

/// Runs a job now, then at most once per interval; requests in between are folded into one run at the end.
@MainActor final class Throttle {
    private let interval: UInt64
    private var running = false
    private var again = false

    init(seconds: Double) { interval = UInt64(seconds * 1_000_000_000) }

    func request(_ job: @escaping @MainActor () async -> Void) {
        if running { again = true; return }
        running = true
        Task {
            repeat {
                again = false
                await job()
                try? await Task.sleep(nanoseconds: interval)
            } while again
            running = false
        }
    }
}

import AxKitCore
import SwiftUI

/// §28 하고 있는 일: what the assistant is doing in the background and what finished lately. Read-only;
/// refreshed every few seconds while something is running.
struct WorkScreen: View {
    @Environment(AppModel.self) private var model
    @State private var state: Loadable<WorkView> = .loading

    var body: some View {
        LoadableView(state: state, retry: load) { work in
            Page {
                if work.active.isEmpty && work.recent.isEmpty {
                    EmptyStateView(icon: "tray", title: "지금 하는 일이 없어요",
                                   message: "오래 걸리는 일(개발 작업, 브라우저 심부름, 생활 심부름)을 맡기면 여기에 보여요.")
                        .padding(.top, 40)
                }
                if !work.active.isEmpty {
                    Panel {
                        VStack(alignment: .leading, spacing: 4) {
                            CardHeader(title: "지금 하고 있는 일 \(work.active.count)개")
                            CardList(items: work.active) { item in WorkRow(item: item) }
                        }
                    }
                }
                if !work.recent.isEmpty {
                    Panel {
                        VStack(alignment: .leading, spacing: 4) {
                            CardHeader(title: "최근에 끝난 일")
                            CardList(items: work.recent) { item in WorkRow(item: item) }
                        }
                    }
                }
                Text("\"어떻게 됐어?\"라고 \(model.assistantName)에게 물어봐도 알려 줘요.")
                    .font(.footnote).foregroundStyle(.secondary).frame(maxWidth: .infinity)
            }
            .refreshable { await load() }
        }
        .navigationTitle("하고 있는 일")
        .task {
            await load()
            // Every 5 s while something runs, every 15 s otherwise (a job may start from another device or the Mac).
            // The task ends when the screen goes away.
            while !Task.isCancelled {
                var busy = true
                if case .loaded(let work) = state { busy = !work.active.isEmpty }
                try? await Task.sleep(nanoseconds: busy ? 5_000_000_000 : 15_000_000_000)
                guard !Task.isCancelled else { return }
                await load()
            }
        }
        // A job's result or a "시작했어요" reply just came in: read again now.
        .onChange(of: model.workTick) { Task { await load() } }
    }

    private func load() async {
        guard let client = model.client else { return }
        do { state = .loaded(try await client.work()) }
        catch { if case .loaded = state { return }; state = .failed(error.friendly) }
    }
}

struct WorkRow: View {
    var item: WorkItem
    @Environment(AppModel.self) private var model

    private var tone: Color {
        switch item.status {
        case "running": .accentColor
        case "waiting": .orange
        case "done": .green
        case "failed", "interrupted": .red
        default: .secondary
        }
    }

    /// The conversation the job was asked in, when it was asked in this app: "" (비서) or a room the phone knows.
    private var conversation: String? {
        // §31: `owner` → 비서, `bot:<id>` → that bot's room.
        if let room = item.room(bots: model.bots) { return room }
        guard let origin = item.origin, origin.channelId?.hasPrefix("channel.app") == true else { return nil }
        guard let address = origin.address, !address.isEmpty, address != "owner" else { return "" }
        let known = model.timeline.roomIds.contains(address) || model.channels?.channels.contains { $0.id == address } == true
            || model.bots?.bot(forChannel: address) != nil
        return known ? address : ""
    }

    private var icon: String {
        switch item.kind {
        case "dev": "hammer"
        case "browser": "safari"
        case "errand": "bag"
        case "bot": "person.crop.circle"
        default: "circle.dashed"
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon).font(.body).foregroundStyle(tone).frame(width: 24).padding(.top, 2)
            VStack(alignment: .leading, spacing: 4) {
                Text(item.title).font(.subheadline.weight(.semibold)).foregroundStyle(.primary)
                HStack(spacing: 6) {
                    Text(item.statusWords).foregroundStyle(tone)
                    if let phase = item.phase, item.isActive, !phase.isEmpty { Text("· \(phase)").foregroundStyle(.secondary) }
                    if let elapsed = item.elapsedWords { Text("· \(elapsed)").foregroundStyle(.secondary) }
                }
                .font(.footnote)
                Text(item.kindWords).font(.caption).foregroundStyle(.tertiary)
                if let summary = item.summary, !summary.isEmpty {
                    // May hold words read from a web page: plain text only (no Markdown links).
                    Text(verbatim: summary).font(.footnote).foregroundStyle(.secondary).lineLimit(6).textSelection(.enabled)
                }
                if let url = item.webLink {
                    Link(destination: url) { Label(ChatText.preview(item.link ?? "", limit: 50), systemImage: "link") }.font(.footnote)
                } else if let link = item.link, !link.isEmpty {
                    Text(verbatim: link).font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                }
                if let room = conversation {
                    Label("시킨 대화 보기", systemImage: "bubble.left")
                        .font(.footnote.weight(.semibold)).foregroundStyle(.tint)
                        .safeTap { model.showRoom(room) }
                        .accessibilityAddTraits(.isButton)
                }
                if item.status == "waiting", model.capabilities.has("browser-live"), item.kind != "dev" {
                    Button { model.open(URL(string: "axkit://open/more?v=browser-live")!) } label: {
                        Label("브라우저 화면 열기", systemImage: "safari")
                    }
                    .buttonStyle(.action(.primary))
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 8)
        // `.contain`, not `.combine`: the buttons inside must stay reachable with VoiceOver.
        .accessibilityElement(children: .contain)
    }
}

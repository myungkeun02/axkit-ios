import AxKitCore
import SwiftUI

/// §31: one folded line above the chat box while the assistant (or a bot) is working in the background:
/// "하는 중 2개 · 맨 위 항목". Tapping it opens the work sheet. Hidden when nothing runs.
struct WorkStrip: View {
    @Environment(AppModel.self) private var model
    @State private var showing = false

    var body: some View {
        // A VStack, not a Group: with nothing running a Group has no child and `.task` would never run.
        VStack(spacing: 0) {
            if let work = model.work, let line = WorkSheet.strip(work) {
                Button { showing = true } label: {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.mini)
                        Text(verbatim: line).font(.footnote.weight(.medium)).lineLimit(1).foregroundStyle(.primary)
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.up").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 16).padding(.vertical, 8)
                    .frame(maxWidth: .infinity)
                    .background(.bar)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(line). 누르면 하고 있는 일을 펼쳐요")
                .overlay(alignment: .top) { Divider() }
            }
        }
        // Every 15 s while something runs; otherwise only when a notice (or a hand-off) comes in.
        // Also again once the Mac's capabilities are known (right after launch or pairing they are still empty).
        .task(id: "\(model.workTick)|\(model.capabilities.hasView("work"))") {
            var work = await model.loadWork()
            while !Task.isCancelled, let w = work, !w.active.isEmpty {
                try? await Task.sleep(nanoseconds: 15_000_000_000)
                guard !Task.isCancelled else { return }
                work = await model.loadWork()
            }
        }
        .sheet(isPresented: $showing) {
            WorkSheetView { room in
                showing = false
                model.showRoom(room)
            }
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        }
    }
}

/// The unfolded sheet: what is running (sub-jobs indented under the job that handed them out) and the last few done.
struct WorkSheetView: View {
    var open: (String) -> Void
    @Environment(AppModel.self) private var model

    var body: some View {
        NavigationStack {
            List {
                if let work = model.work {
                    let active = WorkSheet.active(work)
                    let recent = WorkSheet.recent(work, limit: 5)
                    if active.isEmpty && recent.isEmpty {
                        Text("지금 하는 일이 없어요.").foregroundStyle(.secondary)
                    }
                    if !active.isEmpty {
                        Section("하는 중 \(work.active.count)개") {
                            ForEach(active) { row in WorkSheetRow(row: row, open: open) }
                        }
                    }
                    if !recent.isEmpty {
                        Section("최근에 끝난 일") {
                            ForEach(recent) { row in WorkSheetRow(row: row, open: open) }
                        }
                    }
                } else {
                    ProgressView().frame(maxWidth: .infinity)
                }
            }
            .listStyle(.insetGrouped)
            .refreshable { await model.loadWork() }
            .navigationTitle("하고 있는 일")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}

private struct WorkSheetRow: View {
    var row: WorkSheet.Row
    var open: (String) -> Void
    @Environment(AppModel.self) private var model

    private var item: WorkItem { row.item }
    private var room: String? { item.room(bots: model.bots) }

    private var tone: Color {
        switch item.status {
        case "running": .accentColor
        case "waiting": .orange
        case "done": .green
        case "failed", "interrupted": .red
        default: .secondary
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            if row.depth > 0 {
                Image(systemName: "arrow.turn.down.right").font(.caption).foregroundStyle(.tertiary).padding(.top, 3)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(verbatim: item.title).font(.subheadline.weight(row.depth == 0 ? .semibold : .regular)).lineLimit(2)
                HStack(spacing: 4) {
                    Circle().fill(tone).frame(width: 6, height: 6)
                    Text(item.statusWords).foregroundStyle(tone)
                    if let phase = item.phase, item.isActive, !phase.isEmpty { Text(verbatim: "· \(phase)").foregroundStyle(.secondary) }
                    if let elapsed = item.elapsedWords { Text("· \(elapsed)").foregroundStyle(.secondary) }
                }
                .font(.caption)
                .lineLimit(1)
                if !item.isActive, let summary = item.summary, !summary.isEmpty {
                    // May hold words read from a web page: plain text only.
                    Text(verbatim: summary).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
            }
            Spacer(minLength: 0)
            if room != nil {
                Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary).padding(.top, 3)
            }
        }
        .padding(.leading, CGFloat(row.depth) * 16)
        .contentShape(Rectangle())
        .onTapGesture { if let room { open(room) } }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(room != nil ? .isButton : [])
        .accessibilityHint(room == nil ? "" : room == "" ? "비서 대화를 열어요" : "이 일을 맡은 봇 방을 열어요")
    }
}

/// "@" in the chat box: the bots whose name matches what is typed after it. Picking one puts "@이름 " in the box.
struct MentionBar: View {
    var bots: [BotsView.Bot]
    var pick: (BotsView.Bot) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(bots) { bot in
                    Button { pick(bot) } label: {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(verbatim: "@\(bot.name)").font(.subheadline.weight(.semibold))
                            if let role = bot.role, !role.isEmpty {
                                Text(verbatim: role).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                            }
                        }
                        .padding(.horizontal, 12).padding(.vertical, 6)
                        .frame(maxWidth: 180, alignment: .leading)
                        .background(Theme.cardBackground, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(bot.name)에게 맡기기")
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 6)
        }
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }
}

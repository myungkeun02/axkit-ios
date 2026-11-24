import AxKitCore
import SwiftUI

/// Red bar across the top of every tab while recording: elapsed time and one button to stop.
struct RecordingBar: View {
    @Environment(AppModel.self) private var model
    @State private var confirmStop = false

    var body: some View {
        if let started = model.recorder.startedAt {
            HStack(spacing: 10) {
                Circle().fill(.red).frame(width: 10, height: 10)
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Text("녹음 중 \(Self.clock(context.date.timeIntervalSince(started)))").font(.subheadline.weight(.semibold).monospacedDigit())
                }
                Spacer()
                Button("끝내기") { model.stopRecording() }
                    .buttonStyle(.action(.danger, fullWidth: false, small: true))
            }
            .padding(.horizontal, 16).padding(.vertical, 8)
            .background(.bar)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("녹음 중")
        }
    }

    static func clock(_ seconds: Double) -> String {
        let s = Int(seconds)
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60) : String(format: "%02d:%02d", s / 60, s % 60)
    }
}

/// Starts a recording; the first time it says plainly what is and isn't OK to record.
struct RecordButton<Label: View>: View {
    @Environment(AppModel.self) private var model
    @AppStorage("recordingNoticeSeen") private var noticeSeen = false
    @State private var showNotice = false
    @ViewBuilder var label: Label

    var body: some View {
        Button {
            if model.recorder.isRecording { model.stopRecording() }
            else if noticeSeen { Task { await model.startRecording() } }
            else { showNotice = true }
        } label: { label }
        .alert("녹음하기 전에", isPresented: $showNotice) {
            Button("알겠어요, 녹음할게요") { noticeSeen = true; Task { await model.startRecording() } }
            Button("취소", role: .cancel) {}
        } message: {
            Text("내가 함께 있는 대화만 녹음할 수 있어요. 내가 빠진 다른 사람들의 대화를 몰래 녹음하면 안 돼요.\n녹음은 맥에서 글로 정리되고, 아이폰에서는 보낸 뒤 지워져요.")
        }
    }
}

/// 녹음과 회의록: start a recording, see what is still on its way, and open the documents made from them.
struct RecordingsScreen: View {
    @Environment(AppModel.self) private var model
    @State private var state: Loadable<RecordingsView> = .loading

    var body: some View {
        Page {
            Panel {
                VStack(alignment: .leading, spacing: 12) {
                    Text("녹음하면 맥이 글로 받아 적고, 회의록 문서로 정리해요. 할 만한 일이 보이면 결재로 제안해요.")
                        .font(.subheadline).foregroundStyle(.secondary)
                    RecordButton {
                        Text(model.recorder.isRecording ? "녹음 끝내기" : "녹음 시작")
                    }
                    .buttonStyle(.action(model.recorder.isRecording ? .danger : .primary))
                }
            }
            if !model.pendingRecordings.isEmpty {
                Panel {
                    VStack(alignment: .leading, spacing: 4) {
                        CardHeader(title: "맥으로 보내는 중")
                        CardList(items: model.pendingRecordings) { r in
                            CardRow(title: Self.title(r.startedAt), detail: "\(Format.duration(seconds: r.durationSec)) · \(Int(r.progress * 100))% 보냄") {
                                ProgressView(value: r.progress).frame(width: 60)
                            }
                        }
                        if model.connection != .live {
                            Text("맥이 연결되면 이어서 보내요.").font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            if model.capabilities.hasView("recordings") {
                if let data = state.value, !data.recordings.isEmpty {
                    Panel {
                        VStack(alignment: .leading, spacing: 4) {
                            CardHeader(title: "회의록")
                            CardList(items: data.recordings) { item in row(item) }
                        }
                    }
                } else if case .failed(let message) = state {
                    Text(message).font(.footnote).foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("녹음해서 회의록 만들기")
        .task {
            // Processing takes a while; look again every few seconds while the screen is open.
            while !Task.isCancelled {
                await load()
                try? await Task.sleep(nanoseconds: 4_000_000_000)
            }
        }
        .refreshable { await load() }
    }

    @ViewBuilder private func row(_ item: RecordingsView.Item) -> some View {
        let words: String = switch item.status {
        case "receiving": "받는 중"
        case "transcribing": "글로 받아 적는 중"
        case "summarizing": "회의록으로 정리하는 중"
        case "failed": "정리하지 못했어요"
        default: item.driveUrl != nil ? "정리 끝 · Drive에 저장됨" : "정리 끝"
        }
        let detail = [item.statusText ?? words, item.durationSec.map { Format.duration(seconds: $0) }].compactMap { $0 }.joined(separator: " · ")
        if let doc = item.documentId, item.status == "done" {
            NavigationLink { DocumentScreen(id: doc) } label: {
                CardRow(title: item.title ?? Self.title(item.startedAt), detail: detail) {
                    Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
                }
            }
            .buttonStyle(.plain)
        } else {
            CardRow(title: item.title ?? Self.title(item.startedAt), detail: detail, titleColor: item.status == "failed" ? .red : .primary) {
                if item.status != "failed" { ProgressView() }
            }
        }
    }

    static func title(_ date: Date?) -> String {
        guard let date else { return "녹음" }
        return "\(Format.relative(date)) 녹음 · \(Format.clock(date))"
    }

    private func load() async {
        guard let client = model.client, model.capabilities.hasView("recordings") else { return }
        do { state = .loaded(try await client.view(RecordingsView.self, "recordings")) } catch { if state.value == nil { state = .failed(error.friendly) } }
    }
}

extension View {
    /// The recording bar under a tab's title bar (so it never covers navigation buttons).
    func recordingBarInset() -> some View { safeAreaInset(edge: .top, spacing: 0) { RecordingBar() } }
}

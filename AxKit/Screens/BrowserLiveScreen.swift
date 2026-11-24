import AxKitCore
import SwiftUI
import UIKit

/// §22 브라우저 화면: the page the assistant's browser errand stopped at (login, captcha, consent, the final button).
/// The owner taps and types on the picture; "다 했어요" hands it back to the assistant. Only pages the Mac handed over open.
struct BrowserLiveScreen: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var phase

    enum Phase: Equatable { case loading, nothing(String), live, finishing }

    @State private var phaseNow: Phase = .loading
    @State private var state: BrowserLiveState?
    @State private var frame: BrowserLiveFrame?
    @State private var image: UIImage?
    @State private var streamTask: Task<Void, Never>?
    @State private var typing = ""
    @State private var showTyping = false
    @FocusState private var typingFocused: Bool
    @State private var busy = false
    @State private var lastTap: CGPoint?

    var body: some View {
        VStack(spacing: 0) {
            switch phaseNow {
            case .loading:
                Spacer(); ProgressView("브라우저 화면을 여는 중…"); Spacer()
            case .nothing(let words):
                EmptyStateView(icon: "safari", title: "지금 넘겨받을 화면이 없어요", message: words)
                    .frame(maxHeight: .infinity)
            case .live, .finishing:
                header
                page
                controls
            }
        }
        .background(Theme.page)
        .navigationTitle("브라우저 화면")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .tabBar)
        .toolbar {
            if phaseNow == .live || phaseNow == .finishing {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("다 했어요") { Task { await finish() } }
                        .fontWeight(.semibold)
                        .disabled(phaseNow == .finishing)
                }
            }
        }
        .task { await open() }
        .onDisappear { stopStream() }
        .onChange(of: phase) { _, now in
            if now == .background { stopStream() }
            if now == .active, phaseNow == .live, streamTask == nil { startStream() }
        }
        .sheet(isPresented: $showTyping) { typingSheet }
    }

    // MARK: pieces

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Image(systemName: "lock.fill").font(.caption2).foregroundStyle(.secondary)
                Text(frame?.url.flatMap { URL(string: $0)?.host } ?? state?.host ?? "")
                    .font(.footnote.weight(.semibold)).lineLimit(1)
                Spacer()
                if let closes = state?.idleClosesAt {
                    Text("\(Format.clock(closes))까지 열려 있어요").font(.caption2).foregroundStyle(.tertiary)
                }
            }
            Text(state?.reasonWords ?? "직접 해 주셔야 하는 단계예요").font(.caption).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
        .background(.bar)
    }

    private var page: some View {
        GeometryReader { geo in
            ZStack {
                Color(.secondarySystemBackground)
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: geo.size.width, height: geo.size.height)
                        .accessibilityLabel(frame?.title ?? "브라우저 화면")
                        .accessibilityHint("누른 곳을 맥의 브라우저에서 눌러요")
                } else {
                    ProgressView()
                }
                if let lastTap {
                    Circle().stroke(Color.accentColor, lineWidth: 2).frame(width: 34, height: 34).position(lastTap)
                        .allowsHitTesting(false)
                }
                if phaseNow == .finishing {
                    Color.black.opacity(0.25)
                    ProgressView("비서에게 넘기는 중…").padding(16).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                }
            }
            .contentShape(Rectangle())
            .gesture(
                SpatialTapGesture().onEnded { value in tap(at: value.location, in: geo.size) }
            )
            .simultaneousGesture(
                DragGesture(minimumDistance: 24).onEnded { value in
                    guard let frame else { return }
                    // Drag up = see further down. Screen points → JPEG pixels by the same scale as the picture.
                    let scale = min(geo.size.width / CGFloat(frame.width), geo.size.height / CGFloat(frame.height))
                    let dy = -value.translation.height / max(scale, 0.01)
                    act(.scroll(dy: Int(dy * 1.3)))
                }
            )
        }
    }

    private var controls: some View {
        HStack(spacing: 6) {
            control("chevron.backward", "뒤로") { act(.back) }
            control("keyboard", "글자 쓰기") { showTyping = true }
            control("return", "엔터") { act(.key("Enter")) }
            control("delete.left", "지우기") { act(.key("Backspace")) }
            control("arrow.right.to.line", "다음 칸") { act(.key("Tab")) }
            control("arrow.up", "위로") { act(.scroll(dy: -700)) }
            control("arrow.down", "아래로") { act(.scroll(dy: 700)) }
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .background(.bar)
    }

    private func control(_ icon: String, _ label: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).font(.system(size: 17, weight: .medium))
                .frame(maxWidth: .infinity, minHeight: 40)
        }
        .buttonStyle(.bordered)
        .disabled(phaseNow != .live)
        .accessibilityLabel(label)
    }

    private var typingSheet: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("먼저 화면에서 칸을 누르고, 여기에 쓰세요", text: $typing, axis: .vertical)
                        .lineLimit(1...5)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .focused($typingFocused)
                } footer: {
                    Text("다 쓴 뒤 한 번에 보내요. 쓴 글자는 그 페이지로만 가고, 맥의 기록이나 대화에는 남지 않아요.")
                }
            }
            .navigationTitle("글자 쓰기")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("취소") { showTyping = false } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("보내기") {
                        let text = typing
                        typing = ""
                        showTyping = false
                        act(.type(text))
                    }
                    .disabled(typing.isEmpty)
                }
            }
            .onAppear { typingFocused = true }
        }
        .presentationDetents([.height(260)])
    }

    // MARK: work

    private func open() async {
        guard let client = model.client else { return }
        do {
            var s = try await client.browserLive()
            if !s.live {
                guard s.pending != nil else {
                    phaseNow = .nothing(s.closedWords ?? "브라우저 심부름이 로그인이나 확인 단계에서 멈추면 여기서 그 페이지를 직접 볼 수 있어요.")
                    return
                }
                s = try await client.browserLiveStart()
            }
            state = s
            phaseNow = .live
            startStream()
        } catch {
            phaseNow = .nothing(error.friendly)
        }
    }

    private func startStream() {
        guard let client = model.client, streamTask == nil else { return }
        streamTask = Task {
            var failures = 0
            while !Task.isCancelled {
                do {
                    for try await update in client.browserLiveStream() {
                        failures = 0
                        apply(update)
                    }
                } catch {
                    if Task.isCancelled { return }
                    failures += 1
                }
                if Task.isCancelled || phaseNow != .live { return }
                // The stream cannot be used: one picture every 2 seconds instead (the request limit is 60 a minute).
                if failures >= 2 {
                    await poll(client)
                    return
                }
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
    }

    private func poll(_ client: APIClient) async {
        while !Task.isCancelled, phaseNow == .live {
            if let bytes = try? await client.browserLiveFrame() {
                if let picture = UIImage(data: bytes) {
                    image = picture
                    frame = BrowserLiveFrame(seq: (frame?.seq ?? 0) + 1, url: frame?.url, title: frame?.title,
                                             width: Int(picture.size.width * picture.scale), height: Int(picture.size.height * picture.scale), jpeg: Data())
                }
            } else if let s = try? await client.browserLive(), !s.live {
                apply(.state(s))
                return
            }
            try? await Task.sleep(nanoseconds: 2_000_000_000)
        }
    }

    private func stopStream() {
        streamTask?.cancel()
        streamTask = nil
    }

    private func apply(_ update: BrowserLiveUpdate) {
        switch update {
        case .frame(let f):
            frame = f
            image = UIImage(data: f.jpeg)
            lastTap = nil
        case .state(let s):
            state = s
            if !s.live, phaseNow == .live {
                stopStream()
                phaseNow = .nothing(s.closedWords ?? "브라우저 화면이 닫혔어요.")
            }
        }
    }

    private func tap(at point: CGPoint, in size: CGSize) {
        guard phaseNow == .live, let frame else { return }
        guard let pixel = BrowserLiveGeometry.pixel(at: point, shown: size, image: CGSize(width: frame.width, height: frame.height)) else { return }
        lastTap = point
        act(.tap(x: pixel.x, y: pixel.y))
    }

    private func act(_ action: BrowserLiveAction) {
        guard let client = model.client, phaseNow == .live else { return }
        Task {
            do {
                let answer = try await client.browserLive(action)
                if answer.accepted == false {
                    // Too fast (more than 8 a second): try once more a moment later.
                    try? await Task.sleep(nanoseconds: UInt64(max(answer.retryAfterMs ?? 250, 100)) * 1_000_000)
                    _ = try? await client.browserLive(action)
                }
            } catch {
                model.toast = error.friendly
                if case APIError.refused = error, let s = try? await client.browserLive(), !s.live { apply(.state(s)) }
            }
        }
    }

    private func finish() async {
        guard let client = model.client else { return }
        phaseNow = .finishing
        stopStream()
        do {
            let s = try await client.browserLiveDone()
            model.toast = s.doneWords
            // Back to the chat the errand came from; when it carries on in Discord, just say so and stay.
            if let room = s.returnRoom { model.showRoom(room) }
            dismiss()
        } catch {
            phaseNow = .live
            startStream()
            model.toast = error.friendly
        }
    }
}

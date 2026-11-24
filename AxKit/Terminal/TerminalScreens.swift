import AxKitCore
import SwiftTerm
import SwiftUI
import UIKit

/// 터미널 first screen: the phone's key (to put on each Mac) and the Macs to open.
struct TerminalHostsScreen: View {
    @State private var store = TerminalStore()
    @State private var editing: SSHHost?
    @State private var adding = false
    @State private var confirmNewKey = false
    @Environment(AppModel.self) private var model

    var body: some View {
        Page {
            Panel {
                VStack(alignment: .leading, spacing: 10) {
                    CardHeader(title: "이 아이폰의 열쇠")
                    Text("이 한 줄을 각 맥의 ~/.ssh/authorized_keys 파일에 넣으면 비밀번호 없이 들어가요. 열쇠의 비밀 부분은 이 아이폰 밖으로 나가지 않아요.")
                        .font(.footnote).foregroundStyle(.secondary)
                    if let line = store.publicKeyLine {
                        Text(line)
                            .font(.system(.caption, design: .monospaced))
                            .lineLimit(3)
                            .truncationMode(.middle)
                            .padding(10)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Theme.page, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                            .textSelection(.enabled)
                            .accessibilityLabel("공개키")
                        HStack(spacing: 8) {
                            Button {
                                UIPasteboard.general.string = line
                                model.toast = "공개키를 복사했어요."
                            } label: { Label("복사", systemImage: "doc.on.doc") }
                                .buttonStyle(.action(.primary))
                            ShareLink(item: line) { Label("보내기", systemImage: "square.and.arrow.up") }
                                .buttonStyle(.action(.secondary))
                        }
                        if let fp = store.fingerprint {
                            Text(fp).font(.system(.caption2, design: .monospaced)).foregroundStyle(.tertiary)
                        }
                    }
                }
            }
            Panel {
                VStack(alignment: .leading, spacing: 6) {
                    CardHeader(title: "맥")
                    if store.hosts.isEmpty {
                        Text("아직 넣은 맥이 없어요. 아래에서 추가해 주세요.").font(.footnote).foregroundStyle(.secondary)
                    }
                    CardList(items: store.hosts) { host in
                        NavigationLink { TerminalScreen(host: host, store: store) } label: {
                            CardRow(title: host.name, detail: host.target) {
                                Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
                            }
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            Button { editing = host } label: { Label("고치기", systemImage: "pencil") }
                            Button(role: .destructive) { store.delete(host) } label: { Label("지우기", systemImage: "trash") }
                        }
                    }
                    Button { adding = true } label: { Label("맥 추가", systemImage: "plus") }
                        .buttonStyle(.action(.secondary))
                        .padding(.top, 4)
                }
            }
            Text("아이폰과 맥 모두 Tailscale이 켜져 있어야 해요. 맥은 설정 › 일반 › 공유 › 원격 로그인이 켜져 있어야 해요. 맥을 길게 누르면 고치거나 지울 수 있어요.")
                .font(.caption).foregroundStyle(.secondary).padding(.horizontal, 4)
            Button("새 열쇠 만들기") { confirmNewKey = true }
                .font(.footnote).foregroundStyle(.red)
                .frame(maxWidth: .infinity)
        }
        .navigationTitle("터미널")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $adding) { HostEditSheet(host: nil) { store.save($0) } }
        .sheet(item: $editing) { host in HostEditSheet(host: host) { store.save($0) } }
        .confirmationDialog("새 열쇠를 만들까요?", isPresented: $confirmNewKey, titleVisibility: .visible) {
            Button("새 열쇠 만들기", role: .destructive) { store.replaceKey(); model.toast = "새 열쇠를 만들었어요. 맥마다 새 공개키를 다시 넣어 주세요." }
        } message: {
            Text("지금 열쇠는 더 못 써요. 모든 맥의 authorized_keys에 새 공개키를 다시 넣어야 해요.")
        }
        .onChange(of: store.problem) { _, p in if let p { model.toast = p; store.problem = nil } }
    }
}

/// Add or fix one Mac.
struct HostEditSheet: View {
    var host: SSHHost?
    var onSave: (SSHHost) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var user = ""
    @State private var address = ""
    @State private var port = "22"

    private var built: SSHHost? {
        let n = name.trimmingCharacters(in: .whitespaces), u = user.trimmingCharacters(in: .whitespaces)
        let a = address.trimmingCharacters(in: .whitespaces)
        guard !n.isEmpty, !u.isEmpty, !u.contains(" "), !a.isEmpty, !a.contains(" "), let p = Int(port), (1...65535).contains(p) else { return nil }
        return SSHHost(id: host?.id ?? "h_" + UUID().uuidString.prefix(8).lowercased(), name: n, user: u, address: a, port: p)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("이름 (예: 서버 맥)", text: $name)
                }
                Section {
                    TextField("사용자 (맥 로그인 이름)", text: $user)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    TextField("주소 (Tailscale 100.x.y.z 또는 이름)", text: $address)
                        .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                    TextField("포트", text: $port).keyboardType(.numberPad)
                } footer: {
                    Text("맥의 사용자 이름은 맥 터미널에서 whoami 로 알 수 있어요.")
                }
            }
            .navigationTitle(host == nil ? "맥 추가" : "맥 고치기")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("취소") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("저장") { if let built { onSave(built); dismiss() } }.disabled(built == nil)
                }
            }
            .onAppear {
                if let host { name = host.name; user = host.user; address = host.address; port = String(host.port) }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

/// The terminal itself. Leaves when the app goes to the background and reconnects when it comes back.
struct TerminalScreen: View {
    let host: SSHHost
    let store: TerminalStore
    @State private var session: TerminalSession?
    @Environment(\.scenePhase) private var phase

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let session {
                SwiftTermView(session: session).ignoresSafeArea(.container, edges: .bottom)
                overlay(session)
            }
        }
        .navigationTitle(host.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .tabBar)
        .toolbarBackground(.black, for: .navigationBar)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .toolbar {
            if let session {
                ToolbarItem(placement: .topBarTrailing) {
                    if session.isLive {
                        Button("끊기") { session.disconnect() }
                    } else {
                        Button("다시 연결") { session.connect() }
                    }
                }
            }
        }
        .onAppear {
            if session == nil { session = TerminalSession(host: host, store: store) }
        }
        .onDisappear { session?.disconnect() }
        .onChange(of: phase) { _, now in
            guard let session else { return }
            if now == .background, session.isLive { session.disconnect(forBackground: true) }
            if now == .active, session.leftForBackground { session.connect() }
        }
        .alert("이 맥의 열쇠가 바뀌었어요", isPresented: Binding(
            get: { if case .hostKeyChanged = session?.state { true } else { false } },
            set: { _ in })) {
            Button("연결하지 않기", role: .cancel) { session?.disconnect() }
            Button("새 열쇠 믿고 연결", role: .destructive) {
                if case .hostKeyChanged(_, let key) = session?.state { session?.trustNewKey(key) }
            }
        } message: {
            if case .hostKeyChanged(let fp, _) = session?.state {
                Text("\(host.name)이(가) 전에 본 것과 다른 열쇠를 보냈어요. 맥을 새로 설치했다면 괜찮지만, 아니라면 누가 중간에 끼어든 것일 수 있어요. 맥에서 ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub 로 확인해 보세요.\n\n새 열쇠: \(fp)")
            }
        }
    }

    @ViewBuilder private func overlay(_ session: TerminalSession) -> some View {
        switch session.state {
        case .idle, .connecting:
            VStack(spacing: 10) {
                ProgressView().tint(.white)
                Text("\(host.name)에 연결하는 중…").foregroundStyle(.white.opacity(0.8)).font(.subheadline)
            }
        case .ended(let message):
            VStack(spacing: 14) {
                Text(message).foregroundStyle(.white).multilineTextAlignment(.center).font(.subheadline)
                Button("다시 연결") { session.connect() }.buttonStyle(.action(.primary)).frame(maxWidth: 220)
            }
            .padding(20)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: Theme.corner, style: .continuous))
            .environment(\.colorScheme, .dark)
            .padding(24)
        case .connected, .hostKeyChanged:
            EmptyView()
        }
    }
}

/// SwiftTerm's terminal view. Its keyboard bar already has Esc, Ctrl, Tab and the arrows.
struct SwiftTermView: UIViewRepresentable {
    let session: TerminalSession

    func makeCoordinator() -> Coordinator { Coordinator(session: session) }

    func makeUIView(context: Context) -> TerminalView {
        let view = TerminalView(frame: .zero, font: UIFont.monospacedSystemFont(ofSize: 13, weight: .regular))
        view.terminalDelegate = context.coordinator
        view.nativeBackgroundColor = .black
        view.nativeForegroundColor = UIColor(white: 0.92, alpha: 1)
        view.backgroundColor = .black
        view.keyboardAppearance = .dark
        view.autocorrectionType = .no
        view.autocapitalizationType = .none
        session.view = view
        DispatchQueue.main.async {
            session.connect()
            _ = view.becomeFirstResponder()
        }
        return view
    }

    func updateUIView(_ view: TerminalView, context: Context) {
        if session.state == .connected, let fp = session.firstTimeFingerprint, !context.coordinator.saidFirstTime {
            context.coordinator.saidFirstTime = true
            view.feed(text: "\u{1B}[2m처음 연결한 맥이라 이 맥의 열쇠를 기억했어요 (\(fp)). 나중에 바뀌면 알려 드릴게요.\u{1B}[0m\r\n")
        }
    }

    final class Coordinator: NSObject, TerminalViewDelegate {
        let session: TerminalSession
        var saidFirstTime = false
        init(session: TerminalSession) { self.session = session }

        func send(source: TerminalView, data: ArraySlice<UInt8>) {
            MainActor.assumeIsolated { session.send(data) }
        }
        func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
            MainActor.assumeIsolated { session.resize(cols: newCols, rows: newRows) }
        }
        func setTerminalTitle(source: TerminalView, title: String) {}
        func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
        func scrolled(source: TerminalView, position: Double) {}
        func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {
            if let url = URL(string: link), url.scheme == "https" { UIApplication.shared.open(url) }
        }
        func bell(source: TerminalView) {}
        func clipboardCopy(source: TerminalView, content: Data) {
            if let text = String(data: content, encoding: .utf8) { UIPasteboard.general.string = text }
        }
        func iTermContent(source: TerminalView, content: ArraySlice<UInt8>) {}
        func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
    }
}

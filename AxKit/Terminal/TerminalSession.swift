import AxKitCore
import Citadel
import CryptoKit
import Foundation
import NIOCore
import NIOSSH
import Observation
import SwiftTerm

/// The hosts, the phone's key and the remembered host keys for the 터미널.
@MainActor @Observable
final class TerminalStore {
    private let list = SSHHostList()
    let known = KnownHosts()
    private let keys = SSHKeyStore()

    private(set) var hosts: [SSHHost] = []
    private(set) var publicKeyLine: String?
    var problem: String?

    static let keyComment = "axkit-iphone"

    init() {
        list.seed(SSHHost.presets(Bundle.main.object(forInfoDictionaryKey: "AXSSHHosts") as? String))
        hosts = list.hosts
        loadKey()
    }

    private func loadKey() {
        do { publicKeyLine = SSHKeyFormat.openSSHLine(try keys.loadOrCreate().publicKey, comment: Self.keyComment) }
        catch { problem = "아이폰 열쇠를 만들지 못했어요." }
    }

    var fingerprint: String? { publicKeyLine.flatMap { SSHKeyFormat.fingerprint(openSSHLine: $0) } }

    func privateKey() throws -> Curve25519.Signing.PrivateKey { try keys.loadOrCreate() }

    /// A new key; the old public line stops working on every Mac.
    func replaceKey() {
        do { publicKeyLine = SSHKeyFormat.openSSHLine(try keys.replace().publicKey, comment: Self.keyComment) }
        catch { problem = "새 열쇠를 만들지 못했어요." }
    }

    func save(_ host: SSHHost) {
        if let i = hosts.firstIndex(where: { $0.id == host.id }) {
            // A new address or port is a different machine as far as host keys go.
            if hosts[i].knownHostsKey != host.knownHostsKey { known.forget(hosts[i].knownHostsKey) }
            hosts[i] = host
        } else {
            hosts.append(host)
        }
        list.save(hosts)
    }

    func delete(_ host: SSHHost) {
        hosts.removeAll { $0.id == host.id }
        known.forget(host.knownHostsKey)
        list.save(hosts)
    }
}

struct HostKeyChangedError: Error {}

/// Checks the Mac's host key: remember it the first time, refuse it if it changes later.
final class HostKeyCheck: NIOSSHClientServerAuthenticationDelegate, @unchecked Sendable {
    enum Seen { case firstTime(fingerprint: String), changed(new: String, old: String) }
    private let host: String
    private let known: KnownHosts
    private let lock = NSLock()
    private var _seen: Seen?
    var seen: Seen? { lock.withLock { _seen } }

    init(host: String, known: KnownHosts) { self.host = host; self.known = known }

    func validateHostKey(hostKey: NIOSSHPublicKey, validationCompletePromise: EventLoopPromise<Void>) {
        let line = String(openSSHPublicKey: hostKey)
        switch known.check(line, for: host) {
        case .same:
            validationCompletePromise.succeed(())
        case .new:
            known.remember(line, for: host)
            lock.withLock { _seen = .firstTime(fingerprint: SSHKeyFormat.fingerprint(openSSHLine: line) ?? "") }
            validationCompletePromise.succeed(())
        case .changed(let old):
            lock.withLock { _seen = .changed(new: line, old: old) }
            validationCompletePromise.fail(HostKeyChangedError())
        }
    }
}

/// One terminal: an SSH shell on a Mac, drawn by SwiftTerm.
@MainActor @Observable
final class TerminalSession {
    enum State: Equatable {
        case idle, connecting, connected
        case ended(String)
        case hostKeyChanged(newFingerprint: String, newKey: String)
    }

    let host: SSHHost
    private let store: TerminalStore
    private(set) var state: State = .idle
    /// Said once in the terminal on the first connection to a Mac.
    private(set) var firstTimeFingerprint: String?
    /// Left because the app went to the background; come back and it reconnects by itself.
    private(set) var leftForBackground = false

    @ObservationIgnored weak var view: TerminalView?
    @ObservationIgnored private var client: SSHClient?
    @ObservationIgnored private var writer: TTYStdinWriter?
    @ObservationIgnored private var task: Task<Void, Never>?

    init(host: SSHHost, store: TerminalStore) { self.host = host; self.store = store }

    var isLive: Bool { state == .connected || state == .connecting }

    func connect() {
        guard !isLive else { return }
        leftForBackground = false
        state = .connecting
        let check = HostKeyCheck(host: host.knownHostsKey, known: store.known)
        task = Task { [weak self] in
            guard let self else { return }
            do {
                let key = try store.privateKey()
                let client = try await SSHClient.connect(
                    host: host.address, port: host.port,
                    authenticationMethod: .ed25519(username: host.user, privateKey: key),
                    hostKeyValidator: .custom(check), reconnect: .never, connectTimeout: .seconds(12))
                self.client = client
                if case .firstTime(let fp) = check.seen { firstTimeFingerprint = fp }
                let terminal = view?.getTerminal()
                let request = SSHChannelRequestEvent.PseudoTerminalRequest(
                    wantReply: true, term: "xterm-256color",
                    terminalCharacterWidth: terminal?.cols ?? 80, terminalRowHeight: terminal?.rows ?? 24,
                    terminalPixelWidth: 0, terminalPixelHeight: 0, terminalModes: SSHTerminalModes([:]))
                try await client.withPTY(request) { inbound, outbound in
                    self.writer = outbound
                    self.state = .connected
                    for try await chunk in inbound {
                        switch chunk {
                        case .stdout(let buffer), .stderr(let buffer):
                            self.view?.feed(byteArray: Array(buffer.readableBytesView)[...])
                        }
                    }
                }
                finish(leftForBackground ? "앱을 벗어나서 연결을 끊었어요." : "연결이 끝났어요.")
            } catch {
                if case .changed(let new, _) = check.seen {
                    state = .hostKeyChanged(newFingerprint: SSHKeyFormat.fingerprint(openSSHLine: new) ?? "", newKey: new)
                    cleanUp()
                } else if Task.isCancelled || leftForBackground {
                    finish(leftForBackground ? "앱을 벗어나서 연결을 끊었어요." : "연결을 끊었어요.")
                } else {
                    finish(Self.words(for: error, host: host))
                }
            }
        }
    }

    func disconnect(forBackground: Bool = false) {
        leftForBackground = forBackground
        task?.cancel()
        let client = self.client
        Task { try? await client?.close() }
        if isLive { finish(forBackground ? "앱을 벗어나서 연결을 끊었어요." : "연결을 끊었어요.") }
    }

    /// The owner checked and the Mac really changed (reinstalled, new disk): trust the new key and connect.
    func trustNewKey(_ line: String) {
        store.known.remember(line, for: host.knownHostsKey)
        state = .idle
        connect()
    }

    func send(_ bytes: ArraySlice<UInt8>) {
        guard let writer else { return }
        let buffer = ByteBuffer(bytes: bytes)
        Task { try? await writer.write(buffer) }
    }

    func resize(cols: Int, rows: Int) {
        guard let writer, cols > 0, rows > 0 else { return }
        Task { try? await writer.changeSize(cols: cols, rows: rows, pixelWidth: 0, pixelHeight: 0) }
    }

    private func finish(_ message: String) {
        cleanUp()
        state = .ended(message)
    }

    private func cleanUp() {
        writer = nil
        client = nil
        task = nil
    }

    /// Plain words for what went wrong; never the raw error.
    static func words(for error: Error, host: SSHHost) -> String {
        if let e = error as? SSHClientError, case .allAuthenticationOptionsFailed = e {
            return "\(host.name)이(가) 이 아이폰 열쇠를 아직 몰라요. 터미널 첫 화면의 공개키를 맥의 ~/.ssh/authorized_keys에 넣어 주세요."
        }
        let text = String(describing: error).lowercased()
        if text.contains("authentication") {
            return "\(host.name)이(가) 이 아이폰 열쇠를 아직 몰라요. 터미널 첫 화면의 공개키를 맥의 ~/.ssh/authorized_keys에 넣어 주세요."
        }
        if text.contains("timeout") || text.contains("timed out") {
            return "\(host.name)에 닿지 않아요. 아이폰과 맥 모두 Tailscale이 켜져 있는지 봐 주세요."
        }
        if text.contains("refused") {
            return "\(host.name)이(가) 연결을 받지 않아요. 맥의 설정 › 일반 › 공유에서 '원격 로그인'을 켜 주세요."
        }
        if text.contains("unreachable") || text.contains("no route") || text.contains("resolve") {
            return "\(host.name)을(를) 찾지 못했어요. 주소와 Tailscale 연결을 확인해 주세요."
        }
        return "\(host.name)에 연결하지 못했어요. 잠시 뒤 다시 해 주세요."
    }
}

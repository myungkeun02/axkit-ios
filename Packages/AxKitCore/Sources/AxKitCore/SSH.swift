import CryptoKit
import Foundation
import Security

// The 터미널: the phone opens an SSH session straight to a Mac over Tailscale. Nothing here goes through the AX server.

/// A Mac the terminal can open. Saved on this phone only.
public struct SSHHost: Codable, Hashable, Identifiable, Sendable {
    public var id: String
    public var name: String
    public var user: String
    public var address: String
    public var port: Int

    public init(id: String = "h_" + UUID().uuidString.prefix(8).lowercased(), name: String, user: String, address: String, port: Int = 22) {
        self.id = id; self.name = name; self.user = user; self.address = address; self.port = port
    }

    /// `user@address` (and `:port` when it is not 22).
    public var target: String { "\(user)@\(address)" + (port == 22 ? "" : ":\(port)") }
    /// Key for the remembered host key; the same Mac on another port is a different entry, like OpenSSH.
    public var knownHostsKey: String { port == 22 ? address : "[\(address)]:\(port)" }

    /// `name=user@address[:port]` entries separated by commas (the `AX_SSH_HOSTS` build setting).
    /// Bad entries are skipped. The id comes from the target, so the same preset is recognised on the next launch.
    public static func presets(_ text: String?) -> [SSHHost] {
        guard let text, !text.hasPrefix("$(") else { return [] }
        return text.split(separator: ",").compactMap { entry in
            let parts = entry.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count == 2, !parts[0].isEmpty, let host = parse(parts[1], name: parts[0]) else { return nil }
            return host
        }
    }

    /// `user@address[:port]` → a host (nil when it does not look right).
    public static func parse(_ target: String, name: String) -> SSHHost? {
        let at = target.split(separator: "@", maxSplits: 1).map(String.init)
        guard at.count == 2, !at[0].isEmpty, !at[0].contains(" ") else { return nil }
        var address = at[1], port = 22
        if let colon = address.lastIndex(of: ":"), !address.contains("]"), address.filter({ $0 == ":" }).count == 1 {
            guard let p = Int(address[address.index(after: colon)...]), (1...65535).contains(p) else { return nil }
            port = p
            address = String(address[..<colon])
        }
        address = address.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        guard !address.isEmpty, !address.contains(" ") else { return nil }
        return SSHHost(id: "preset:\(at[0])@\(address):\(port)", name: name, user: at[0], address: address, port: port)
    }
}

/// The phone's own SSH key (Ed25519). The private half never leaves the Keychain; the public half is one OpenSSH line
/// to paste into `~/.ssh/authorized_keys` on each Mac.
public enum SSHKeyFormat {
    /// `ssh-ed25519 AAAA… comment`
    public static func openSSHLine(_ publicKey: Curve25519.Signing.PublicKey, comment: String) -> String {
        "ssh-ed25519 " + blob(publicKey).base64EncodedString() + (comment.isEmpty ? "" : " " + comment)
    }

    /// The SSH wire form: string "ssh-ed25519", string <32 key bytes>.
    public static func blob(_ publicKey: Curve25519.Signing.PublicKey) -> Data {
        var out = Data()
        func string(_ bytes: Data) {
            var length = UInt32(bytes.count).bigEndian
            out.append(Data(bytes: &length, count: 4))
            out.append(bytes)
        }
        string(Data("ssh-ed25519".utf8))
        string(publicKey.rawRepresentation)
        return out
    }

    /// `SHA256:…` as `ssh-keygen -lf` prints it, for any OpenSSH public key line.
    public static func fingerprint(openSSHLine line: String) -> String? {
        let parts = line.split(separator: " ")
        guard parts.count >= 2, let blob = Data(base64Encoded: String(parts[1])) else { return nil }
        let digest = Data(SHA256.hash(data: blob)).base64EncodedString()
        return "SHA256:" + digest.trimmingCharacters(in: CharacterSet(charactersIn: "="))
    }
}

/// Keeps the phone's SSH key in this app's Keychain (this device only, not in backups).
public struct SSHKeyStore: Sendable {
    public let service: String
    public init(service: String = "dev.axkit.app.ssh") { self.service = service }

    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: "ed25519"]
    }

    public func load() -> Curve25519.Signing.PrivateKey? {
        var q = query
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        return try? Curve25519.Signing.PrivateKey(rawRepresentation: data)
    }

    /// The saved key, or a new one made and saved now.
    public func loadOrCreate() throws -> Curve25519.Signing.PrivateKey {
        if let key = load() { return key }
        return try replace()
    }

    /// Makes a new key. Every Mac that trusted the old one must be given the new public line.
    @discardableResult
    public func replace() throws -> Curve25519.Signing.PrivateKey {
        let key = Curve25519.Signing.PrivateKey()
        SecItemDelete(query as CFDictionary)
        var q = query
        q[kSecValueData as String] = key.rawRepresentation
        q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(q as CFDictionary, nil)
        guard status == errSecSuccess else { throw CredentialStoreError.keychain(status) }
        return key
    }
}

/// Host keys seen before (trust on first use). A different key later means the Mac changed — or someone is in between.
public final class KnownHosts: @unchecked Sendable {
    public enum Check: Equatable { case new, same, changed(previous: String) }

    private let defaults: UserDefaults
    private let storeKey = "ssh.knownHosts"
    private let lock = NSLock()

    public init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    private var all: [String: String] { defaults.dictionary(forKey: storeKey) as? [String: String] ?? [:] }

    public func check(_ hostKeyLine: String, for host: String) -> Check {
        lock.withLock {
            guard let saved = all[host] else { return .new }
            return Self.sameKey(saved, hostKeyLine) ? .same : .changed(previous: saved)
        }
    }

    public func remember(_ hostKeyLine: String, for host: String) {
        lock.withLock {
            var map = all
            map[host] = hostKeyLine
            defaults.set(map, forKey: storeKey)
        }
    }

    public func forget(_ host: String) {
        lock.withLock {
            var map = all
            map[host] = nil
            defaults.set(map, forKey: storeKey)
        }
    }

    public func saved(for host: String) -> String? { lock.withLock { all[host] } }

    /// Type and key bytes decide; a comment does not.
    static func sameKey(_ a: String, _ b: String) -> Bool {
        let x = a.split(separator: " ").prefix(2), y = b.split(separator: " ").prefix(2)
        return x.count == 2 && Array(x) == Array(y)
    }
}

/// The hosts list on this phone. Presets from the build are added once; a preset the owner deleted stays deleted.
public final class SSHHostList: @unchecked Sendable {
    private let defaults: UserDefaults
    private let listKey = "ssh.hosts"
    private let seededKey = "ssh.seededPresets"

    public init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    public var hosts: [SSHHost] {
        guard let data = defaults.data(forKey: listKey), let list = try? JSONDecoder().decode([SSHHost].self, from: data) else { return [] }
        return list
    }

    public func save(_ hosts: [SSHHost]) {
        if let data = try? JSONEncoder().encode(hosts) { defaults.set(data, forKey: listKey) }
    }

    public func seed(_ presets: [SSHHost]) {
        var seeded = Set(defaults.stringArray(forKey: seededKey) ?? [])
        var list = hosts
        for preset in presets where !seeded.contains(preset.id) {
            if !list.contains(where: { $0.id == preset.id || $0.target == preset.target }) { list.append(preset) }
            seeded.insert(preset.id)
        }
        save(list)
        defaults.set(Array(seeded).sorted(), forKey: seededKey)
    }
}

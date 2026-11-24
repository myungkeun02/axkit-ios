import Foundation
import Security

public protocol CredentialStore: Sendable {
    func load() -> ServerCredentials?
    func save(_ credentials: ServerCredentials) throws
    func clear()
}

public enum CredentialStoreError: Error { case keychain(OSStatus), encoding }

/// Device token and Access service token live only here: one generic-password item, this device only, after first unlock.
public struct KeychainCredentialStore: CredentialStore {
    public let service: String
    public let account: String
    /// Shared with the share extension (keychain access group). nil = this app only.
    public let accessGroup: String?

    public init(service: String = "dev.axkit.app.server", account: String = "pairing", accessGroup: String? = nil) {
        self.service = service; self.account = account; self.accessGroup = accessGroup
    }

    private var query: [String: Any] {
        var q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
        if let accessGroup { q[kSecAttrAccessGroup as String] = accessGroup }
        return q
    }

    public func load() -> ServerCredentials? {
        var q = query
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        return try? JSONDecoder().decode(ServerCredentials.self, from: data)
    }

    public func save(_ credentials: ServerCredentials) throws {
        guard let data = try? JSONEncoder().encode(credentials) else { throw CredentialStoreError.encoding }
        SecItemDelete(query as CFDictionary)
        var q = query
        q[kSecValueData as String] = data
        q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(q as CFDictionary, nil)
        guard status == errSecSuccess else { throw CredentialStoreError.keychain(status) }
    }

    public func clear() { SecItemDelete(query as CFDictionary) }

    /// Moves a pairing saved before the shared group existed into it (one time).
    public func migrate(from old: KeychainCredentialStore) {
        guard load() == nil, let saved = old.load() else { return }
        if (try? save(saved)) != nil { old.clear() }
    }
}

/// For tests and previews.
public final class MemoryCredentialStore: CredentialStore, @unchecked Sendable {
    private let lock = NSLock()
    private var value: ServerCredentials?
    public init(_ value: ServerCredentials? = nil) { self.value = value }
    public func load() -> ServerCredentials? { lock.withLock { value } }
    public func save(_ credentials: ServerCredentials) throws { lock.withLock { value = credentials } }
    public func clear() { lock.withLock { value = nil } }
}

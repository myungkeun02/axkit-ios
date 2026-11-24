import AxKitCore
import Foundation
import Security

/// What the app, the share extension and the widget share: the keychain group for the connection and an app-group
/// folder for the widget snapshot and things shared while the Mac was out of reach.
enum SharedPlace {
    static var keychainGroup: String? {
        guard let group = Bundle.main.object(forInfoDictionaryKey: "AXKeychainGroup") as? String, !group.isEmpty, !group.hasPrefix("$(") else { return nil }
        return group
    }

    static var folder: URL? {
        guard let id = Bundle.main.object(forInfoDictionaryKey: "AXAppGroup") as? String, !id.hasPrefix("$(") else { return nil }
        return FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: id)
    }

    /// The shared keychain group when this build may use it (signed with a team); otherwise this app's own keychain
    /// (unsigned simulator builds), so pairing never disappears.
    static func credentialStore() -> KeychainCredentialStore {
        let own = KeychainCredentialStore()
        guard let group = keychainGroup, canUse(group: group) else { return own }
        let shared = KeychainCredentialStore(accessGroup: group)
        shared.migrate(from: own)
        return shared.load() == nil && own.load() != nil ? own : shared
    }

    private static func canUse(group: String) -> Bool {
        let probe: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "dev.axkit.app.probe",
                                    kSecAttrAccount as String: "probe", kSecAttrAccessGroup as String: group]
        SecItemDelete(probe as CFDictionary)
        var add = probe
        add[kSecValueData as String] = Data([1])
        let status = SecItemAdd(add as CFDictionary, nil)
        SecItemDelete(probe as CFDictionary)
        return status == errSecSuccess
    }

    // MARK: widget snapshot

    struct Snapshot: Codable {
        struct Event: Codable, Hashable { var title: String; var start: Date?; var allDay: Bool }
        var updatedAt: Date
        var openCards: Int
        var firstCard: String?
        var events: [Event]
    }

    static func save(_ snapshot: Snapshot) {
        guard let url = folder?.appendingPathComponent("widget.json"), let data = try? JSONEncoder().encode(snapshot) else { return }
        try? data.write(to: url, options: .atomic)
    }

    static func snapshot() -> Snapshot? {
        guard let url = folder?.appendingPathComponent("widget.json"), let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(Snapshot.self, from: data)
    }

    // MARK: things shared while offline

    struct SharedItem: Codable, Identifiable {
        var id = UUID().uuidString
        var text: String?
        var fileName: String?
        var contentType: String?
    }

    private static var inbox: URL? { folder?.appendingPathComponent("share-inbox", isDirectory: true) }

    static func queue(_ item: SharedItem, bytes: Data?) {
        guard let inbox else { return }
        try? FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
        if let bytes { try? bytes.write(to: inbox.appendingPathComponent(item.id + ".bin")) }
        if let data = try? JSONEncoder().encode(item) { try? data.write(to: inbox.appendingPathComponent(item.id + ".json")) }
    }

    /// Items waiting, with their bytes; `remove` after sending.
    static func queued() -> [(SharedItem, Data?)] {
        guard let inbox, let names = try? FileManager.default.contentsOfDirectory(atPath: inbox.path) else { return [] }
        return names.filter { $0.hasSuffix(".json") }.compactMap { name in
            guard let data = try? Data(contentsOf: inbox.appendingPathComponent(name)),
                  let item = try? JSONDecoder().decode(SharedItem.self, from: data) else { return nil }
            return (item, try? Data(contentsOf: inbox.appendingPathComponent(item.id + ".bin")))
        }
    }

    static func remove(_ item: SharedItem) {
        guard let inbox else { return }
        try? FileManager.default.removeItem(at: inbox.appendingPathComponent(item.id + ".json"))
        try? FileManager.default.removeItem(at: inbox.appendingPathComponent(item.id + ".bin"))
    }
}

import Foundation

/// `axkit://pair?u=<baseUrl>&n=<nonce>&c=<6 digits>[&ci=…&cs=…]` from the Mac's QR (docs/APP-PROTOCOL.md §1–2).
public struct PairingLink: Equatable, Sendable {
    public var baseURL: URL
    public var nonce: String
    public var code: String
    public var accessClientId: String?
    public var accessClientSecret: String?

    public enum ParseError: Error, Equatable {
        case notALink, missingPart, badAddress, insecureAddress
    }

    public init(baseURL: URL, nonce: String, code: String, accessClientId: String? = nil, accessClientSecret: String? = nil) {
        self.baseURL = baseURL; self.nonce = nonce; self.code = code
        self.accessClientId = accessClientId; self.accessClientSecret = accessClientSecret
    }

    public static func parse(_ raw: String) throws -> PairingLink {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let components = URLComponents(string: text), components.scheme?.lowercased() == "axkit",
              components.host?.lowercased() == "pair" || components.path.lowercased().hasSuffix("pair")
        else { throw ParseError.notALink }
        var values: [String: String] = [:]
        for item in components.queryItems ?? [] { if let value = item.value { values[item.name] = value } }
        guard let address = values["u"], let nonce = values["n"], let code = values["c"], !nonce.isEmpty, !code.isEmpty
        else { throw ParseError.missingPart }
        guard nonce.range(of: #"^[A-Za-z0-9_-]{1,200}$"#, options: .regularExpression) != nil,
              code.range(of: #"^[0-9]{4,8}$"#, options: .regularExpression) != nil
        else { throw ParseError.missingPart }
        guard let url = URL(string: address), url.host != nil else { throw ParseError.badAddress }
        guard AddressPolicy.isAllowed(url) else { throw ParseError.insecureAddress }
        let ci = values["ci"].flatMap { $0.isEmpty ? nil : $0 }
        let cs = values["cs"].flatMap { $0.isEmpty ? nil : $0 }
        return PairingLink(baseURL: AddressPolicy.normalized(url), nonce: nonce, code: code, accessClientId: ci, accessClientSecret: cs)
    }
}

/// The app talks only to `https`, or to `http` on a private address (loopback, LAN, Tailscale 100.64/10).
public enum AddressPolicy {
    public static func isAllowed(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), let host = url.host?.lowercased() else { return false }
        if scheme == "https" { return true }
        guard scheme == "http" else { return false }
        return isPrivateHost(host)
    }

    public static func isPrivateHost(_ host: String) -> Bool {
        let h = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        if h == "localhost" || h == "::1" || h.hasSuffix(".localhost") { return true }
        let parts = h.split(separator: ".").compactMap { Int($0) }
        guard parts.count == 4, h.split(separator: ".").count == 4, parts.allSatisfy({ (0...255).contains($0) }) else { return false }
        switch (parts[0], parts[1]) {
        case (127, _), (10, _), (192, 168): return true
        case (172, 16...31): return true
        case (100, 64...127): return true // Tailscale CGNAT range
        case (169, 254): return true
        default: return false
        }
    }

    /// Drops a trailing slash so paths join cleanly.
    public static func normalized(_ url: URL) -> URL {
        var text = url.absoluteString
        while text.hasSuffix("/") { text.removeLast() }
        return URL(string: text) ?? url
    }
}

/// What pairing hands back. Stored only in the Keychain.
public struct ServerCredentials: Codable, Equatable, Sendable {
    public var baseURL: URL
    public var token: String
    public var deviceId: String
    public var deviceName: String
    public var accessClientId: String?
    public var accessClientSecret: String?
    public var pairedAt: Date

    public init(baseURL: URL, token: String, deviceId: String, deviceName: String, accessClientId: String? = nil,
                accessClientSecret: String? = nil, pairedAt: Date = Date()) {
        self.baseURL = baseURL; self.token = token; self.deviceId = deviceId; self.deviceName = deviceName
        self.accessClientId = accessClientId; self.accessClientSecret = accessClientSecret; self.pairedAt = pairedAt
    }

    /// Host only, for showing "어느 맥에 붙었는지" without leaking anything secret.
    public var displayHost: String { baseURL.host ?? baseURL.absoluteString }
}

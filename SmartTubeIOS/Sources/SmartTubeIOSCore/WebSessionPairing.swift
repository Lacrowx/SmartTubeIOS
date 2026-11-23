import CryptoKit
import Foundation

/// Moves a web session (see `WebSession`) from an iPhone, iPad or Mac to an Apple TV, which has
/// no web view to sign in with. The TV listens on the local network and shows a QR code with an
/// `Invitation`; the phone opens it, asks the user, and sends the session's cookies encrypted
/// with the invitation's one-time key, which never travels over the network.
public enum WebSessionPairing {

    public enum PairingError: Error, Equatable {
        case badPayload
    }

    /// Where the TV listens, and the key for this one transfer.
    public struct Invitation: Equatable, Sendable {
        public static let urlHost = "pair-tv"

        public let host: String
        public let port: UInt16
        public let keyData: Data

        public init(host: String, port: UInt16, keyData: Data) {
            self.host = host
            self.port = port
            self.keyData = keyData
        }

        /// A new invitation with a random 256-bit key.
        public static func make(host: String, port: UInt16) -> Invitation {
            Invitation(host: host, port: port, keyData: SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) })
        }

        /// `smarttube://pair-tv?host=…&port=…&key=…` (key in base64url).
        public var url: URL {
            var components = URLComponents()
            components.scheme = "smarttube"
            components.host = Self.urlHost
            components.queryItems = [
                URLQueryItem(name: "host", value: host),
                URLQueryItem(name: "port", value: String(port)),
                URLQueryItem(name: "key", value: WebSessionPairing.base64URL(keyData)),
            ]
            return components.url ?? URL(fileURLWithPath: "/")
        }

        /// Parses an invitation URL; nil for anything else or a host outside the local network.
        public init?(url: URL) {
            guard url.scheme?.lowercased() == "smarttube", url.host?.lowercased() == Self.urlHost,
                let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
                let host = items.first(where: { $0.name == "host" })?.value,
                WebSessionPairing.isLocalNetworkHost(host),
                let port = items.first(where: { $0.name == "port" })?.value.flatMap(UInt16.init), port > 0,
                let key = items.first(where: { $0.name == "key" })?.value.flatMap(WebSessionPairing.data(base64URL:)),
                key.count == 32
            else { return nil }
            self.init(host: host, port: port, keyData: key)
        }

        var key: SymmetricKey { SymmetricKey(data: keyData) }
    }

    /// Encrypts the session cookies among `cookies` for `invitation` (AES-GCM).
    public static func seal(_ cookies: [HTTPCookie], for invitation: Invitation) throws -> Data {
        let records = WebSession.sessionCookies(cookies).map(CookieRecord.init)
        let plain = try JSONEncoder().encode(records)
        guard let combined = try AES.GCM.seal(plain, using: invitation.key).combined else {
            throw PairingError.badPayload
        }
        return combined
    }

    /// Decrypts a payload from `seal`; throws if it was not sealed for `invitation`.
    public static func open(_ payload: Data, for invitation: Invitation) throws -> [HTTPCookie] {
        let box = try AES.GCM.SealedBox(combined: payload)
        let plain = try AES.GCM.open(box, using: invitation.key)
        let records = try JSONDecoder().decode([CookieRecord].self, from: plain)
        return WebSession.sessionCookies(records.compactMap(\.cookie))
    }

    /// True for private IPv4 addresses (10/8, 172.16/12, 192.168/16, 169.254/16), so a QR code
    /// can't send a session to a host on the internet.
    public static func isLocalNetworkHost(_ host: String) -> Bool {
        let octets = host.split(separator: ".").compactMap { UInt8($0) }
        guard octets.count == 4, host.split(separator: ".").count == 4 else { return false }
        switch (octets[0], octets[1]) {
        case (10, _), (192, 168), (169, 254): return true
        case (172, 16...31): return true
        default: return false
        }
    }

    static func base64URL(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func data(base64URL text: String) -> Data? {
        var base64 = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
        return Data(base64Encoded: base64)
    }

    /// The parts of an `HTTPCookie` that travel to the TV.
    struct CookieRecord: Codable {
        let name: String
        let value: String
        let domain: String
        let path: String
        let expires: Date?
        let isSecure: Bool
        let isHTTPOnly: Bool

        init(_ cookie: HTTPCookie) {
            name = cookie.name
            value = cookie.value
            domain = cookie.domain
            path = cookie.path
            expires = cookie.expiresDate
            isSecure = cookie.isSecure
            isHTTPOnly = cookie.isHTTPOnly
        }

        var cookie: HTTPCookie? {
            var properties: [HTTPCookiePropertyKey: Any] = [
                .name: name, .value: value, .domain: domain, .path: path,
            ]
            if let expires { properties[.expires] = expires }
            if isSecure { properties[.secure] = "TRUE" }
            if isHTTPOnly { properties[HTTPCookiePropertyKey("HttpOnly")] = "TRUE" }
            return HTTPCookie(properties: properties)
        }
    }
}

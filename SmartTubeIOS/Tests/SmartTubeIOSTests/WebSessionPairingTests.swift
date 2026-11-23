import Foundation
import Testing

@testable import SmartTubeIOSCore

@Suite("WebSessionPairing")
struct WebSessionPairingTests {

    private let invitation = WebSessionPairing.Invitation.make(host: "192.168.1.20", port: 50_123)

    private func cookie(_ name: String, domain: String, httpOnly: Bool = false) throws -> HTTPCookie {
        var properties: [HTTPCookiePropertyKey: Any] = [
            .name: name, .value: "v-\(name)", .domain: domain, .path: "/", .secure: "TRUE",
            .expires: Date(timeIntervalSince1970: 2_000_000_000),
        ]
        if httpOnly { properties[HTTPCookiePropertyKey("HttpOnly")] = "TRUE" }
        return try #require(HTTPCookie(properties: properties))
    }

    @Test func invitationURLRoundTrips() {
        #expect(WebSessionPairing.Invitation(url: invitation.url) == invitation)
    }

    @Test func invitationRejectsPublicHosts() {
        let remote = WebSessionPairing.Invitation(host: "8.8.8.8", port: 80, keyData: invitation.keyData)
        #expect(WebSessionPairing.Invitation(url: remote.url) == nil)
    }

    @Test func invitationRejectsShortKeys() {
        let weak = WebSessionPairing.Invitation(host: "10.0.0.2", port: 80, keyData: Data(count: 8))
        #expect(WebSessionPairing.Invitation(url: weak.url) == nil)
    }

    @Test func localNetworkHosts() {
        #expect(WebSessionPairing.isLocalNetworkHost("10.1.2.3"))
        #expect(WebSessionPairing.isLocalNetworkHost("172.20.0.1"))
        #expect(WebSessionPairing.isLocalNetworkHost("192.168.0.5"))
        #expect(!WebSessionPairing.isLocalNetworkHost("172.32.0.1"))
        #expect(!WebSessionPairing.isLocalNetworkHost("example.com"))
        #expect(!WebSessionPairing.isLocalNetworkHost("192.168.0.5.evil.com"))
    }

    @Test func sealedCookiesOpenWithTheSameInvitation() throws {
        let cookies = [
            try cookie("SAPISID", domain: ".youtube.com"),
            try cookie("SID", domain: ".google.com", httpOnly: true),
            try cookie("IDE", domain: ".doubleclick.net"),
        ]
        let payload = try WebSessionPairing.seal(cookies, for: invitation)
        let opened = try WebSessionPairing.open(payload, for: invitation)
        #expect(opened.map(\.name) == ["SAPISID", "SID"])
        #expect(opened.last?.isHTTPOnly == true)
        #expect(opened.first?.isSecure == true)
        #expect(opened.first?.value == "v-SAPISID")
    }

    @Test func payloadDoesNotOpenWithAnotherKey() throws {
        let payload = try WebSessionPairing.seal([try cookie("SAPISID", domain: ".youtube.com")], for: invitation)
        let other = WebSessionPairing.Invitation.make(host: invitation.host, port: invitation.port)
        #expect(throws: (any Error).self) { try WebSessionPairing.open(payload, for: other) }
    }
}

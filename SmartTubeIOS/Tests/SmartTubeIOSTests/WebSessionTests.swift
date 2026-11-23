import Foundation
import Testing

@testable import SmartTubeIOSCore

@Suite("WebSession")
struct WebSessionTests {

    private func cookie(_ name: String, domain: String, value: String = "v") -> HTTPCookie {
        // Name, value, domain and path are all present, so the initializer cannot fail.
        HTTPCookie(properties: [.name: name, .value: value, .domain: domain, .path: "/"]) ?? HTTPCookie()
    }

    @Test func completeOnYouTubeWithSAPISID() {
        let cookies = [cookie("SAPISID", domain: ".youtube.com", value: "abc")]
        #expect(WebSession.isComplete(url: URL(string: "https://m.youtube.com/"), cookies: cookies))
    }

    @Test func notCompleteWhileStillOnGoogleSignIn() {
        let cookies = [cookie("SAPISID", domain: ".youtube.com")]
        #expect(!WebSession.isComplete(url: URL(string: "https://accounts.google.com/signin"), cookies: cookies))
    }

    @Test func notCompleteWithOnlyGoogleSAPISID() {
        let cookies = [cookie("SAPISID", domain: ".google.com")]
        #expect(!WebSession.isComplete(url: URL(string: "https://m.youtube.com/"), cookies: cookies))
    }

    @Test func lookalikeHostIsNotYouTube() {
        let cookies = [cookie("SAPISID", domain: ".youtube.com")]
        #expect(!WebSession.isComplete(url: URL(string: "https://notyoutube.com/"), cookies: cookies))
    }

    @Test func sessionCookiesKeepOnlyYouTubeAndGoogle() {
        let cookies = [
            cookie("SID", domain: ".google.com"),
            cookie("LOGIN_INFO", domain: ".youtube.com"),
            cookie("IDE", domain: ".doubleclick.net"),
        ]
        #expect(WebSession.sessionCookies(cookies).map(\.name) == ["SID", "LOGIN_INFO"])
    }

    @Test func authorizationHasAllThreeHashes() {
        let cookies = [
            cookie("SAPISID", domain: ".youtube.com", value: "sid"),
            cookie("__Secure-1PAPISID", domain: ".youtube.com", value: "p1"),
            cookie("__Secure-3PAPISID", domain: ".youtube.com", value: "p3"),
            cookie("SAPISID", domain: ".google.com", value: "other"),
        ]
        let header = WebSession.authorization(cookies: cookies, now: Date(timeIntervalSince1970: 1_700_000_000))
        #expect(
            header == "SAPISIDHASH 1700000000_74cf24f8fc8e15eb74dbc3bc9bbde6fa183ce16a "
                + "SAPISID1PHASH 1700000000_07743c4e7b758e943c3a6f456edc46b9008124a7 "
                + "SAPISID3PHASH 1700000000_6b7771b818e7009dda12cc1f3169be2ca5898973")
    }

    @Test func authorizationNeedsSAPISID() {
        let cookies = [cookie("__Secure-1PAPISID", domain: ".youtube.com", value: "p1")]
        #expect(WebSession.authorization(cookies: cookies) == nil)
    }

    @Test func emptySAPISIDIsIgnored() throws {
        let empty = try #require(
            HTTPCookie(properties: [.name: "SAPISID", .value: "", .domain: ".youtube.com", .path: "/"]))
        #expect(WebSession.sapisid(in: [empty]) == nil)
    }
}

import Foundation
import Testing

@testable import SmartTubeIOSCore

@Suite("WebSession")
struct WebSessionTests {

    private func cookie(_ name: String, domain: String, value: String = "v") -> HTTPCookie {
        HTTPCookie(properties: [.name: name, .value: value, .domain: domain, .path: "/"])!
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

    @Test func emptySAPISIDIsIgnored() throws {
        let empty = try #require(
            HTTPCookie(properties: [.name: "SAPISID", .value: "", .domain: ".youtube.com", .path: "/"]))
        #expect(WebSession.sapisid(in: [empty]) == nil)
    }
}

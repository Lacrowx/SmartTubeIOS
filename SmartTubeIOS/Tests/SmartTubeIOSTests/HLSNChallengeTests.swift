import Foundation
import Testing

@testable import SmartTubeIOSCore

@Suite("HLSNChallenge")
struct HLSNChallengeTests {

    private let segment = URL(
        string: "https://rr1.googlevideo.com/videoplayback/id/abc/n/SCRAMBLED_n1/rqh/1/sq/0/file/seg.ts")!

    @Test func findsAbsoluteURLLines() {
        let playlist = "#EXTM3U\n#EXTINF:5,\n\(segment.absoluteString)\n#EXT-X-ENDLIST\n"
        #expect(HLSNChallenge.urls(in: playlist) == [segment])
    }

    @Test func readsTheNValue() {
        #expect(HLSNChallenge.value(in: segment) == "SCRAMBLED_n1")
        #expect(HLSNChallenge.value(in: URL(string: "https://example.com/a/b")!) == nil)
    }

    @Test func replacesTheNValue() {
        let solved = HLSNChallenge.replacing("SCRAMBLED_n1", with: "solved", in: segment)
        #expect(solved?.absoluteString.contains("/n/solved/rqh/1/") == true)
    }

    @Test func solvesTheQueryValueOfAdaptiveURLs() throws {
        let url = try #require(URL(string: "https://rr1.googlevideo.com/videoplayback?itag=401&n=abc&rqh=1"))
        #expect(HLSNChallenge.queryValue(in: url) == "abc")
        let solved = HLSNChallenge.solvingQueryValue(in: url, with: ["abc": "xyz"])
        #expect(HLSNChallenge.queryValue(in: solved) == "xyz")
        #expect(solved.absoluteString.contains("itag=401"))
        #expect(HLSNChallenge.solvingQueryValue(in: url, with: [:]) == url)
    }
}

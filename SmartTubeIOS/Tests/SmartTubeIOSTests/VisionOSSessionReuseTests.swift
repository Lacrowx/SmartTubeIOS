import Foundation
import Testing

@testable import SmartTubeIOSCore

// MARK: - VisionOS session reuse
//
// Seeding the VisionOS session downloads YouTube's watch page, so it should happen once and
// be reused for later videos, and again only when YouTube rejects the reused session.

private final class VisionOSStubURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var watchPageLoads = 0
    nonisolated(unsafe) static var playerRequests = 0
    /// Player requests to answer with LOGIN_REQUIRED before answering normally again.
    nonisolated(unsafe) static var rejectNextPlayerRequests = 0

    static func reset() {
        watchPageLoads = 0
        playerRequests = 0
        rejectNextPlayerRequests = 0
    }

    override static func canInit(with request: URLRequest) -> Bool { true }
    override static func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else { return }
        let body: Data
        let contentType: String
        if url.path == "/watch" {
            Self.watchPageLoads += 1
            body = Data(#"<script>ytcfg.set({"VISITOR_DATA":"visitor-\#(Self.watchPageLoads)"});</script>"#.utf8)
            contentType = "text/html"
        } else {
            Self.playerRequests += 1
            let json: [String: Any]
            if Self.rejectNextPlayerRequests > 0 {
                Self.rejectNextPlayerRequests -= 1
                json = ["playabilityStatus": ["status": "LOGIN_REQUIRED", "reason": "Sign in to confirm"]]
            } else {
                json = [
                    "playabilityStatus": ["status": "OK"],
                    "streamingData": ["hlsManifestUrl": "https://example.com/master.m3u8"],
                ]
            }
            body = (try? JSONSerialization.data(withJSONObject: json)) ?? Data()
            contentType = "application/json"
        }
        guard
            let response = HTTPURLResponse(
                url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": contentType])
        else { return }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private func makeStubbedAPI() -> InnerTubeAPI {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [VisionOSStubURLProtocol.self]
    return InnerTubeAPI(authToken: nil, session: URLSession(configuration: config))
}

@Suite("VisionOS session reuse", .serialized)
struct VisionOSSessionReuseTests {

    @Test("loads the watch page once for several videos")
    func seedsOnceForSeveralVideos() async throws {
        VisionOSStubURLProtocol.reset()
        let api = makeStubbedAPI()

        _ = try await api.fetchPlayerInfoVisionOS(videoId: "video-a")
        _ = try await api.fetchPlayerInfoVisionOS(videoId: "video-b")

        #expect(VisionOSStubURLProtocol.watchPageLoads == 1)
        #expect(VisionOSStubURLProtocol.playerRequests == 2)
    }

    @Test("reseeds and retries once when YouTube rejects the reused session")
    func reseedsWhenReusedSessionIsRejected() async throws {
        VisionOSStubURLProtocol.reset()
        let api = makeStubbedAPI()
        _ = try await api.fetchPlayerInfoVisionOS(videoId: "video-a")

        VisionOSStubURLProtocol.rejectNextPlayerRequests = 1
        _ = try await api.fetchPlayerInfoVisionOS(videoId: "video-b")

        #expect(VisionOSStubURLProtocol.watchPageLoads == 2)
        #expect(VisionOSStubURLProtocol.playerRequests == 3)
        #expect(await api.currentVisitorData() == "visitor-2")
    }

    @Test("reseeds when visitorData has changed since the seed")
    func reseedsAfterVisitorDataChange() async throws {
        VisionOSStubURLProtocol.reset()
        let api = makeStubbedAPI()
        _ = try await api.fetchPlayerInfoVisionOS(videoId: "video-a")

        await api.updateVisitorData(from: ["responseContext": ["visitorData": "from-browse"]])
        _ = try await api.fetchPlayerInfoVisionOS(videoId: "video-b")

        #expect(VisionOSStubURLProtocol.watchPageLoads == 2)
    }
}

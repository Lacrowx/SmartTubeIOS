import Testing

@testable import SmartTubeIOSCore

@Suite("WebSessionRoute")
struct WebSessionRouteTests {

    @Test func webHLSNamesTheWEBClientAndItsLimit() {
        #expect(WebSessionRoute.webHLS.label == "WEB · H.264 HLS (up to 1080p)")
    }

    @Test func av1NamesMWEB() {
        #expect(WebSessionRoute.av1.label == "MWEB · AV1")
    }

    @Test func vp9SaysWhetherItIsHDR() {
        #expect(WebSessionRoute.vp9(hdr: false).label == "MWEB · VP9 (WebM → HLS)")
        #expect(WebSessionRoute.vp9(hdr: true).label == "MWEB · VP9 HDR (WebM → HLS)")
    }

    @Test func noticeSaysTheNetworkIsBlockedAndNamesTheRoute() {
        #expect(
            WebSessionRoute.vp9(hdr: true).notice
                == "Network blocked by YouTube · playing through the web session: MWEB · VP9 HDR (WebM → HLS)")
    }
}

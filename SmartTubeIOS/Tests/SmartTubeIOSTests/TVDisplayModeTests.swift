import Foundation
import Testing

@testable import SmartTubeIOSCore

// MARK: - TVDisplayModeTests
//
// tvOS Settings → Display Mode: which dynamic range the app asks the TV for.

@Suite("TV display mode")
struct TVDisplayModeTests {
    typealias Mode = AppSettings.TVDisplayMode

    @Test("defaults to matching each video and survives a round trip")
    func settingRoundTrip() throws {
        #expect(AppSettings().tvDisplayMode == .matchVideo)
        var settings = AppSettings()
        settings.tvDisplayMode = .hdr10SDRVideosInSDR
        let decoded = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(settings))
        #expect(decoded.tvDisplayMode == .hdr10SDRVideosInSDR)
        #expect(try JSONDecoder().decode(AppSettings.self, from: Data("{}".utf8)).tvDisplayMode == .matchVideo)
    }

    @Test("match each video: TV default in menus, the video's own mode while playing")
    func matchVideo() {
        #expect(Mode.matchVideo.request(videoIsHDR: nil) == .systemDefault)
        #expect(Mode.matchVideo.request(videoIsHDR: true) == .videoOwn)
        #expect(Mode.matchVideo.request(videoIsHDR: false) == .videoOwn)
    }

    @Test("HDR10 with SDR videos in SDR: only SDR videos leave HDR10")
    func hdr10SDRVideosInSDR() {
        #expect(Mode.hdr10SDRVideosInSDR.request(videoIsHDR: nil) == .hdr10)
        #expect(Mode.hdr10SDRVideosInSDR.request(videoIsHDR: true) == .hdr10)
        #expect(Mode.hdr10SDRVideosInSDR.request(videoIsHDR: false) == .sdr)
    }

    @Test("always HDR10: never leaves HDR10")
    func hdr10Always() {
        #expect(Mode.hdr10Always.request(videoIsHDR: nil) == .hdr10)
        #expect(Mode.hdr10Always.request(videoIsHDR: true) == .hdr10)
        #expect(Mode.hdr10Always.request(videoIsHDR: false) == .hdr10)
    }
}

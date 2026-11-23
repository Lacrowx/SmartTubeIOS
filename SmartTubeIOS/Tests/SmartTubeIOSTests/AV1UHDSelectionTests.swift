import Foundation
import Testing

@testable import SmartTubeIOSCore

// MARK: - AV1UHDSelectionTests
//
// tvOS "4K via AV1" opt-in: VisionOS HLS tops out at 1080p H.264 on Apple TVs without
// VP9, so the player can pick an AV1 adaptive format above 1080p instead.

@Suite("AV1 UHD selection")
struct AV1UHDSelectionTests {

    private func format(
        _ height: Int, _ mime: String, fps: Int = 30, bitrate: Int? = nil, hasURL: Bool = true
    )
        -> VideoFormat
    {
        VideoFormat(
            label: "\(height)p", width: height * 16 / 9, height: height, fps: fps, mimeType: mime,
            url: hasURL ? URL(string: "https://example.invalid/\(height)/\(mime.hashValue)") : nil,
            bitrate: bitrate)
    }

    private func info(_ formats: [VideoFormat]) -> PlayerInfo {
        PlayerInfo(
            video: Video(id: "test", title: "Test", channelTitle: "Channel"),
            formats: formats, hlsURL: nil, dashURL: nil, captionTracks: [], trackingURLs: nil, endCards: [])
    }

    private let av1 = #"video/mp4; codecs="av01.0.13M.08""#
    private let h264 = #"video/mp4; codecs="avc1.640028""#
    private let vp9 = #"video/webm; codecs="vp9""#

    @Test("picks the tallest AV1 format above 1080p")
    func picksTallestAV1() {
        let playerInfo = info([format(1080, av1), format(1440, av1), format(2160, av1), format(2160, vp9)])
        #expect(playerInfo.bestAV1UHDVideoFormat(maximumHeight: nil)?.height == 2160)
    }

    @Test("respects the quality cap")
    func respectsCap() {
        let playerInfo = info([format(1440, av1), format(2160, av1)])
        #expect(playerInfo.bestAV1UHDVideoFormat(maximumHeight: 1440)?.height == 1440)
    }

    @Test("returns nil when the cap is 1080p or lower")
    func nilAt1080Cap() {
        let playerInfo = info([format(1440, av1), format(2160, av1)])
        #expect(playerInfo.bestAV1UHDVideoFormat(maximumHeight: 1080) == nil)
    }

    @Test("returns nil without AV1 above 1080p, or without URLs")
    func nilWithoutPlayableAV1() {
        #expect(
            info([format(2160, h264), format(2160, vp9), format(1080, av1)]).bestAV1UHDVideoFormat(maximumHeight: nil)
                == nil)
        #expect(info([format(2160, av1, hasURL: false)]).bestAV1UHDVideoFormat(maximumHeight: nil) == nil)
    }

    @Test("prefers higher fps, then higher bitrate, at the same height")
    func tieBreaks() {
        let playerInfo = info([
            format(2160, av1, fps: 30, bitrate: 30_000_000),
            format(2160, av1, fps: 60, bitrate: 20_000_000),
            format(2160, av1, fps: 60, bitrate: 25_000_000),
        ])
        let best = playerInfo.bestAV1UHDVideoFormat(maximumHeight: nil)
        #expect(best?.fps == 60)
        #expect(best?.bitrate == 25_000_000)
    }

    @Test("AV1 ladder keeps one format per height from 480p up to the cap, tallest first")
    func av1Ladder() {
        let playerInfo = info([
            format(2160, av1, fps: 30), format(2160, av1, fps: 60), format(1440, av1), format(1080, av1),
            format(720, av1), format(480, av1), format(360, av1), format(2160, h264), format(1080, av1, hasURL: false),
        ])
        let ladder = playerInfo.av1VideoLadder(maximumHeight: 1440)
        #expect(ladder.map(\.height) == [1440, 1080, 720, 480])
        #expect(playerInfo.av1VideoLadder(maximumHeight: nil).first?.fps == 60)
    }
}

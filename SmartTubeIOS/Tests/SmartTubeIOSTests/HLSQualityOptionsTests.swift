import Foundation
import Testing

@testable import SmartTubeIOS
@testable import SmartTubeIOSCore

/// The quality menu of an HLS stream (`PlaybackQualityManager.hlsQualityOptions`).
@Suite("HLS quality options")
struct HLSQualityOptionsTests {
    private let variants: [Int: URL] = [
        1080: URL(string: "https://example.com/1080.m3u8")!,
        720: URL(string: "https://example.com/720.m3u8")!,
        360: URL(string: "https://example.com/360.m3u8")!,
    ]

    private func format(_ height: Int, url: Bool) -> VideoFormat {
        VideoFormat(
            label: "\(height)p", width: height * 16 / 9, height: height, fps: 30, mimeType: "video/mp4",
            url: url ? URL(string: "https://example.com/\(height).mp4") : nil)
    }

    @Test func formatsWithURLsAreFilteredToTheManifestsHeights() {
        let playable = [format(1440, url: true), format(1080, url: true), format(720, url: true)]
        let options = PlaybackQualityManager.hlsQualityOptions(
            playable: playable, response: playable, variants: variants)
        #expect(options.map(\.height) == [1080, 720])
    }

    /// Through the web session the adaptive formats are SABR-only; only the 360p muxed
    /// format has a URL. The menu must offer the stream's own qualities, not just 360p.
    @Test func sabrOnlyResponseUsesTheManifestsHeights() {
        let muxed = format(360, url: true)
        let response = [format(1080, url: false), format(720, url: false), muxed]
        let options = PlaybackQualityManager.hlsQualityOptions(
            playable: [muxed], response: response, variants: variants)
        #expect(options.map(\.height) == [1080, 720, 360])
        #expect(options.map(\.qualityLabel) == ["1080p", "720p", "360p"])
    }

    /// A 2:1 video's variants are 1920×960 and 1280×640: labelled by YouTube's tier.
    @Test func nonStandardHeightsAreLabelledByTier() {
        let response = [format(1080, url: false)]
        let wide: [Int: URL] = [
            960: URL(string: "https://example.com/960.m3u8")!,
            640: URL(string: "https://example.com/640.m3u8")!,
        ]
        let options = PlaybackQualityManager.hlsQualityOptions(playable: [], response: response, variants: wide)
        #expect(options.map(\.qualityLabel) == ["1080p", "720p"])
        #expect(options.map(\.height) == [960, 640])
    }
}

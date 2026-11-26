import Foundation
import Testing

@testable import SmartTubeIOSCore

// MARK: - OriginalAudioFormatTests
//
// Multi-language videos list one adaptive audio format per language. The tvOS AV1 path plays
// `bestAdaptiveAudioURL`, which must be the creator's original track, not a dub.

@Suite("Original audio among adaptive formats")
struct OriginalAudioFormatTests {

    /// `xtags` as YouTube sends them: base64url, no padding, protobuf around `acont=<value>`.
    private func xtags(_ acont: String) -> String {
        Data("\n\u{15}\n\u{05}acont\u{12}\u{0C}\(acont)".utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    @Test func xtagsOriginalMarksOriginal() {
        let format: [String: Any] = [
            "audioTrack": ["displayName": "English (United States)", "audioIsDefault": false],
            "xtags": xtags("original"),
        ]
        #expect(InnerTubeAPI.isOriginalAudio(format: format) == true)
    }

    @Test func xtagsDubbedMarksDub_evenWhenDefault() {
        let format: [String: Any] = [
            "audioTrack": ["displayName": "German (Germany)", "audioIsDefault": true],
            "xtags": xtags("dubbed-auto"),
        ]
        #expect(InnerTubeAPI.isOriginalAudio(format: format) == false)
    }

    @Test func displayNameOriginalMarksOriginal() {
        let format: [String: Any] = ["audioTrack": ["displayName": "English original", "audioIsDefault": false]]
        #expect(InnerTubeAPI.isOriginalAudio(format: format) == true)
    }

    @Test func fallsBackToAudioIsDefault() {
        let format: [String: Any] = ["audioTrack": ["displayName": "Spanish", "audioIsDefault": false]]
        #expect(InnerTubeAPI.isOriginalAudio(format: format) == false)
    }

    @Test func noAudioTrackMeansUnknown() {
        #expect(InnerTubeAPI.isOriginalAudio(format: ["mimeType": "audio/mp4"]) == nil)
    }

    @Test func bestAdaptiveAudioURL_prefersOriginalOverHigherBitrateDub() {
        let dub = VideoFormat(
            label: "audio", width: 0, height: 0, fps: 0, mimeType: "audio/mp4; codecs=\"mp4a.40.2\"",
            url: URL(string: "https://example.com/dub"), bitrate: 160_000, isOriginalAudio: false)
        let original = VideoFormat(
            label: "audio", width: 0, height: 0, fps: 0, mimeType: "audio/mp4; codecs=\"mp4a.40.2\"",
            url: URL(string: "https://example.com/original"), bitrate: 128_000, isOriginalAudio: true)
        let info = PlayerInfo(
            video: Video(id: "v", title: "t", channelTitle: "c"), formats: [dub, original], hlsURL: nil,
            dashURL: nil, captionTracks: [], trackingURLs: nil, endCards: [])
        #expect(info.bestAdaptiveAudioURL == URL(string: "https://example.com/original"))
    }

    @Test func bestAdaptiveAudioURL_singleLanguage_highestBitrate() {
        let low = VideoFormat(
            label: "audio", width: 0, height: 0, fps: 0, mimeType: "audio/mp4", url: URL(string: "https://example.com/low"),
            bitrate: 48_000)
        let high = VideoFormat(
            label: "audio", width: 0, height: 0, fps: 0, mimeType: "audio/mp4",
            url: URL(string: "https://example.com/high"), bitrate: 128_000)
        let info = PlayerInfo(
            video: Video(id: "v", title: "t", channelTitle: "c"), formats: [low, high], hlsURL: nil, dashURL: nil,
            captionTracks: [], trackingURLs: nil, endCards: [])
        #expect(info.bestAdaptiveAudioURL == URL(string: "https://example.com/high"))
    }
}

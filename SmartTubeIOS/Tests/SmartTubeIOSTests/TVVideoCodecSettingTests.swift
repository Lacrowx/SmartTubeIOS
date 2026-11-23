import Foundation
import Testing

@testable import SmartTubeIOSCore

// MARK: - TVVideoCodecSettingTests
//
// tvOS Settings → Video Codec: H.264 (up to 1080p), VP9 or AV1 (up to 4K).

@Suite("TV video codec setting")
struct TVVideoCodecSettingTests {

    @Test("video codec setting defaults to VP9 and survives a round trip")
    func settingRoundTrip() throws {
        #expect(AppSettings().tvVideoCodec == .vp9)
        var settings = AppSettings()
        settings.tvVideoCodec = .h264
        let decoded = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(settings))
        #expect(decoded.tvVideoCodec == .h264)
    }

    @Test("older settings without the key, or an unknown value, decode as VP9")
    func settingMissingOrUnknown() throws {
        #expect(try JSONDecoder().decode(AppSettings.self, from: Data("{}".utf8)).tvVideoCodec == .vp9)
        let unknown = Data(#"{"tvVideoCodec":"hevc"}"#.utf8)
        #expect(try JSONDecoder().decode(AppSettings.self, from: unknown).tvVideoCodec == .vp9)
    }

    @Test("H.264 and VP9: VP9 is tried only when the decoder is available")
    func vp9PlaybackOrder() {
        #expect(AppSettings.TVVideoCodec.h264.playbackOrder(vp9Supported: true).isEmpty)
        #expect(AppSettings.TVVideoCodec.vp9.playbackOrder(vp9Supported: true) == [.vp9])
        #expect(AppSettings.TVVideoCodec.vp9.playbackOrder(vp9Supported: false).isEmpty)
    }

    @Test("VP9 picker label says when H.264 plays instead")
    func vp9PickerLabels() {
        #expect(AppSettings.TVVideoCodec.h264.pickerLabel(vp9Supported: false) == "H.264 (up to 1080p)")
        #expect(AppSettings.TVVideoCodec.vp9.pickerLabel(vp9Supported: true) == "VP9 (up to 4K)")
        #expect(AppSettings.TVVideoCodec.vp9.pickerLabel(vp9Supported: false) == "VP9 (not supported, plays H.264)")
    }

    @Test("AV1 falls back to VP9, then to the regular path")
    func av1PlaybackOrder() {
        let av1 = AppSettings.TVVideoCodec.av1
        #expect(av1.playbackOrder(vp9Supported: true, av1Supported: true) == [.av1, .vp9])
        #expect(av1.playbackOrder(vp9Supported: true, av1Supported: false) == [.vp9])
        #expect(av1.playbackOrder(vp9Supported: false, av1Supported: true) == [.av1])
        #expect(av1.playbackOrder(vp9Supported: false, av1Supported: false).isEmpty)
    }

    @Test("AV1 picker label names the codec that plays instead")
    func av1PickerLabels() {
        let av1 = AppSettings.TVVideoCodec.av1
        #expect(av1.pickerLabel(vp9Supported: true, av1Supported: true) == "AV1 (up to 4K, experimental)")
        #expect(av1.pickerLabel(vp9Supported: true, av1Supported: false) == "AV1 (not supported, plays VP9)")
        #expect(av1.pickerLabel(vp9Supported: false, av1Supported: false) == "AV1 (not supported, plays H.264)")
    }

    @Test("settings saved with Prefer H.264 on and no codec choice decode as H.264")
    func migratesPreferH264() throws {
        let old = Data(#"{"preferH264":true}"#.utf8)
        #expect(try JSONDecoder().decode(AppSettings.self, from: old).tvVideoCodec == .h264)
        let chosen = Data(#"{"preferH264":true,"tvVideoCodec":"av1"}"#.utf8)
        #expect(try JSONDecoder().decode(AppSettings.self, from: chosen).tvVideoCodec == .av1)
    }

    #if os(tvOS)
    @Test("on tvOS the Video Codec choice, not the hidden toggle, sets the H.264 preference")
    func tvPrefersH264FollowsPicker() {
        var settings = AppSettings()
        settings.preferH264 = true
        settings.tvVideoCodec = .vp9
        #expect(!settings.prefersH264Formats)
        settings.preferH264 = false
        settings.tvVideoCodec = .h264
        #expect(settings.prefersH264Formats)
    }
    #endif
}

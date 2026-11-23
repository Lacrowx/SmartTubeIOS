import Foundation
import Testing

@testable import SmartTubeIOSCore

// MARK: - TVVideoCodecSettingTests
//
// tvOS Settings → Video Codec: H.264 (up to 1080p) or VP9 (up to 4K).

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

}

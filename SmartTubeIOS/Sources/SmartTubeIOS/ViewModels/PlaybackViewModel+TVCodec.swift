@preconcurrency import AVFoundation
import SmartTubeIOSCore
import os

private let playerLog = CrashlyticsLogger(category: "Player")

// tvOS-only playback of VP9 up to 4K, chosen in Settings › Playback › Video Codec.
// Runs before the regular fallback cascade in `PlaybackViewModel+Fallback.swift`.

extension PlaybackViewModel {
    #if os(tvOS)
    /// Plays `video` with the codec chosen in `settings.tvVideoCodec` before the regular
    /// path, which tops out at 1080p H.264 on Apple TV. Returns `false` to fall through.
    /// VP9 is skipped when the device can't decode it.
    func tryTVPreferredCodecPlayback(video: Video) async -> Bool {
        let choice = settings.tvVideoCodec
        let order = choice.playbackOrder(
            vp9Supported: HLSPlaybackPolicy.vp9DecoderAvailable)
        if order.first != choice, choice != .h264 {
            playerLog.notice(
                "[VisionOS] \(choice.rawValue) not decodable on this device — trying \(order.map(\.rawValue))")
        }
        for codec in order {
            switch codec {
            case .vp9:
                if await tryVP9UHDPlayback(video: video) { return true }
            case .h264:
                break
            }
        }
        return false
    }

    /// VP9: YouTube's VisionOS HLS stream; attemptURL's HLS policy keeps its VP9 variants
    /// whenever the Video Codec choice is not H.264 and the VP9 decoder is available.
    private func tryVP9UHDPlayback(video: Video) async -> Bool {
        guard let info = try? await api.fetchPlayerInfoVisionOS(videoId: video.id) else {
            playerLog.notice("[VisionOS/VP9] player request failed — falling back")
            return false
        }
        if await tryAllStreams(video: video, info: info, label: "VisionOS", skipMuxed: true) { return true }
        playerLog.notice("[VisionOS/VP9] failed — falling back")
        return false
    }
    #endif
}

@preconcurrency import AVFoundation
import SmartTubeIOSCore
import os

private let playerLog = CrashlyticsLogger(category: "Player")

// tvOS-only playback of VP9/AV1 up to 4K, chosen in Settings › Playback › Video Codec.
// Runs before the regular fallback cascade in `PlaybackViewModel+Fallback.swift`.

extension PlaybackViewModel {
    #if os(tvOS)
    /// Plays `video` with the codec chosen in `settings.tvVideoCodec` before the regular
    /// path, which tops out at 1080p H.264 on Apple TV. Returns `false` to fall through.
    /// Codecs the device can't decode are skipped: AV1 falls back to VP9, VP9 to the regular path.
    func tryTVPreferredCodecPlayback(video: Video) async -> Bool {
        let choice = settings.tvVideoCodec
        let order = choice.playbackOrder(
            vp9Supported: HLSPlaybackPolicy.vp9DecoderAvailable,
            av1Supported: HLSPlaybackPolicy.av1DecoderAvailable)
        if order.first != choice, choice != .h264 {
            playerLog.notice(
                "[VisionOS] \(choice.rawValue) not decodable on this device — trying \(order.map(\.rawValue))")
        }
        for codec in order {
            switch codec {
            case .av1:
                if await tryAV1UHDPlayback(video: video) { return true }
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

    /// AV1 choice of `settings.tvVideoCodec`. On Apple TVs without VP9 every HLS
    /// manifest YouTube serves tops out at 1080p H.264, but the VisionOS client's adaptive
    /// formats include AV1 up to 2160p. AVURLAsset opens those fragmented-MP4 files slowly
    /// and the CDN throttles requests over ~10 MB, so instead each file's `sidx` index is
    /// turned into an HLS playlist of byte ranges (`DASHToHLS`) that AVPlayer plays natively,
    /// with every AV1 height as a variant for ABR. Returns `false` to fall back to VP9 or the
    /// regular path.
    private func tryAV1UHDPlayback(video: Video) async -> Bool {
        guard let info = try? await api.fetchPlayerInfoVisionOS(videoId: video.id) else {
            playerLog.notice("[VisionOS/AV1] player request failed — falling back")
            return false
        }
        let cap = effectiveQuality.maxHeight
        let ladder = info.av1VideoLadder(maximumHeight: cap)
        guard info.bestAV1UHDVideoFormat(maximumHeight: cap) != nil,
            let audioURL = info.bestAdaptiveAudioURL,
            let audio = info.formats.first(where: { $0.url == audioURL }),
            let audioCodec = DASHToHLS.codecs(fromMimeType: audio.mimeType)
        else {
            playerLog.notice("[VisionOS/AV1] no AV1 above 1080p for \(video.id) — falling back")
            return false
        }

        // Fetch each file's init + sidx (first 256 KB) in parallel.
        let urls = ladder.compactMap(\.url) + [audioURL]
        let indexes = await withTaskGroup(of: (URL, DASHSegmentIndex?).self) { group in
            for url in urls {
                group.addTask { (url, await Self.fetchDASHIndex(url)) }
            }
            var result: [URL: DASHSegmentIndex] = [:]
            for await (url, index) in group { result[url] = index }
            return result
        }
        guard let audioIndex = indexes[audioURL] else {
            playerLog.notice("[VisionOS/AV1] audio index unavailable — falling back")
            return false
        }
        var playlists = ["audio.m3u8": DASHToHLS.mediaPlaylist(url: audioURL, index: audioIndex)]
        var variants: [DASHToHLS.Variant] = []
        for format in ladder {
            guard let url = format.url, let index = indexes[url],
                let codecs = DASHToHLS.codecs(fromMimeType: format.mimeType)
            else { continue }
            let name = "video\(format.height).m3u8"
            playlists[name] = DASHToHLS.mediaPlaylist(url: url, index: index)
            variants.append(
                DASHToHLS.Variant(
                    uri: name, codecs: codecs,
                    width: format.width > 0 ? format.width : format.height * 16 / 9, height: format.height,
                    frameRate: format.fps, peakBitrate: index.peakBitrate, averageBitrate: index.averageBitrate))
        }
        guard variants.contains(where: { $0.height > 1080 }) else {
            playerLog.notice("[VisionOS/AV1] UHD index unavailable — falling back")
            return false
        }
        playlists["master.m3u8"] = DASHToHLS.multivariantPlaylist(
            variants: variants, audioURI: "audio.m3u8", audioCodec: audioCodec,
            audioPeakBitrate: audioIndex.peakBitrate, audioAverageBitrate: audioIndex.averageBitrate)
        playerLog.notice(
            "[VisionOS/AV1] DASH→HLS variants=\(variants.map(\.height)) audio=\(audio.mimeType) segments=\(audioIndex.segments.count)"
        )

        let loader = InMemoryPlaylistLoader(playlists: playlists)
        guard let asset = loader.makeAsset(multivariantName: "master.m3u8") else { return false }
        av1PlaylistLoader = loader
        playerInfo = info
        availableCaptions = info.captionTracks
        autoApplyCaptionPreference(tracks: info.captionTracks)
        lastAttemptedStreamURL = ladder.first?.url
        if await playPreparedItem(AVPlayerItem(asset: asset), for: video, info: info, label: "VisionOS/AV1") {
            // Quality menu = the AV1 variants in the playlist; picking one caps this item's
            // ABR in place (`PlaybackQualityManager.selectFormat(_:inPlace:)`).
            availableFormats = ladder.filter { format in variants.contains { $0.height == format.height } }
            return true
        }
        av1PlaylistLoader = nil
        playerLog.notice("[VisionOS/AV1] failed — falling back")
        return false
    }

    /// Reads the init section and `sidx` index from the start of a DASH file.
    nonisolated private static func fetchDASHIndex(_ url: URL) async -> DASHSegmentIndex? {
        var request = URLRequest(url: url, timeoutInterval: 5)
        request.setValue(InnerTubeClients.VisionOS.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("bytes=0-262143", forHTTPHeaderField: "Range")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
            let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode)
        else { return nil }
        return DASHSegmentIndex.parse(data)
    }
    #endif
}

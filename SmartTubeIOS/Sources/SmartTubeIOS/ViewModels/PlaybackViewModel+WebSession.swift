import AVFoundation
import Foundation
import SmartTubeIOSCore
import os

private let webSessionLog = Logger(subsystem: appSubsystem, category: "WebSessionPlayback")

// MARK: - Playback through the web session
//
// When YouTube answers "Sign in to confirm you're not a bot", a web session (cookies from a
// sign-in on YouTube's website, see `WebSession`) still gets streams: a WEB `/player` request
// with the session's full auth returns an HLS manifest. Its segments need the `n` parameter
// solved (`NChallengeSolver`), which `YTHLSProxyLoader` rewrites into every playlist.

extension PlaybackViewModel {

    /// Fetches `videoId` through the web session and prepares its HLS stream, or returns nil
    /// when there is no web session or the stream can't be prepared (the caller then reports
    /// the original block). Sets `webSessionNChallenge` on success.
    func playerInfoThroughWebSession(videoId: String) async -> PlayerInfo? {
        guard let sapisid = WebSession.storedSAPISID() else { return nil }
        webSessionLog.notice("bot check: trying the web session for \(videoId, privacy: .public)")
        await api.setSAPISID(sapisid)
        do {
            let player = try await NChallengeSolver.shared.currentPlayer()
            let info = try await api.fetchPlayerInfoWebSafari(
                videoId: videoId, signatureTimestamp: player.signatureTimestamp)
            guard let manifest = info.hlsURL else {
                webSessionLog.error("web session: no HLS manifest")
                return nil
            }
            webSessionNChallenge = try await WebSessionHLS.prepare(manifest: manifest, player: player)
            webSessionTallestFormat = info.formats.filter { $0.mimeType.hasPrefix("video/") }
                .map { $0.width > 0 ? min($0.width, $0.height) : $0.height }.max()
            webSessionLog.notice("web session: stream ready for \(videoId, privacy: .public)")
            return info
        } catch {
            webSessionLog.error("web session failed: \(String(describing: error), privacy: .public)")
            return nil
        }
    }

    /// After YouTube's bot check: MWEB through the web session, with every format's `n`
    /// solved, for the tvOS AV1 UHD path (the WEB response's AV1/VP9 formats are SABR-only).
    /// Nil without a web session or when the files can't be prepared.
    func adaptivePlayerInfoThroughWebSession(videoId: String) async -> PlayerInfo? {
        if let cached = webSessionAdaptive, cached.videoId == videoId { return cached.info }
        let info = await fetchAdaptivePlayerInfoThroughWebSession(videoId: videoId)
        webSessionAdaptive = (videoId, info)
        return info
    }

    private func fetchAdaptivePlayerInfoThroughWebSession(videoId: String) async -> PlayerInfo? {
        guard let sapisid = WebSession.storedSAPISID() else { return nil }
        await api.setSAPISID(sapisid)
        do {
            let player = try await NChallengeSolver.shared.currentPlayer()
            let info = try await api.fetchPlayerInfoMWEBWebSession(
                videoId: videoId, signatureTimestamp: player.signatureTimestamp)
            let solutions = try await NChallengeSolver.shared.solve(info.nChallenges, player: player)
            let solved = info.solvingNChallenges(solutions)
            // The CDN refuses fresh URLs for a moment; wait until the top file is served.
            if let top = solved.av1VideoLadder(maximumHeight: nil).first?.url {
                guard (200..<300).contains(await WebSessionHLS.waitUntilServed(top)) else { return nil }
            }
            webSessionLog.notice("web session: adaptive formats ready for \(videoId, privacy: .public)")
            return solved
        } catch {
            webSessionLog.error("web session adaptive failed: \(String(describing: error), privacy: .public)")
            return nil
        }
    }

    #if os(tvOS)
    /// Testing only: `--uitesting-force-vp9-remux` treats the player request and the VP9
    /// path's VisionOS request as bot-checked and skips AV1, so the blocked-network flow and
    /// the WebM path run on any network.
    static var forcesWebMRemux: Bool {
        #if DEBUG
        ProcessInfo.processInfo.arguments.contains("--uitesting-force-vp9-remux")
        #else
        false
        #endif
    }

    /// After a bot check: plays the web session's VP9 WebM files above 1080p through
    /// `WebMRemuxServer`, HDR (`vp9.2`) when the display can show it. Returns false to fall back.
    func tryWebMRemuxPlayback(video: Video, info: PlayerInfo) async -> Bool {
        let cap = effectiveQuality.maxHeight
        let hdrLadder = info.vp9VideoLadder(hdr: true, maximumHeight: cap)
        let wantsHDR = AVPlayer.eligibleForHDRPlayback && hdrLadder.contains { $0.height > 1080 }
        if wantsHDR, await playWebM(video: video, info: info, ladder: hdrLadder, hdr: true) { return true }
        return await playWebM(
            video: video, info: info, ladder: info.vp9VideoLadder(hdr: false, maximumHeight: cap), hdr: false)
    }

    private func playWebM(video: Video, info: PlayerInfo, ladder: [VideoFormat], hdr: Bool) async -> Bool {
        let label = hdr ? "WebSession/VP9 HDR" : "WebSession/VP9"
        // The audio rendition is played from MP4 byte ranges (DASHToHLS reads MP4 indexes only).
        let audio = info.formats.filter { $0.mimeType.hasPrefix("audio/mp4") && $0.url != nil }
            .max { ($0.bitrate ?? 0) < ($1.bitrate ?? 0) }
        guard ladder.contains(where: { $0.height > 1080 }), let audio else {
            webSessionLog.notice("[\(label, privacy: .public)] no VP9 above 1080p or no MP4 audio")
            return false
        }
        guard
            let server = await WebMRemuxServer.prepare(
                ladder: ladder, hdr: hdr, audio: audio, userAgent: InnerTubeClients.MWEB.userAgent),
            let playlistURL = await server.start(atSeconds: savedPositionToRestore)
        else {
            webSessionLog.error("[\(label, privacy: .public)] server could not start")
            return false
        }
        webMRemuxServer?.stop()
        webMRemuxServer = server
        playerInfo = info
        availableCaptions = info.captionTracks
        autoApplyCaptionPreference(tracks: info.captionTracks)
        lastAttemptedStreamURL = ladder.first?.url
        // The playlist already starts at the resume position (EXT-X-START); no seek afterwards.
        let resumePosition = savedPositionToRestore
        savedPositionToRestore = nil
        let item = AVPlayerItem(url: playlistURL)
        if await playPreparedItem(item, for: video, info: info, label: label) {
            availableFormats = ladder.filter { format in server.variants.contains { $0.format.height == format.height }
            }
            return true
        }
        server.stop()
        webMRemuxServer = nil
        savedPositionToRestore = resumePosition
        webSessionLog.notice("[\(label, privacy: .public)] failed")
        return false
    }
    #endif

    /// An asset for `manifest` that loads its playlists through `YTHLSProxyLoader` with the
    /// solved `n`, or nil when the current stream didn't come through the web session.
    func webSessionAsset(for manifest: URL) -> AVURLAsset? {
        guard let challenge = webSessionNChallenge, let proxied = manifest.proxyURL else { return nil }
        let loader = YTHLSProxyLoader(ua: WebSessionHLS.userAgent, nSolver: challenge)
        let asset = AVURLAsset(url: proxied)
        // AVAssetResourceLoader requires a dispatch queue for its delegate.
        asset.resourceLoader.setDelegate(loader, queue: DispatchQueue.global(qos: .userInitiated))
        webSessionHLSLoader = loader
        return asset
    }
}

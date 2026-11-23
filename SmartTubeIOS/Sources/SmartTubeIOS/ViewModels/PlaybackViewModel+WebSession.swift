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

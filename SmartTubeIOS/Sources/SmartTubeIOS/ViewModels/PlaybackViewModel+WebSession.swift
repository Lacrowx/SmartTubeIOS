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

/// InMemoryPlaylistLoader.swift
/// Serves app-generated HLS playlists (see `DASHToHLS`) to AVFoundation. Only playlists go
/// through here; the media segments they list stay https:// byte ranges that AVPlayer
/// fetches natively (AVAssetResourceLoader cannot serve HLS segment data).

import AVFoundation
import Foundation

final class InMemoryPlaylistLoader: NSObject, AVAssetResourceLoaderDelegate, @unchecked Sendable {
    static let scheme = "ytlocalhls"

    /// Playlist name → contents, e.g. `"master.m3u8"`. Immutable after init.
    private let playlists: [String: Data]

    init(playlists: [String: String]) {
        self.playlists = playlists.mapValues { Data($0.utf8) }
    }

    /// `ytlocalhls://playlist/<name>`
    static func url(for name: String) -> URL? {
        URL(string: "\(scheme)://playlist/\(name)")
    }

    func makeAsset(multivariantName: String) -> AVURLAsset? {
        guard let url = Self.url(for: multivariantName) else { return nil }
        let asset = AVURLAsset(url: url)
        asset.resourceLoader.setDelegate(self, queue: .global(qos: .userInitiated))
        return asset
    }

    func resourceLoader(
        _ resourceLoader: AVAssetResourceLoader,
        shouldWaitForLoadingOfRequestedResource loadingRequest: AVAssetResourceLoadingRequest
    ) -> Bool {
        guard let url = loadingRequest.request.url, url.scheme == Self.scheme,
            let data = playlists[url.lastPathComponent]
        else { return false }
        if let info = loadingRequest.contentInformationRequest {
            // UTI, not MIME — a MIME type here fails with CoreMediaErrorDomain -12881.
            info.contentType = "public.m3u-playlist"
            info.contentLength = Int64(data.count)
            info.isByteRangeAccessSupported = false
        }
        loadingRequest.dataRequest?.respond(with: data)
        loadingRequest.finishLoading()
        return true
    }
}

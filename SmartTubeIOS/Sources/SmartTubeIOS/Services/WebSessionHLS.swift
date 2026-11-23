import Foundation
import SmartTubeIOSCore
import os

private let webHLSLog = Logger(subsystem: appSubsystem, category: "WebSessionHLS")

/// Prepares an HLS stream from a web-session `/player` response (see `WebSession`) for
/// AVPlayer: finds the scrambled `n` its segments carry, solves it with `NChallengeSolver`,
/// and waits until the CDN serves a segment with the solved value (`waitUntilServed`). Observed: right after the
/// `/player` response the CDN still answers 403 for about 1.5 s, then 200.
enum WebSessionHLS {

    enum PrepareError: Error {
        case playlist(String)
        case segmentRefused(Int)
    }

    /// The user agent of the WEB client that signed the stream URLs.
    static let userAgent = InnerTubeClients.WebSafari.userAgent

    private static let session = URLSession(configuration: .ephemeral)
    private static let readinessAttempts = 8
    private static let readinessInterval: Duration = .milliseconds(750)

    /// Returns the `n` pair for `YTHLSProxyLoader` once a segment with the solved value loads.
    static func prepare(manifest: URL, player: YouTubePlayerScript) async throws -> (unsolved: String, solved: String) {
        let manifestText = try await text(of: manifest)
        guard let variant = HLSNChallenge.urls(in: manifestText).last else { throw PrepareError.playlist("no variant") }
        let variantPlaylist = try await text(of: variant)
        guard let segment = HLSNChallenge.urls(in: variantPlaylist).first,
            let unsolved = HLSNChallenge.value(in: segment)
        else { throw PrepareError.playlist("no segment with n") }

        let solutions = try await NChallengeSolver.shared.solve([unsolved], player: player)
        guard let solved = solutions[unsolved],
            let solvedSegment = HLSNChallenge.replacing(unsolved, with: solved, in: segment)
        else { throw PrepareError.playlist("n not solved") }

        let status = await waitUntilServed(solvedSegment)
        guard (200..<300).contains(status) else { throw PrepareError.segmentRefused(status) }
        return (unsolved, solved)
    }

    /// Requests the first bytes of `url` until the CDN serves them (2xx) or the attempts run
    /// out; returns the last HTTP status.
    static func waitUntilServed(_ url: URL) async -> Int {
        var status = 0
        for attempt in 1...readinessAttempts {
            status = await statusCode(of: url)
            if (200..<300).contains(status) {
                webHLSLog.notice("served after \(attempt) attempt(s)")
                return status
            }
            try? await Task.sleep(for: readinessInterval)
        }
        webHLSLog.error("still refused: HTTP \(status)")
        return status
    }

    private static func request(for url: URL) -> URLRequest {
        var request = URLRequest(url: url, timeoutInterval: 15)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        return request
    }

    private static func text(of url: URL) async throws -> String {
        let (data, response) = try await session.data(for: request(for: url))
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200, let text = String(bytes: data, encoding: .utf8) else {
            throw PrepareError.playlist("HTTP \(status) for \(url.lastPathComponent)")
        }
        return text
    }

    private static func statusCode(of segment: URL) async -> Int {
        var request = request(for: segment)
        request.setValue("bytes=0-1023", forHTTPHeaderField: "Range")
        guard let (_, response) = try? await session.data(for: request) else { return 0 }
        return (response as? HTTPURLResponse)?.statusCode ?? 0
    }
}

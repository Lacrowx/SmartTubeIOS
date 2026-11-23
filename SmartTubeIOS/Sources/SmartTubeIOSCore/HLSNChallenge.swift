import Foundation

/// The scrambled `n` parameter in YouTube HLS URLs: a `/n/{value}/` path segment that is the
/// same in every playlist and segment URL of one stream. The CDN refuses segments until it is
/// replaced with the solved value.
public enum HLSNChallenge {

    /// The absolute URL lines of an HLS playlist (variants of a master, segments of a variant).
    public static func urls(in playlist: String) -> [URL] {
        playlist.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.hasPrefix("https://") }
            .compactMap(URL.init(string:))
    }

    /// The `n` value in `url`'s path, if any.
    public static func value(in url: URL) -> String? {
        let parts = url.path.split(separator: "/")
        guard let index = parts.firstIndex(of: "n"), index + 1 < parts.count else { return nil }
        let value = parts[index + 1]
        return value.isEmpty ? nil : String(value)
    }

    /// `url` with its `n` value replaced by `solved`.
    public static func replacing(_ unsolved: String, with solved: String, in url: URL) -> URL? {
        URL(string: url.absoluteString.replacingOccurrences(of: "/n/\(unsolved)/", with: "/n/\(solved)/"))
    }
}

// MARK: - Adaptive stream URLs

extension HLSNChallenge {

    /// The `n` query value of an adaptive (non-HLS) stream URL.
    public static func queryValue(in url: URL) -> String? {
        URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "n" }?.value
    }

    /// `url` with its `n` query value replaced by its entry in `solutions`, or `url` unchanged.
    public static func solvingQueryValue(in url: URL, with solutions: [String: String]) -> URL {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false),
            let items = components.queryItems,
            let unsolved = items.first(where: { $0.name == "n" })?.value,
            let solved = solutions[unsolved]
        else { return url }
        components.queryItems = items.map { $0.name == "n" ? URLQueryItem(name: "n", value: solved) : $0 }
        return components.url ?? url
    }
}

extension PlayerInfo {

    /// The distinct `n` challenges in the formats' adaptive URLs.
    public var nChallenges: [String] {
        Array(Set(formats.compactMap { $0.url.flatMap(HLSNChallenge.queryValue(in:)) }))
    }

    /// A copy whose format URLs carry the solved `n` values.
    public func solvingNChallenges(_ solutions: [String: String]) -> PlayerInfo {
        let solvedFormats = formats.map { format in
            var format = format
            format.url = format.url.map { HLSNChallenge.solvingQueryValue(in: $0, with: solutions) }
            return format
        }
        return PlayerInfo(
            video: video, formats: solvedFormats, hlsURL: hlsURL, dashURL: dashURL, captionTracks: captionTracks,
            trackingURLs: trackingURLs, endCards: endCards)
    }
}

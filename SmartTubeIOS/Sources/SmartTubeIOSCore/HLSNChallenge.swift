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

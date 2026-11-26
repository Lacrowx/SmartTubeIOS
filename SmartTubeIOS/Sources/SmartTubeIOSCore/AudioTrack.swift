import Foundation

// MARK: - AudioTrack

/// A single audio rendition from an HLS manifest, exposed via AVMediaSelectionGroup.
/// AVMediaSelectionOption itself is not Sendable, so we snapshot the data we need
/// into this struct at load time; the actual option is kept in PlaybackViewModel.
public struct AudioTrack: Identifiable, Hashable, Sendable {
    /// BCP 47 language tag from the HLS rendition (e.g. "en", "es-419", "fr").
    public let id: String
    /// Localised display name (e.g. "English", "Spanish", "French").
    public let name: String
    /// ISO 639-1 / BCP 47 language code — same value as `id` for #EXT-X-MEDIA tracks.
    public let languageCode: String
    /// `true` when this is the HLS `DEFAULT=YES` rendition (the original audio).
    public let isOriginal: Bool
    /// The `YT-EXT-AUDIO-CONTENT-ID` value used to filter HLS variants via the proxy.
    /// `nil` for tracks sourced from `#EXT-X-MEDIA` groups (AVMediaSelectionGroup path)
    /// and for the synthetic "Original" entry added when the original-audio variant
    /// lacks a `YT-EXT-AUDIO-CONTENT-ID` attribute. When `nil`, the proxy keeps
    /// variants that have *no* `YT-EXT-AUDIO-CONTENT-ID` (i.e. the original stream).
    public let contentID: String?

    public init(
        id: String, name: String, languageCode: String, isOriginal: Bool,
        contentID: String? = nil
    ) {
        self.id = id
        self.name = name
        self.languageCode = languageCode
        self.isOriginal = isOriginal
        self.contentID = contentID
    }
}

// MARK: - Picker order

public extension Array where Element == AudioTrack {
    /// Audio picker order: the original track, then English, then German, then the rest by name.
    func sortedForPicker() -> [AudioTrack] {
        func rank(_ track: AudioTrack) -> Int {
            if track.isOriginal { return 0 }
            let base = track.languageCode.components(separatedBy: "-").first?.lowercased() ?? ""
            switch base {
            case "en": return 1
            case "de": return 2
            default: return 3
            }
        }
        return sorted {
            (rank($0), $0.name.localizedLowercase) < (rank($1), $1.name.localizedLowercase)
        }
    }
}

// MARK: - Auto-selection

public extension AudioTrack {
    /// The track a video starts with. Every video starts in its original language. The Settings
    /// language (`preferredLanguage`) is only a fallback for when no track is marked original;
    /// then English, then the first track. The device language is deliberately not used: on a
    /// German Apple TV it picked German AI dubs.
    static func autoSelect(from tracks: [AudioTrack], preferredLanguage: String?) -> AudioTrack? {
        if let original = tracks.first(where: \.isOriginal) { return original }
        if let lang = preferredLanguage, lang != "original" {
            let base = lang.components(separatedBy: "-").first ?? lang
            if let match = tracks.first(where: { $0.languageCode == lang })
                ?? tracks.first(where: { $0.languageCode.hasPrefix(base) })
            {
                return match
            }
        }
        return tracks.first(where: { $0.languageCode == "en" || $0.languageCode.hasPrefix("en-") })
            ?? tracks.first
    }
}

import Foundation

/// How the current video plays after YouTube bot-checked the network and the stream came
/// through the web session (`WebSession`). Shown to the user so a blocked network is visible.
public enum WebSessionRoute: Sendable, Equatable {
    /// The WEB client's H.264 HLS stream, which tops out at 1080p.
    case webHLS
    /// MWEB's AV1 formats, played as HLS byte ranges.
    case av1
    /// MWEB's VP9 WebM files, repackaged to fragmented-MP4 HLS.
    case vp9(hdr: Bool)

    /// Client and stream, e.g. `MWEB · VP9 HDR (WebM → HLS)`.
    public var label: String {
        switch self {
        case .webHLS: "WEB · H.264 HLS (up to 1080p)"
        case .av1: "MWEB · AV1"
        case .vp9(let hdr): "MWEB · VP9\(hdr ? " HDR" : "") (WebM → HLS)"
        }
    }

    /// The message shown when playback starts on this route.
    public var notice: String {
        "Network blocked by YouTube · playing through the web session: \(label)"
    }
}

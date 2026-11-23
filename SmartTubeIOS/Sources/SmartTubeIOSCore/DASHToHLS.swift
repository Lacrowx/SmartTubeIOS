import Foundation

// MARK: - DASH → HLS
//
// YouTube's adaptive formats are fragmented MP4 files: `ftyp` + `moov` (init), a `sidx`
// index listing every fragment's byte size and duration, then `moof`/`mdat` fragments.
// AVURLAsset opens these slowly (it walks the fragments) and the CDN throttles single
// requests over ~10 MB, but AVPlayer plays them well as HLS: an `EXT-X-MAP` byte range
// for the init section plus one `EXT-X-BYTERANGE` segment per `sidx` entry, all pointing
// at the original googlevideo URL. Used for the tvOS "4K via AV1" opt-in.

/// Byte layout of one fragmented-MP4 adaptive file, parsed from its first bytes.
public struct DASHSegmentIndex: Equatable, Sendable {
    public struct Segment: Equatable, Sendable {
        public let offset: Int64
        public let length: Int64
        public let duration: Double
    }

    /// Length of `ftyp` + `moov`, i.e. the HLS `EXT-X-MAP` byte range `initLength@0`.
    public let initLength: Int64
    public let segments: [Segment]

    /// Peak segment bitrate in bits per second (HLS `BANDWIDTH`).
    public var peakBitrate: Int {
        Int(segments.map { Double($0.length) * 8 / max($0.duration, 0.001) }.max() ?? 0)
    }

    /// Average bitrate in bits per second (HLS `AVERAGE-BANDWIDTH`).
    public var averageBitrate: Int {
        let seconds = segments.reduce(0) { $0 + $1.duration }
        let bytes = segments.reduce(Int64(0)) { $0 + $1.length }
        return seconds > 0 ? Int(Double(bytes) * 8 / seconds) : 0
    }

    /// Parses top-level boxes from the start of the file until the `sidx` box.
    /// Returns `nil` when `moov` or a complete `sidx` is not inside `data`.
    public static func parse(_ data: Data) -> DASHSegmentIndex? {
        let bytes = [UInt8](data)
        var offset = 0
        var initLength: Int64?
        while offset + 8 <= bytes.count {
            var size = Int(bytes.u32(at: offset))
            let type = String(bytes: bytes[offset + 4..<offset + 8], encoding: .ascii) ?? ""
            var headerLength = 8
            if size == 1 {
                guard offset + 16 <= bytes.count else { return nil }
                size = Int(bytes.u64(at: offset + 8))
                headerLength = 16
            }
            guard size >= headerLength else { return nil }
            switch type {
            case "moov":
                initLength = Int64(offset + size)
            case "sidx":
                guard let initLength, offset + size <= bytes.count else { return nil }
                return parseSidx(
                    bytes, body: offset + headerLength, boxEnd: Int64(offset + size), initLength: initLength)
            case "moof", "mdat":
                return nil
            default:
                break
            }
            offset += size
        }
        return nil
    }

    private static func parseSidx(_ bytes: [UInt8], body: Int, boxEnd: Int64, initLength: Int64) -> DASHSegmentIndex? {
        let version = bytes[body]
        let timescale = Double(bytes.u32(at: body + 8))
        guard timescale > 0 else { return nil }
        var cursor = body + 12
        let firstOffset: Int64
        if version == 0 {
            firstOffset = Int64(bytes.u32(at: cursor + 4))
            cursor += 8
        } else {
            firstOffset = Int64(bytes.u64(at: cursor + 8))
            cursor += 16
        }
        let count = Int(UInt16(bytes[cursor + 2]) << 8 | UInt16(bytes[cursor + 3]))
        cursor += 4
        guard cursor + count * 12 <= bytes.count else { return nil }
        var segments: [Segment] = []
        segments.reserveCapacity(count)
        var position = boxEnd + firstOffset
        for _ in 0..<count {
            let length = Int64(bytes.u32(at: cursor) & 0x7FFF_FFFF)
            let duration = Double(bytes.u32(at: cursor + 4)) / timescale
            segments.append(Segment(offset: position, length: length, duration: duration))
            position += length
            cursor += 12
        }
        return segments.isEmpty ? nil : DASHSegmentIndex(initLength: initLength, segments: segments)
    }
}

/// Builds HLS playlists over byte ranges of DASH files.
public enum DASHToHLS {
    public struct Variant: Sendable {
        public let uri: String
        public let codecs: String
        public let width: Int
        public let height: Int
        public let frameRate: Int
        public let peakBitrate: Int
        public let averageBitrate: Int
        /// HLS `VIDEO-RANGE` (`SDR`, `PQ`, `HLG`); derived from `codecs` by default.
        public let videoRange: String

        public init(
            uri: String, codecs: String, width: Int, height: Int, frameRate: Int, peakBitrate: Int,
            averageBitrate: Int, videoRange: String? = nil
        ) {
            self.uri = uri
            self.codecs = codecs
            self.width = width
            self.height = height
            self.frameRate = frameRate
            self.peakBitrate = peakBitrate
            self.averageBitrate = averageBitrate
            self.videoRange = videoRange ?? DASHToHLS.videoRange(fromCodecs: codecs)
        }
    }

    /// HLS `VIDEO-RANGE` from an AV1/VP9 codec string's transfer characteristics:
    /// `av01.P.LLT.DD.M.CCC.cp.tc.mc.F` / `vp09.PP.LL.DD.CC.cp.tc.mc.FF` (`tc` 16 = PQ, 18 = HLG).
    /// Short forms such as `av01.0.12M.08` carry no colour info and are SDR.
    public static func videoRange(fromCodecs codecs: String) -> String {
        let parts = codecs.split(separator: ".").map(String.init)
        let transferIndex: Int
        switch parts.first {
        case "av01": transferIndex = 7
        case "vp09": transferIndex = 6
        default: return "SDR"
        }
        guard parts.count > transferIndex else { return "SDR" }
        switch Int(parts[transferIndex]) {
        case 16: return "PQ"
        case 18: return "HLG"
        default: return "SDR"
        }
    }

    /// VOD media playlist for one DASH file.
    public static func mediaPlaylist(url: URL, index: DASHSegmentIndex) -> String {
        let target = Int((index.segments.map(\.duration).max() ?? 1).rounded(.up))
        var lines = [
            "#EXTM3U",
            "#EXT-X-VERSION:7",
            "#EXT-X-TARGETDURATION:\(target)",
            "#EXT-X-PLAYLIST-TYPE:VOD",
            "#EXT-X-INDEPENDENT-SEGMENTS",
            "#EXT-X-MAP:URI=\"\(url.absoluteString)\",BYTERANGE=\"\(index.initLength)@0\"",
        ]
        for segment in index.segments {
            lines.append("#EXTINF:\(String(format: "%.5f", segment.duration)),")
            lines.append("#EXT-X-BYTERANGE:\(segment.length)@\(segment.offset)")
            lines.append(url.absoluteString)
        }
        lines.append("#EXT-X-ENDLIST")
        return lines.joined(separator: "\n") + "\n"
    }

    /// Multivariant (master) playlist: video variants sharing one audio rendition.
    public static func multivariantPlaylist(
        variants: [Variant], audioURI: String, audioCodec: String, audioPeakBitrate: Int, audioAverageBitrate: Int
    ) -> String {
        var lines = [
            "#EXTM3U",
            "#EXT-X-VERSION:7",
            "#EXT-X-INDEPENDENT-SEGMENTS",
            "#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID=\"aud\",NAME=\"Original\",DEFAULT=YES,AUTOSELECT=YES,URI=\"\(audioURI)\"",
        ]
        for variant in variants.sorted(by: { $0.height > $1.height }) {
            lines.append(
                "#EXT-X-STREAM-INF:BANDWIDTH=\(variant.peakBitrate + audioPeakBitrate),"
                    + "AVERAGE-BANDWIDTH=\(variant.averageBitrate + audioAverageBitrate),"
                    + "CODECS=\"\(variant.codecs),\(audioCodec)\",RESOLUTION=\(variant.width)x\(variant.height),"
                    + "FRAME-RATE=\(variant.frameRate),VIDEO-RANGE=\(variant.videoRange),AUDIO=\"aud\"")
            lines.append(variant.uri)
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// Extracts the `codecs="…"` value from a YouTube mimeType, e.g. `av01.0.12M.08`.
    public static func codecs(fromMimeType mimeType: String) -> String? {
        guard let start = mimeType.range(of: "codecs=\"") else { return nil }
        let rest = mimeType[start.upperBound...]
        guard let end = rest.firstIndex(of: "\"") else { return nil }
        let value = rest[..<end].trimmingCharacters(in: .whitespaces)
        return value.isEmpty ? nil : value
    }
}

extension [UInt8] {
    fileprivate func u32(at index: Int) -> UInt32 {
        UInt32(self[index]) << 24 | UInt32(self[index + 1]) << 16 | UInt32(self[index + 2]) << 8
            | UInt32(self[index + 3])
    }

    fileprivate func u64(at index: Int) -> UInt64 {
        UInt64(u32(at: index)) << 32 | UInt64(u32(at: index + 4))
    }
}

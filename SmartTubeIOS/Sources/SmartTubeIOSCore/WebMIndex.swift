import Foundation

// MARK: - EBML

/// One EBML element header (Matroska / WebM): its ID, where its data starts and its size
/// (`nil` for "unknown size").
struct EBMLElement: Equatable {
    let id: UInt32
    let dataStart: Int
    let size: Int?
    var end: Int? { size.map { dataStart + $0 } }

    /// Reads the element header at `position`; nil when it doesn't fit in `bytes`.
    static func read(_ bytes: [UInt8], at position: Int) -> EBMLElement? {
        guard let (id, idLength) = vint(bytes, at: position, maxLength: 4, keepMarker: true),
            let (size, sizeLength) = vint(bytes, at: position + idLength, maxLength: 8, keepMarker: false)
        else { return nil }
        let unknown = size == (UInt64(1) << (7 * UInt64(sizeLength))) - 1
        return EBMLElement(
            id: UInt32(id), dataStart: position + idLength + sizeLength, size: unknown ? nil : Int(size))
    }

    private static func vint(_ bytes: [UInt8], at position: Int, maxLength: Int, keepMarker: Bool) -> (UInt64, Int)? {
        guard position < bytes.count, bytes[position] != 0 else { return nil }
        let first = bytes[position]
        let length = first.leadingZeroBitCount + 1
        guard length <= maxLength, position + length <= bytes.count else { return nil }
        var value = UInt64(keepMarker ? first : first & (0xFF >> length))
        for offset in 1..<length { value = value << 8 | UInt64(bytes[position + offset]) }
        return (value, length)
    }

    func unsigned(_ bytes: [UInt8]) -> UInt64 {
        guard let end, end <= bytes.count else { return 0 }
        return bytes[dataStart..<end].reduce(0) { $0 << 8 | UInt64($1) }
    }

    func float(_ bytes: [UInt8]) -> Double {
        let bits = unsigned(bytes)
        switch size {
        case 4: return Double(Float(bitPattern: UInt32(truncatingIfNeeded: bits)))
        case 8: return Double(bitPattern: bits)
        default: return 0
        }
    }

    /// The child elements, as far as they lie within `bytes`.
    func children(_ bytes: [UInt8]) -> [EBMLElement] {
        var result: [EBMLElement] = []
        var position = dataStart
        let limit = min(end ?? bytes.count, bytes.count)
        while position < limit, let child = EBMLElement.read(bytes, at: position), let next = child.end {
            result.append(child)
            position = next
        }
        return result
    }
}

// MARK: - WebM index

/// What a YouTube WebM file's header says: timing, video size and colour, and the cue points
/// (one per cluster, each starting with a key frame), which become HLS segments.
public struct WebMIndex: Equatable, Sendable {
    public struct Cue: Equatable, Sendable {
        public let timeMs: Int64
        /// Byte offset of the cluster, relative to the start of the Segment's data.
        public let position: Int64
    }

    /// Matroska `Colour` values (ISO/IEC 23091-2 codes); nil when the file has none.
    public struct Colour: Equatable, Sendable {
        public var bitsPerChannel: Int?
        public var matrixCoefficients: Int?
        public var transferCharacteristics: Int?
        public var primaries: Int?
        /// Matroska `Range`: 1 broadcast (limited), 2 full.
        public var range: Int?
    }

    public enum ParseResult: Equatable, Sendable {
        case complete(WebMIndex)
        /// The header continues past the bytes given; fetch at least this many from offset 0.
        case needsBytes(Int)
        case invalid
    }

    public var segmentDataStart: Int64 = 0
    public var timecodeScale: UInt64 = 1_000_000
    public var durationMs: Int64 = 0
    public var width = 0
    public var height = 0
    public var colour: Colour?
    public var cues: [Cue] = []

    /// One HLS segment per cue point: absolute byte range (the last one is open-ended) and time.
    public struct Segment: Equatable, Sendable {
        public let start: Int64
        /// Last byte, inclusive; nil for the last segment (up to the end of the file).
        public let end: Int64?
        public let startMs: Int64
        public let endMs: Int64
        public var durationSeconds: Double { Double(endMs - startMs) / 1000 }
    }

    public var segments: [Segment] {
        cues.indices.map { cueIndex in
            let cue = cues[cueIndex]
            let next = cueIndex + 1 < cues.count ? cues[cueIndex + 1] : nil
            return Segment(
                start: segmentDataStart + cue.position,
                end: next.map { segmentDataStart + $0.position - 1 },
                startMs: cue.timeMs,
                endMs: next?.timeMs ?? max(durationMs, cue.timeMs + 1))
        }
    }

    /// Parses the header (EBML, Segment, Info, Tracks, Cues) from the start of a WebM file.
    /// YouTube's files keep their Cues before the first Cluster.
    public static func parse(_ bytes: [UInt8]) -> ParseResult {
        guard let ebml = EBMLElement.read(bytes, at: 0), ebml.id == 0x1A45_DFA3, let segmentStart = ebml.end,
            let segment = EBMLElement.read(bytes, at: segmentStart), segment.id == 0x1853_8067
        else { return bytes.count < 64 ? .needsBytes(64 * 1024) : .invalid }
        var index = WebMIndex()
        index.segmentDataStart = Int64(segment.dataStart)
        var position = segment.dataStart
        while true {
            guard let element = EBMLElement.read(bytes, at: position) else { return .needsBytes(position + 64 * 1024) }
            if element.id == 0x1F43_B675 { break }  // first Cluster: header done
            guard let end = element.end else { return .invalid }
            if end > bytes.count { return .needsBytes(end + 1024) }
            switch element.id {
            case 0x1549_A966: index.readInfo(bytes, element)
            case 0x1654_AE6B: index.readTracks(bytes, element)
            case 0x1C53_BB6B: index.readCues(bytes, element)
            default: break
            }
            position = end
        }
        return index.cues.isEmpty || index.width == 0 ? .invalid : .complete(index)
    }

    private mutating func readInfo(_ bytes: [UInt8], _ info: EBMLElement) {
        var duration: Double = 0
        for child in info.children(bytes) {
            if child.id == 0x2A_D7B1 { timecodeScale = child.unsigned(bytes) }
            if child.id == 0x4489 { duration = child.float(bytes) }
        }
        durationMs = Int64(duration * Double(timecodeScale) / 1_000_000)
    }

    private mutating func readTracks(_ bytes: [UInt8], _ tracks: EBMLElement) {
        for entry in tracks.children(bytes) where entry.id == 0xAE {
            for video in entry.children(bytes) where video.id == 0xE0 {
                for field in video.children(bytes) {
                    switch field.id {
                    case 0xB0: width = Int(field.unsigned(bytes))
                    case 0xBA: height = Int(field.unsigned(bytes))
                    case 0x55B0: colour = Self.colour(bytes, field)
                    default: break
                    }
                }
            }
        }
    }

    private static func colour(_ bytes: [UInt8], _ element: EBMLElement) -> Colour {
        var colour = Colour()
        for field in element.children(bytes) {
            let value = Int(field.unsigned(bytes))
            switch field.id {
            case 0x55B1: colour.matrixCoefficients = value
            case 0x55B2: colour.bitsPerChannel = value
            case 0x55B9: colour.range = value
            case 0x55BA: colour.transferCharacteristics = value
            case 0x55BB: colour.primaries = value
            default: break
            }
        }
        return colour
    }

    private mutating func readCues(_ bytes: [UInt8], _ element: EBMLElement) {
        for point in element.children(bytes) where point.id == 0xBB {
            var time: UInt64 = 0
            var position: UInt64?
            for field in point.children(bytes) {
                if field.id == 0xB3 { time = field.unsigned(bytes) }
                if field.id == 0xB7 {
                    for track in field.children(bytes) where track.id == 0xF1 { position = track.unsigned(bytes) }
                }
            }
            if let position {
                cues.append(Cue(timeMs: Int64(time * timecodeScale / 1_000_000), position: Int64(position)))
            }
        }
    }
}

// MARK: - Frames

/// A video frame from a WebM cluster (a VP9 superframe counts as one frame).
public struct WebMFrame: Sendable {
    public let timeMs: Int64
    public let isKey: Bool
    public let data: ArraySlice<UInt8>
}

extension WebMIndex {
    /// The frames of every Cluster in `bytes`, which must start at a Cluster element.
    public func frames(inClusters bytes: [UInt8]) -> [WebMFrame] {
        var frames: [WebMFrame] = []
        var position = 0
        while let cluster = EBMLElement.read(bytes, at: position), let end = cluster.end, end <= bytes.count {
            defer { position = end }
            guard cluster.id == 0x1F43_B675 else { continue }
            var clusterTime: Int64 = 0
            for child in cluster.children(bytes) {
                switch child.id {
                case 0xE7:
                    clusterTime = Int64(child.unsigned(bytes))
                case 0xA3:
                    if let frame = block(bytes, child, clusterTime: clusterTime, isKey: nil) { frames.append(frame) }
                case 0xA0:  // BlockGroup: a key frame unless it references another block
                    let parts = child.children(bytes)
                    let references = parts.contains { $0.id == 0xFB }
                    for part in parts where part.id == 0xA1 {
                        if let frame = block(bytes, part, clusterTime: clusterTime, isKey: !references) {
                            frames.append(frame)
                        }
                    }
                default:
                    break
                }
            }
        }
        return frames
    }

    private func block(_ bytes: [UInt8], _ element: EBMLElement, clusterTime: Int64, isKey: Bool?) -> WebMFrame? {
        guard let end = element.end, end <= bytes.count, element.dataStart < end else { return nil }
        let trackLength = bytes[element.dataStart].leadingZeroBitCount + 1
        let header = element.dataStart + trackLength
        guard trackLength <= 8, header + 3 <= end else { return nil }
        let relative = Int16(bitPattern: UInt16(bytes[header]) << 8 | UInt16(bytes[header + 1]))
        let flags = bytes[header + 2]
        guard flags & 0x06 == 0 else { return nil }  // laced blocks don't occur in YouTube video
        let ticks = clusterTime + Int64(relative)
        return WebMFrame(
            timeMs: ticks * Int64(timecodeScale) / 1_000_000,
            isKey: isKey ?? (flags & 0x80 != 0),
            data: bytes[(header + 3)..<end])
    }
}

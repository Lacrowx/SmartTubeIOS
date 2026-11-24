import Foundation

/// The VP9 stream properties an MP4 `vpcC` box and an HLS `CODECS` string carry.
public struct VP9Configuration: Equatable, Sendable {
    public var profile: UInt8
    public var level: UInt8
    public var bitDepth: UInt8
    /// 1 = 4:2:0 co-located with luma (YouTube's VP9).
    public var chromaSubsampling: UInt8 = 1
    public var fullRange: Bool = false
    public var primaries: UInt8
    public var transfer: UInt8
    public var matrix: UInt8

    /// From a WebM header: profile 2 / 10-bit when the file says 10 bits or `hdr` is set,
    /// colour from its `Colour` element, otherwise BT.709 (SDR) or BT.2020 PQ (HDR).
    public init(index: WebMIndex, hdr: Bool) {
        let colour = index.colour
        let tenBit = hdr || (colour?.bitsPerChannel ?? 8) > 8
        profile = tenBit ? 2 : 0
        bitDepth = tenBit ? 10 : 8
        level = Self.level(width: index.width, height: index.height)
        fullRange = colour?.range == 2
        primaries = UInt8(colour?.primaries ?? (hdr ? 9 : 1))
        transfer = UInt8(colour?.transferCharacteristics ?? (hdr ? 16 : 1))
        matrix = UInt8(colour?.matrixCoefficients ?? (hdr ? 9 : 1))
    }

    /// VP9 level (×10) for a frame size at up to 60 fps.
    static func level(width: Int, height: Int) -> UInt8 {
        switch width * height {
        case ...(1280 * 720): return 31
        case ...(1920 * 1080): return 41
        case ...(2560 * 1440): return 50
        default: return 51
        }
    }

    /// HLS / RFC 6381 codec string, e.g. `vp09.00.51.08` or `vp09.02.51.10.01.09.16.09.00`.
    public var codecString: String {
        let base = String(format: "vp09.%02d.%02d.%02d", profile, level, bitDepth)
        guard profile != 0 || bitDepth != 8 || transfer != 1 else { return base }
        return base
            + String(format: ".%02d.%02d.%02d.%02d.%02d", chromaSubsampling, primaries, transfer, matrix, fullRange ? 1 : 0)
    }
}

/// Writes fragmented MP4 (CMAF-style) for one VP9 video track: an init segment and media
/// segments (`moof` + `mdat`) built from WebM frames. Times are in milliseconds.
public enum FragmentedMP4 {

    public static func vp9InitSegment(width: Int, height: Int, configuration config: VP9Configuration) -> [UInt8] {
        var ftyp = Writer()
        ftyp.fourcc("iso6")
        ftyp.u32(0)
        for brand in ["iso6", "iso5", "mp41"] { ftyp.fourcc(brand) }

        var mvhd = Writer()
        mvhd.u32(0)
        mvhd.u32(0)
        mvhd.u32(timescale)
        mvhd.u32(0)
        mvhd.u32(0x0001_0000)
        mvhd.u16(0x0100)
        mvhd.zeros(10)
        mvhd.matrix()
        mvhd.zeros(24)
        mvhd.u32(2)

        var tkhd = Writer()
        tkhd.zeros(8)
        tkhd.u32(trackID)
        tkhd.zeros(4 + 4 + 8)
        tkhd.zeros(8)  // layer, alternate group, volume, reserved
        tkhd.matrix()
        tkhd.u32(UInt32(width) << 16)
        tkhd.u32(UInt32(height) << 16)

        var mdhd = Writer()
        mdhd.zeros(8)
        mdhd.u32(timescale)
        mdhd.u32(0)
        mdhd.u16(0x55C4)  // "und"
        mdhd.u16(0)

        var hdlr = Writer()
        hdlr.u32(0)
        hdlr.fourcc("vide")
        hdlr.zeros(12)
        hdlr.bytes += Array("VideoHandler".utf8) + [0]

        var dref = Writer()
        dref.u32(1)
        dref.bytes += fullBox("url ", flags: 1, [])

        var stsd = Writer()
        stsd.u32(1)
        stsd.bytes += box("vp09", vp09SampleEntry(width: width, height: height, configuration: config))

        let emptyTable: [UInt8] = [0, 0, 0, 0]
        let stbl = box(
            "stbl",
            fullBox("stsd", stsd.bytes) + fullBox("stts", emptyTable) + fullBox("stsc", emptyTable)
                + fullBox("stsz", [0, 0, 0, 0, 0, 0, 0, 0]) + fullBox("stco", emptyTable))
        let minf = box("minf", fullBox("vmhd", flags: 1, [UInt8](repeating: 0, count: 8)) + box("dinf", fullBox("dref", dref.bytes)) + stbl)
        let mdia = box("mdia", fullBox("mdhd", mdhd.bytes) + fullBox("hdlr", hdlr.bytes) + minf)
        let trak = box("trak", fullBox("tkhd", flags: 3, tkhd.bytes) + mdia)

        var trex = Writer()
        trex.u32(trackID)
        trex.u32(1)
        trex.zeros(12)
        let mvex = box("mvex", fullBox("trex", trex.bytes))
        return box("ftyp", ftyp.bytes) + box("moov", fullBox("mvhd", mvhd.bytes) + trak + mvex)
    }

    /// `vp09` VisualSampleEntry with its `vpcC` and `colr` (nclx) boxes.
    static func vp09SampleEntry(width: Int, height: Int, configuration config: VP9Configuration) -> [UInt8] {
        var vpcC = Writer()
        vpcC.u8(config.profile)
        vpcC.u8(config.level)
        vpcC.u8(config.bitDepth << 4 | config.chromaSubsampling << 1 | (config.fullRange ? 1 : 0))
        vpcC.u8(config.primaries)
        vpcC.u8(config.transfer)
        vpcC.u8(config.matrix)
        vpcC.u16(0)

        var colr = Writer()
        colr.fourcc("nclx")
        colr.u16(UInt16(config.primaries))
        colr.u16(UInt16(config.transfer))
        colr.u16(UInt16(config.matrix))
        colr.u8(config.fullRange ? 0x80 : 0)

        var vp09 = Writer()
        vp09.zeros(6)
        vp09.u16(1)  // data reference index
        vp09.zeros(16)
        vp09.u16(UInt16(width))
        vp09.u16(UInt16(height))
        vp09.u32(0x0048_0000)
        vp09.u32(0x0048_0000)
        vp09.u32(0)
        vp09.u16(1)
        vp09.zeros(32)
        vp09.u16(0x0018)
        vp09.u16(0xFFFF)
        vp09.bytes += fullBox("vpcC", version: 1, vpcC.bytes) + box("colr", colr.bytes)

        return vp09.bytes
    }

    /// A `moof` + `mdat` for `frames` (decode order). The last frame lasts until `endMs`.
    public static func mediaSegment(sequence: UInt32, frames: [WebMFrame], endMs: Int64) -> [UInt8] {
        guard let first = frames.first else { return [] }
        func moof(dataOffset: Int32) -> [UInt8] {
            var mfhd = Writer()
            mfhd.u32(sequence)
            var tfhd = Writer()
            tfhd.u32(trackID)
            var tfdt = Writer()
            tfdt.u64(UInt64(max(0, first.timeMs)))
            var trun = Writer()
            trun.u32(UInt32(frames.count))
            trun.u32(UInt32(bitPattern: dataOffset))
            for (position, frame) in frames.enumerated() {
                let next = position + 1 < frames.count ? frames[position + 1].timeMs : endMs
                trun.u32(UInt32(clamping: max(1, next - frame.timeMs)))
                trun.u32(UInt32(frame.data.count))
                trun.u32(frame.isKey ? 0x0200_0000 : 0x0101_0000)
            }
            // tfhd: default-base-is-moof; trun: data offset + per-sample duration, size, flags.
            let traf = box(
                "traf",
                fullBox("tfhd", flags: 0x02_0000, tfhd.bytes) + fullBox("tfdt", version: 1, tfdt.bytes)
                    + fullBox("trun", flags: 0x00_0701, trun.bytes))
            return box("moof", fullBox("mfhd", mfhd.bytes) + traf)
        }
        let moofSize = moof(dataOffset: 0).count
        var mdat: [UInt8] = []
        mdat.reserveCapacity(frames.reduce(0) { $0 + $1.data.count })
        for frame in frames { mdat += frame.data }
        return moof(dataOffset: Int32(moofSize + 8)) + box("mdat", mdat)
    }

    static let timescale: UInt32 = 1000
    static let trackID: UInt32 = 1

    static func box(_ type: String, _ content: [UInt8]) -> [UInt8] {
        var writer = Writer()
        writer.u32(UInt32(8 + content.count))
        writer.fourcc(type)
        return writer.bytes + content
    }

    static func fullBox(_ type: String, version: UInt8 = 0, flags: UInt32 = 0, _ content: [UInt8]) -> [UInt8] {
        box(type, [version, UInt8(flags >> 16 & 0xFF), UInt8(flags >> 8 & 0xFF), UInt8(flags & 0xFF)] + content)
    }

    struct Writer {
        var bytes: [UInt8] = []
        mutating func u8(_ value: UInt8) { bytes.append(value) }
        mutating func u16(_ value: UInt16) { bytes += [UInt8(value >> 8), UInt8(value & 0xFF)] }
        mutating func u32(_ value: UInt32) {
            bytes += [UInt8(value >> 24), UInt8(value >> 16 & 0xFF), UInt8(value >> 8 & 0xFF), UInt8(value & 0xFF)]
        }
        mutating func u64(_ value: UInt64) {
            u32(UInt32(value >> 32))
            u32(UInt32(value & 0xFFFF_FFFF))
        }
        mutating func zeros(_ count: Int) { bytes += [UInt8](repeating: 0, count: count) }
        mutating func fourcc(_ code: String) { bytes += Array(code.utf8) }
        mutating func matrix() {
            for value: UInt32 in [0x0001_0000, 0, 0, 0, 0x0001_0000, 0, 0, 0, 0x4000_0000] { u32(value) }
        }
    }
}

extension PlayerInfo {
    /// WebM VP9 formats with a URL, one per height (highest frame rate, then bitrate), tallest
    /// first: SDR (`vp9`) or, with `hdr`, HDR (`vp9.2`).
    public func vp9VideoLadder(hdr: Bool, minimumHeight: Int = 480, maximumHeight: Int?) -> [VideoFormat] {
        let codec = hdr ? "\"vp9.2\"" : "\"vp9\""
        let candidates = formats.filter {
            $0.mimeType.hasPrefix("video/webm") && $0.mimeType.contains(codec) && $0.url != nil
                && $0.height >= minimumHeight && $0.height <= (maximumHeight ?? .max)
        }
        return Dictionary(grouping: candidates, by: \.height).values
            .compactMap { group in group.max { ($0.fps, $0.bitrate ?? 0) < ($1.fps, $1.bitrate ?? 0) } }
            .sorted { $0.height > $1.height }
    }
}

import Foundation
import Testing

@testable import SmartTubeIOSCore

// MARK: - DASHToHLSTests
//
// The tvOS "4K via AV1" path turns a YouTube DASH file's `sidx` index into an HLS playlist
// of byte ranges. Fixture layout mirrors a real file: ftyp, moov, sidx, then moof.

@Suite("DASH → HLS")
struct DASHToHLSTests {

    private func box(_ type: String, _ body: [UInt8]) -> [UInt8] {
        be32(UInt32(8 + body.count)) + Array(type.utf8) + body
    }

    private func be32(_ value: UInt32) -> [UInt8] {
        [UInt8(value >> 24), UInt8(value >> 16 & 0xFF), UInt8(value >> 8 & 0xFF), UInt8(value & 0xFF)]
    }
    private func be64(_ value: UInt64) -> [UInt8] { be32(UInt32(value >> 32)) + be32(UInt32(value & 0xFFFF_FFFF)) }

    /// sidx with `refs` = [(size, duration)] at `timescale`.
    private func sidx(version: UInt8, timescale: UInt32, firstOffset: UInt32, refs: [(UInt32, UInt32)]) -> [UInt8] {
        var body: [UInt8] = [version, 0, 0, 0] + be32(1) + be32(timescale)
        body += version == 0 ? be32(0) + be32(firstOffset) : be64(0) + be64(UInt64(firstOffset))
        body += [0, 0, UInt8(refs.count >> 8), UInt8(refs.count & 0xFF)]
        for (size, duration) in refs { body += be32(size) + be32(duration) + be32(0x9000_0000) }
        return box("sidx", body)
    }

    private struct SampleFile {
        let data: Data
        let initLength: Int
        let sidxEnd: Int
    }

    private func file(version: UInt8 = 0, firstOffset: UInt32 = 0) -> SampleFile {
        let ftyp = box("ftyp", Array("dash".utf8) + be32(0))
        let moov = box("moov", [UInt8](repeating: 0, count: 40))
        let index = sidx(
            version: version, timescale: 1000, firstOffset: firstOffset,
            refs: [(1000, 5000), (2000, 5000), (500, 2500)])
        let bytes = ftyp + moov + index + box("moof", [])
        return SampleFile(
            data: Data(bytes), initLength: ftyp.count + moov.count, sidxEnd: ftyp.count + moov.count + index.count)
    }

    @Test("parses init length and contiguous segment byte ranges")
    func parsesIndex() throws {
        let sample = file()
        let data = sample.data
        let initLength = sample.initLength
        let sidxEnd = sample.sidxEnd
        let index = try #require(DASHSegmentIndex.parse(data))
        #expect(index.initLength == Int64(initLength))
        #expect(index.segments.map(\.offset) == [Int64(sidxEnd), Int64(sidxEnd + 1000), Int64(sidxEnd + 3000)])
        #expect(index.segments.map(\.length) == [1000, 2000, 500])
        #expect(index.segments.map(\.duration) == [5, 5, 2.5])
    }

    @Test("honours sidx version 1 and first_offset")
    func parsesVersion1() throws {
        let sample = file(version: 1, firstOffset: 16)
        let data = sample.data
        let sidxEnd = sample.sidxEnd
        let index = try #require(DASHSegmentIndex.parse(data))
        #expect(index.segments.first?.offset == Int64(sidxEnd + 16))
    }

    @Test("returns nil when the sidx is cut off or missing")
    func rejectsIncomplete() {
        let sample = file()
        let data = sample.data
        let sidxEnd = sample.sidxEnd
        #expect(DASHSegmentIndex.parse(data.prefix(sidxEnd - 4)) == nil)
        let noSidx = Data(box("ftyp", []) + box("moov", []) + box("moof", []))
        #expect(DASHSegmentIndex.parse(noSidx) == nil)
    }

    @Test("bitrates come from segment sizes and durations")
    func bitrates() throws {
        let index = try #require(DASHSegmentIndex.parse(file().data))
        #expect(index.peakBitrate == 3200)  // 2000 B over 5 s
        #expect(index.averageBitrate == 2240)  // 3500 B × 8 over 12.5 s
    }

    @Test("media playlist maps init and every segment as byte ranges of the source URL")
    func mediaPlaylist() throws {
        let sample = file()
        let data = sample.data
        let initLength = sample.initLength
        let sidxEnd = sample.sidxEnd
        let index = try #require(DASHSegmentIndex.parse(data))
        let url = try #require(URL(string: "https://example.invalid/videoplayback?itag=401&a=b"))
        let text = DASHToHLS.mediaPlaylist(url: url, index: index)
        #expect(text.hasPrefix("#EXTM3U\n#EXT-X-VERSION:7\n#EXT-X-TARGETDURATION:5\n"))
        #expect(text.contains("#EXT-X-MAP:URI=\"\(url.absoluteString)\",BYTERANGE=\"\(initLength)@0\""))
        #expect(text.contains("#EXTINF:5.00000,\n#EXT-X-BYTERANGE:1000@\(sidxEnd)\n\(url.absoluteString)"))
        #expect(text.contains("#EXT-X-BYTERANGE:500@\(sidxEnd + 3000)"))
        #expect(text.hasSuffix("#EXT-X-ENDLIST\n"))
    }

    @Test("master playlist lists variants tallest first with combined bandwidth and audio group")
    func multivariantPlaylist() throws {
        let variants = [
            DASHToHLS.Variant(
                uri: "video1080.m3u8", codecs: "av01.0.09M.08", width: 1920, height: 1080, frameRate: 30,
                peakBitrate: 4_000_000, averageBitrate: 3_000_000),
            DASHToHLS.Variant(
                uri: "video2160.m3u8", codecs: "av01.0.12M.08", width: 3840, height: 2160, frameRate: 30,
                peakBitrate: 20_000_000, averageBitrate: 15_000_000),
        ]
        let text = DASHToHLS.multivariantPlaylist(
            variants: variants, audioURI: "audio.m3u8", audioCodec: "mp4a.40.2",
            audioPeakBitrate: 130_000, audioAverageBitrate: 128_000)
        #expect(
            text.contains("TYPE=AUDIO,GROUP-ID=\"aud\",NAME=\"Original\",DEFAULT=YES,AUTOSELECT=YES,URI=\"audio.m3u8\"")
        )
        let uhd = try #require(text.range(of: "RESOLUTION=3840x2160"))
        let fhd = try #require(text.range(of: "RESOLUTION=1920x1080"))
        #expect(uhd.lowerBound < fhd.lowerBound)
        #expect(text.contains("BANDWIDTH=20130000,AVERAGE-BANDWIDTH=15128000,CODECS=\"av01.0.12M.08,mp4a.40.2\""))
    }

    @Test("codecs are read from a YouTube mimeType")
    func codecsFromMime() {
        #expect(DASHToHLS.codecs(fromMimeType: #"video/mp4; codecs="av01.0.12M.08""#) == "av01.0.12M.08")
        #expect(DASHToHLS.codecs(fromMimeType: #"audio/mp4; codecs="mp4a.40.2""#) == "mp4a.40.2")
        #expect(DASHToHLS.codecs(fromMimeType: "video/mp4") == nil)
    }
}

import Foundation
import Testing

@testable import SmartTubeIOSCore

@Suite("WebM to fragmented MP4")
struct WebMRemuxTests {

    // MARK: Synthetic WebM

    /// EBML element with an 8-byte size field (fixed width keeps offsets predictable).
    private func element(_ id: [UInt8], _ payload: [UInt8]) -> [UInt8] {
        var size: [UInt8] = [0x01]
        for shift in stride(from: 48, through: 0, by: -8) { size.append(UInt8(payload.count >> shift & 0xFF)) }
        return id + size + payload
    }

    private func uint(_ id: [UInt8], _ value: UInt32) -> [UInt8] {
        element(id, [UInt8(value >> 24), UInt8(value >> 16 & 0xFF), UInt8(value >> 8 & 0xFF), UInt8(value & 0xFF)])
    }

    private func simpleBlock(relativeMs: Int16, key: Bool, data: [UInt8]) -> [UInt8] {
        let time = UInt16(bitPattern: relativeMs)
        return element([0xA3], [0x81, UInt8(time >> 8), UInt8(time & 0xFF), key ? 0x80 : 0x00] + data)
    }

    private func cluster(timecode: UInt32, blocks: [[UInt8]]) -> [UInt8] {
        element([0x1F, 0x43, 0xB6, 0x75], uint([0xE7], timecode) + blocks.flatMap { $0 })
    }

    /// 3840×2160, 10-bit PQ colour, two cues (0 ms and 5000 ms), 10 s long.
    private func webM(hdrColour: Bool = true) -> (bytes: [UInt8], firstClusterOffset: Int) {
        let durationBits = Double(10_000).bitPattern
        let duration = (0..<8).map { UInt8(durationBits >> (56 - 8 * $0) & 0xFF) }
        let info = element(
            [0x15, 0x49, 0xA9, 0x66], uint([0x2A, 0xD7, 0xB1], 1_000_000) + element([0x44, 0x89], duration))
        var video = uint([0xB0], 3840) + uint([0xBA], 2160)
        if hdrColour {
            video += element(
                [0x55, 0xB0],
                uint([0x55, 0xB2], 10) + uint([0x55, 0xBA], 16) + uint([0x55, 0xBB], 9) + uint([0x55, 0xB1], 9))
        }
        let tracks = element([0x16, 0x54, 0xAE, 0x6B], element([0xAE], element([0xE0], video)))
        let clusterA = cluster(
            timecode: 0,
            blocks: [simpleBlock(relativeMs: 0, key: true, data: [1, 2, 3]), simpleBlock(relativeMs: 40, key: false, data: [4, 5])])
        let clusterB = cluster(timecode: 5000, blocks: [simpleBlock(relativeMs: 0, key: true, data: [6])])
        func cues(_ first: UInt32, _ second: UInt32) -> [UInt8] {
            func point(_ time: UInt32, _ position: UInt32) -> [UInt8] {
                element([0xBB], uint([0xB3], time) + element([0xB7], uint([0xF7], 1) + uint([0xF1], position)))
            }
            return element([0x1C, 0x53, 0xBB, 0x6B], point(0, first) + point(5000, second))
        }
        let headerLength = info.count + tracks.count + cues(0, 0).count
        let cuesElement = cues(UInt32(headerLength), UInt32(headerLength + clusterA.count))
        let segmentPayload = info + tracks + cuesElement + clusterA + clusterB
        let ebml = element([0x1A, 0x45, 0xDF, 0xA3], [])
        let segment = element([0x18, 0x53, 0x80, 0x67], segmentPayload)
        let segmentDataStart = ebml.count + 12
        return (ebml + segment, segmentDataStart + headerLength)
    }

    private func index(_ bytes: [UInt8]) throws -> WebMIndex {
        guard case .complete(let index) = WebMIndex.parse(bytes) else {
            Issue.record("WebM header did not parse")
            throw CancellationError()
        }
        return index
    }

    // MARK: WebM

    @Test func parsesHeaderCuesAndColour() throws {
        let (bytes, firstCluster) = webM()
        let index = try index(bytes)
        #expect(index.width == 3840 && index.height == 2160)
        #expect(index.durationMs == 10_000)
        #expect(index.colour == WebMIndex.Colour(bitsPerChannel: 10, matrixCoefficients: 9, transferCharacteristics: 16, primaries: 9))
        #expect(index.segments.map(\.startMs) == [0, 5000])
        #expect(index.segments.map(\.endMs) == [5000, 10_000])
        #expect(index.segments.first?.start == Int64(firstCluster))
        #expect(index.segments.last?.end == nil)
    }

    @Test func asksForMoreBytesWhenTheHeaderIsCut() {
        let (bytes, _) = webM()
        guard case .needsBytes = WebMIndex.parse(Array(bytes.prefix(80))) else {
            Issue.record("expected needsBytes")
            return
        }
    }

    @Test func readsFramesFromClusters() throws {
        let (bytes, firstCluster) = webM()
        let frames = try index(bytes).frames(inClusters: Array(bytes[firstCluster...]))
        #expect(frames.map(\.timeMs) == [0, 40, 5000])
        #expect(frames.map(\.isKey) == [true, false, true])
        #expect(frames.map { Array($0.data) } == [[1, 2, 3], [4, 5], [6]])
    }

    // MARK: VP9 configuration

    @Test func hdrConfigurationFromColour() throws {
        let configuration = VP9Configuration(index: try index(webM().bytes), hdr: true)
        #expect(configuration.codecString == "vp09.02.51.10.01.09.16.09.00")
    }

    @Test func sdrConfigurationWithoutColour() throws {
        let configuration = VP9Configuration(index: try index(webM(hdrColour: false).bytes), hdr: false)
        #expect(configuration.codecString == "vp09.00.51.08")
    }

    // MARK: Fragmented MP4

    private func boxes(_ bytes: [UInt8]) -> [(type: String, size: Int)] {
        var result: [(String, Int)] = []
        var position = 0
        while position + 8 <= bytes.count {
            let size = bytes[position..<position + 4].reduce(0) { $0 << 8 | Int($1) }
            let type = String(bytes: bytes[position + 4..<position + 8], encoding: .ascii) ?? "?"
            guard size >= 8 else { break }
            result.append((type, size))
            position += size
        }
        return result
    }

    @Test func initSegmentIsFtypThenMoovWithVP9Boxes() throws {
        let configuration = VP9Configuration(index: try index(webM().bytes), hdr: true)
        let segment = FragmentedMP4.vp9InitSegment(width: 3840, height: 2160, configuration: configuration)
        let top = boxes(segment)
        #expect(top.map(\.type) == ["ftyp", "moov"])
        #expect(top.reduce(0) { $0 + $1.size } == segment.count)
        let text = String(bytes: segment.map { $0 < 0x20 || $0 > 0x7E ? 0x2E : $0 }, encoding: .ascii) ?? ""
        for name in ["mvex", "trex", "vp09", "vpcC", "colr", "nclx"] { #expect(text.contains(name)) }
    }

    @Test func mediaSegmentPointsTrunAtTheMdatPayload() throws {
        let (bytes, firstCluster) = webM()
        let frames = try index(bytes).frames(inClusters: Array(bytes[firstCluster...]))
        let segment = FragmentedMP4.mediaSegment(sequence: 1, frames: Array(frames.prefix(2)), endMs: 5000)
        let top = boxes(segment)
        #expect(top.map(\.type) == ["moof", "mdat"])
        let moofSize = top[0].size
        // trun: after its 8-byte header and version/flags come sample_count and data_offset.
        let trun = try #require(segment.indices.first { offset in
            offset + 4 <= segment.count && String(bytes: segment[offset..<offset + 4], encoding: .ascii) == "trun"
        })
        let count = segment[trun + 8..<trun + 12].reduce(0) { $0 << 8 | Int($1) }
        let offset = segment[trun + 12..<trun + 16].reduce(0) { $0 << 8 | Int($1) }
        #expect(count == 2)
        #expect(offset == moofSize + 8)
        #expect(Array(segment[offset...]) == [1, 2, 3, 4, 5])
    }
}

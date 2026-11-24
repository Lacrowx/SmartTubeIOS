import Foundation
import Network
import SmartTubeIOSCore
import os

private let remuxLog = Logger(subsystem: appSubsystem, category: "WebMRemux")

/// Plays YouTube's VP9 WebM files in AVPlayer, which can't read WebM: serves them as HLS from a
/// loopback HTTP server, rewrapping each cluster range (one per cue point, starting with a key
/// frame) as a fragmented-MP4 segment when AVPlayer asks for it. Audio is the MP4 audio file,
/// referenced by byte range. AVAssetResourceLoader can't supply HLS media segments, hence the
/// server.
final class WebMRemuxServer: @unchecked Sendable {

    struct Variant {
        let format: VideoFormat
        let url: URL
        let index: WebMIndex
        let configuration: VP9Configuration
        let initSegment: [UInt8]
    }

    struct Audio {
        let url: URL
        let index: DASHSegmentIndex
        let codec: String
    }

    let variants: [Variant]
    private let audio: Audio
    private let userAgent: String
    private let lock = NSLock()
    private var cache: [String: [UInt8]] = [:]
    private var cacheOrder: [String] = []
    private var inFlight: [String: Task<[UInt8]?, Never>] = [:]
    private var listener: NWListener?
    private var startSeconds: Double?
    private static let cacheLimit = 4
    private static let headerBytes = 64 * 1024
    private static let fetchAttempts = 8
    private static let retryInterval: Duration = .milliseconds(750)
    private static let partSize: Int64 = 4 * 1024 * 1024
    private static let parallelParts = 6

    private init(variants: [Variant], audio: Audio, userAgent: String) {
        self.variants = variants
        self.audio = audio
        self.userAgent = userAgent
    }

    // MARK: Preparing

    /// Reads the WebM headers of `ladder` and the audio file's index; nil when none of the
    /// video files or the audio can be read.
    static func prepare(
        ladder: [VideoFormat], hdr: Bool, audio audioFormat: VideoFormat, userAgent: String
    ) async
        -> WebMRemuxServer?
    {
        guard let audioURL = audioFormat.url,
            let audioCodec = DASHToHLS.codecs(fromMimeType: audioFormat.mimeType)
        else { return nil }
        async let audioIndex = fetchAudioIndex(audioURL, userAgent: userAgent)
        let variants = await withTaskGroup(of: Variant?.self) { group in
            for format in ladder {
                guard let url = format.url else { continue }
                group.addTask {
                    guard let index = await fetchIndex(url, userAgent: userAgent) else { return nil }
                    let configuration = VP9Configuration(index: index, hdr: hdr)
                    return Variant(
                        format: format, url: url, index: index, configuration: configuration,
                        initSegment: FragmentedMP4.vp9InitSegment(
                            width: index.width, height: index.height, configuration: configuration))
                }
            }
            var result: [Variant] = []
            for await variant in group { if let variant { result.append(variant) } }
            return result.sorted { $0.index.height > $1.index.height }
        }
        guard !variants.isEmpty, let audioIndex = await audioIndex else {
            remuxLog.error("prepare failed: variants=\(variants.count)")
            return nil
        }
        remuxLog.notice(
            "prepared \(variants.map { "\($0.index.height)p \($0.configuration.codecString)" }, privacy: .public) cues=\(variants.first?.index.cues.count ?? 0)"
        )
        return WebMRemuxServer(
            variants: variants, audio: Audio(url: audioURL, index: audioIndex, codec: audioCodec), userAgent: userAgent)
    }

    private static func fetchIndex(_ url: URL, userAgent: String) async -> WebMIndex? {
        var length = headerBytes
        for _ in 0..<3 {
            guard let data = await fetch(url, range: "bytes=0-\(length - 1)", userAgent: userAgent) else { return nil }
            switch WebMIndex.parse([UInt8](data)) {
            case .complete(let index): return index
            case .needsBytes(let needed) where needed > length: length = needed
            default: return nil
            }
        }
        return nil
    }

    private static func fetchAudioIndex(_ url: URL, userAgent: String) async -> DASHSegmentIndex? {
        guard let data = await fetch(url, range: "bytes=0-262143", userAgent: userAgent) else { return nil }
        return DASHSegmentIndex.parse(data)
    }

    /// GET with a Range; retries while the CDN still refuses fresh URLs (403 for ~1.5 s).
    private static func fetch(_ url: URL, range: String, userAgent: String) async -> Data? {
        var request = URLRequest(url: url, timeoutInterval: 30)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue(range, forHTTPHeaderField: "Range")
        for attempt in 1...fetchAttempts {
            if let (data, response) = try? await URLSession.shared.data(for: request),
                let status = (response as? HTTPURLResponse)?.statusCode
            {
                if (200..<300).contains(status) { return data }
                if status != 403 { return nil }
            }
            guard attempt < fetchAttempts, !Task.isCancelled else { break }
            try? await Task.sleep(for: retryInterval)
        }
        return nil
    }

    /// Fetches `start...end` as up to `parallelParts` concurrent ranges of about `partSize`: the
    /// CDN serves one large range at ~60 Mbit/s, so a 25 MB 4K segment took ~4 s on its own.
    /// An open-ended range (the last segment) is fetched in one request.
    private static func fetchParallel(_ url: URL, start: Int64, end: Int64?, userAgent: String) async -> Data? {
        guard let end, end - start + 1 > partSize else {
            return await fetch(url, range: "bytes=\(start)-" + (end.map(String.init) ?? ""), userAgent: userAgent)
        }
        let length = end - start + 1
        let count = min(parallelParts, Int((length + partSize - 1) / partSize))
        let size = (length + Int64(count) - 1) / Int64(count)
        let parts = (0..<count).map { part in
            (start + Int64(part) * size, min(end, start + Int64(part + 1) * size - 1))
        }
        let results = await withTaskGroup(of: (Int, Data?).self) { group in
            for (position, part) in parts.enumerated() {
                group.addTask { (position, await fetch(url, range: "bytes=\(part.0)-\(part.1)", userAgent: userAgent)) }
            }
            var results = [Data?](repeating: nil, count: count)
            for await (position, data) in group { results[position] = data }
            return results
        }
        guard results.allSatisfy({ $0 != nil }) else { return nil }
        return results.reduce(into: Data()) { $0.append($1 ?? Data()) }
    }

    // MARK: Serving

    /// Starts listening on loopback; returns the multivariant playlist URL. With
    /// `startSeconds` the playlist tells AVPlayer to start there (`EXT-X-START`), so a resumed
    /// video doesn't first show its opening frame.
    func start(atSeconds startSeconds: Double? = nil) async -> URL? {
        lock.withLock { self.startSeconds = startSeconds }
        let parameters = NWParameters.tcp
        parameters.requiredInterfaceType = .loopback
        parameters.allowLocalEndpointReuse = true
        guard let listener = try? NWListener(using: parameters, on: .any) else { return nil }
        lock.withLock { self.listener = listener }
        listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
        // NWListener requires a dispatch queue.
        listener.start(queue: .global(qos: .userInitiated))
        for _ in 0..<40 where (listener.port?.rawValue ?? 0) == 0 {
            try? await Task.sleep(for: .milliseconds(25))
        }
        guard let port = listener.port?.rawValue, port != 0 else { return nil }
        return URL(string: "http://127.0.0.1:\(port)/multivariant.m3u8")
    }

    func stop() {
        let (listener, tasks) = lock.withLock {
            let state = (self.listener, Array(inFlight.values))
            self.listener = nil
            inFlight = [:]
            cache = [:]
            cacheOrder = []
            return state
        }
        listener?.cancel()
        tasks.forEach { $0.cancel() }
    }

    private func accept(_ connection: NWConnection) {
        connection.start(queue: .global(qos: .userInitiated))
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) { [weak self] data, _, _, _ in
            guard let self, let data, let request = String(bytes: data, encoding: .utf8) else {
                connection.cancel()
                return
            }
            let lines = request.split(separator: "\r\n")
            let path = lines.first?.split(separator: " ").dropFirst().first.map(String.init) ?? "/"
            let range = lines.first { $0.lowercased().hasPrefix("range:") }.map(String.init)
            Task {
                let resource = await self.resource(path)
                Self.respond(connection, resource: resource, range: range, path: path)
            }
        }
    }

    private static func respond(
        _ connection: NWConnection, resource: (body: [UInt8], type: String)?, range: String?, path: String
    ) {
        guard let resource else {
            remuxLog.error("404 \(path, privacy: .public)")
            let response = "HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
            connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in connection.cancel() })
            return
        }
        let body = resource.body
        var status = "200 OK"
        var slice = body[...]
        var contentRange = ""
        if let range, let spec = range.split(separator: "=").last {
            let bounds = spec.split(separator: "-", omittingEmptySubsequences: false)
            let start = Int(bounds.first ?? "") ?? 0
            let end = min(bounds.count > 1 ? (Int(bounds[1]) ?? body.count - 1) : body.count - 1, body.count - 1)
            if start <= end {
                slice = body[start...end]
                status = "206 Partial Content"
                contentRange = "Content-Range: bytes \(start)-\(end)/\(body.count)\r\n"
            }
        }
        let header =
            "HTTP/1.1 \(status)\r\nContent-Type: \(resource.type)\r\nContent-Length: \(slice.count)\r\n"
            + "\(contentRange)Accept-Ranges: bytes\r\nConnection: close\r\n\r\n"
        connection.send(
            content: Data(header.utf8) + Data(slice), completion: .contentProcessed { _ in connection.cancel() })
    }

    private func resource(_ path: String) async -> (body: [UInt8], type: String)? {
        let playlist = "application/vnd.apple.mpegurl"
        if path == "/multivariant.m3u8" { return (Array(multivariantPlaylist.utf8), playlist) }
        if path == "/audio.m3u8" {
            return (Array(DASHToHLS.mediaPlaylist(url: audio.url, index: audio.index).utf8), playlist)
        }
        // /v<index>/video.m3u8, /v<index>/init.mp4, /v<index>/<segment>.m4s
        let parts = path.split(separator: "/")
        guard parts.count == 2, parts[0].hasPrefix("v"), let variantIndex = Int(parts[0].dropFirst()),
            variants.indices.contains(variantIndex)
        else { return nil }
        let variant = variants[variantIndex]
        switch parts[1] {
        case "video.m3u8": return (Array(mediaPlaylist(variant).utf8), playlist)
        case "init.mp4": return (variant.initSegment, "video/mp4")
        default:
            guard parts[1].hasSuffix(".m4s"), let number = Int(parts[1].dropLast(4)),
                variant.index.segments.indices.contains(number),
                let body = await segment(variant: variantIndex, number: number)
            else { return nil }
            prefetch(variant: variantIndex, number: number + 1)
            return (body, "video/mp4")
        }
    }

    var multivariantPlaylist: String {
        let hlsVariants = variants.enumerated().map { position, variant in
            let average = variant.format.bitrate ?? 0
            let peak =
                variant.index.segments.compactMap { segment -> Int? in
                    guard let end = segment.end, segment.durationSeconds > 0 else { return nil }
                    return Int(Double(end - segment.start + 1) * 8 / segment.durationSeconds)
                }.max() ?? average
            return DASHToHLS.Variant(
                uri: "v\(position)/video.m3u8", codecs: variant.configuration.codecString, width: variant.index.width,
                height: variant.index.height, frameRate: max(variant.format.fps, 1), peakBitrate: max(peak, average),
                averageBitrate: average > 0 ? average : peak * 6 / 10)
        }
        let playlist = DASHToHLS.multivariantPlaylist(
            variants: hlsVariants, audioURI: "audio.m3u8", audioCodec: audio.codec,
            audioPeakBitrate: audio.index.peakBitrate, audioAverageBitrate: audio.index.averageBitrate)
        guard let start = lock.withLock({ startSeconds }), start > 0 else { return playlist }
        // EXT-X-START goes with the other playlist-wide tags, after #EXTM3U and the version.
        var lines = playlist.components(separatedBy: "\n")
        lines.insert(String(format: "#EXT-X-START:TIME-OFFSET=%.3f,PRECISE=YES", start), at: min(2, lines.count))
        return lines.joined(separator: "\n")
    }

    func mediaPlaylist(_ variant: Variant) -> String {
        let segments = variant.index.segments
        let target = Int((segments.map(\.durationSeconds).max() ?? 1).rounded(.up))
        var lines = [
            "#EXTM3U", "#EXT-X-VERSION:7", "#EXT-X-TARGETDURATION:\(target)", "#EXT-X-PLAYLIST-TYPE:VOD",
            "#EXT-X-INDEPENDENT-SEGMENTS", "#EXT-X-MAP:URI=\"init.mp4\"",
        ]
        for (number, segment) in segments.enumerated() {
            lines.append("#EXTINF:\(String(format: "%.5f", segment.durationSeconds)),")
            lines.append("\(number).m4s")
        }
        lines.append("#EXT-X-ENDLIST")
        return lines.joined(separator: "\n") + "\n"
    }

    // MARK: Segments

    private func segment(variant variantIndex: Int, number: Int) async -> [UInt8]? {
        let key = "\(variantIndex)/\(number)"
        let task: Task<[UInt8]?, Never> = lock.withLock {
            if let cached = cache[key] { return Task { cached } }
            if let running = inFlight[key] { return running }
            let task = Task { [weak self] () -> [UInt8]? in await self?.remux(variant: variantIndex, number: number) }
            inFlight[key] = task
            return task
        }
        let body = await task.value
        lock.withLock {
            inFlight[key] = nil
            guard let body, cache[key] == nil else { return }
            cache[key] = body
            cacheOrder.append(key)
            while cacheOrder.count > Self.cacheLimit { cache[cacheOrder.removeFirst()] = nil }
        }
        return body
    }

    private func prefetch(variant variantIndex: Int, number: Int) {
        guard variants[variantIndex].index.segments.indices.contains(number) else { return }
        Task { _ = await segment(variant: variantIndex, number: number) }
    }

    private func remux(variant variantIndex: Int, number: Int) async -> [UInt8]? {
        let variant = variants[variantIndex]
        let segment = variant.index.segments[number]
        let started = Date()
        guard
            let data = await Self.fetchParallel(
                variant.url, start: segment.start, end: segment.end, userAgent: userAgent)
        else {
            remuxLog.error("segment \(variant.index.height)p #\(number) fetch failed")
            return nil
        }
        let frames = variant.index.frames(inClusters: [UInt8](data))
        guard !frames.isEmpty else {
            remuxLog.error("segment \(variant.index.height)p #\(number): no frames")
            return nil
        }
        remuxLog.debug(
            "segment \(variant.index.height)p #\(number): \(data.count / 1_000_000) MB in \(Int(Date().timeIntervalSince(started) * 1000)) ms"
        )
        return FragmentedMP4.mediaSegment(sequence: UInt32(number + 1), frames: frames, endMs: segment.endMs)
    }
}

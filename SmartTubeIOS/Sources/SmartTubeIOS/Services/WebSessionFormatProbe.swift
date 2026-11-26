#if DEBUG
import Foundation
import SmartTubeIOSCore

private let probeLog = CrashlyticsLogger(category: "WebSessionProbe")

// MARK: - WebSessionFormatProbe
//
// Debug-only investigation: which `/player` request, sent with the web session (website sign-in
// cookies + SAPISIDHASH auth), still returns adaptive formats with direct URLs above 1080p?
// The 4K routes during a bot check (AV1 byte ranges, VP9 WebM remux) need direct URLs. On
// 2026-11-26 MWEB and WEB answered with `serverAbrStreamingUrl` and no URLs; WEB_CREATOR listed
// direct URLs, but the CDN served them only up to ~2 MB (also with a PO token minted in WebKit).
//
// Run: launch with `--debug-probe-web-session` or `--debug-probe-web-session=<videoId>`.
// Results go to the log (category WebSessionProbe) and to Library/Caches/web-session-probe.txt (tvOS only lets apps write caches).

public enum WebSessionFormatProbe {
    private static let argument = "--debug-probe-web-session"

    /// Runs the probe when the launch argument is present.
    public static func runIfRequested() async {
        guard let arg = ProcessInfo.processInfo.arguments.first(where: { $0.hasPrefix(argument) }) else { return }
        let given = arg.dropFirst(argument.count).drop { $0 == "=" }
        await run(videoId: given.isEmpty ? "oUsHRECFnEo" : String(given))
    }

    private struct Variant {
        let label: String
        let clientName: String
        let clientID: String
        let version: String
        let userAgent: String
        var origin = "https://www.youtube.com"
        var extraClient: [String: Any] = [:]
        var extraBody: [String: Any] = [:]
        var sendsSignatureTimestamp = true
        var sendsVisitorData = false
    }

    static func run(videoId: String) async {
        var lines = ["web-session format probe — video \(videoId) — \(Date())"]
        write(lines + ["running…"])
        guard let youtube = URL(string: "https://www.youtube.com") else { return }
        let cookies = HTTPCookieStorage.shared.cookies(for: youtube) ?? []
        lines.append("cookies for youtube.com: \(cookies.count), SAPISID: \(WebSession.sapisid(in: cookies) != nil)")
        let sts = await signatureTimestamp(timeout: .seconds(10))
        lines.append("signatureTimestamp: \(sts.map(String.init) ?? "unavailable")")

        typealias C = InnerTubeClients
        let variants: [Variant] = [
            Variant(
                label: "MWEB (as the app sends it)", clientName: C.MWEB.name, clientID: C.MWEB.nameID,
                version: C.MWEB.version, userAgent: C.MWEB.userAgent, extraClient: ["clientScreen": "WATCH"]),
            Variant(
                label: "MWEB, iPhone Safari UA, m.youtube.com", clientName: C.MWEB.name, clientID: C.MWEB.nameID,
                version: C.MWEB.version, userAgent: WebSession.userAgent, origin: "https://m.youtube.com"),
            Variant(
                label: "MWEB + visitorData", clientName: C.MWEB.name, clientID: C.MWEB.nameID,
                version: C.MWEB.version, userAgent: C.MWEB.userAgent, sendsVisitorData: true),
            Variant(
                label: "MWEB without signatureTimestamp", clientName: C.MWEB.name, clientID: C.MWEB.nameID,
                version: C.MWEB.version, userAgent: C.MWEB.userAgent, sendsSignatureTimestamp: false),
            Variant(
                label: "WEB (Safari)", clientName: C.WebSafari.name, clientID: C.WebSafari.nameID,
                version: C.WebSafari.version, userAgent: C.WebSafari.userAgent),
            Variant(
                label: "TVHTML5", clientName: C.TV.name, clientID: C.TV.nameID, version: C.TV.version,
                userAgent: C.TV.userAgent),
            Variant(
                label: "WEB_EMBEDDED_PLAYER", clientName: C.TVEmbedded.name, clientID: C.TVEmbedded.nameID,
                version: C.TVEmbedded.version, userAgent: C.WebSafari.userAgent,
                extraBody: ["thirdParty": ["embedUrl": "https://www.reddit.com/"]]),
            Variant(
                label: "WEB_CREATOR", clientName: C.WebCreator.name, clientID: C.WebCreator.nameID,
                version: C.WebCreator.version, userAgent: C.WebSafari.userAgent),
        ]

        var visitorData: String?
        for variant in variants {
            let (line, responseVisitorData) = await probe(
                videoId: videoId, variant: variant, sts: sts, visitorData: visitorData)
            visitorData = visitorData ?? responseVisitorData
            lines.append("\(variant.label): \(line)")
            write(lines + ["running…"])
        }
        for line in lines { probeLog.notice("[probe] \(line)") }
        write(lines)
    }

    /// The current player script's signatureTimestamp, or nil if it can't be had in `timeout`.
    private static func signatureTimestamp(timeout: Duration) async -> Int? {
        await withTaskGroup(of: Int?.self) { group in
            group.addTask { try? await NChallengeSolver.shared.currentPlayer().signatureTimestamp }
            group.addTask {
                try? await Task.sleep(for: timeout)
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }

    private static func probe(
        videoId: String, variant: Variant, sts: Int?, visitorData: String?
    ) async -> (String, String?) {
        guard let url = URL(string: "https://www.youtube.com/youtubei/v1/player?prettyPrint=false") else {
            return ("bad URL", nil)
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(variant.origin, forHTTPHeaderField: "Origin")
        request.setValue(variant.origin, forHTTPHeaderField: "X-Origin")
        request.setValue(variant.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue(variant.clientID, forHTTPHeaderField: "X-YouTube-Client-Name")
        request.setValue(variant.version, forHTTPHeaderField: "X-YouTube-Client-Version")
        request.setValue("0", forHTTPHeaderField: "X-Goog-AuthUser")
        let cookies = HTTPCookieStorage.shared.cookies(for: url) ?? []
        if let auth = WebSession.authorization(cookies: cookies, origin: variant.origin) {
            request.setValue(auth, forHTTPHeaderField: "Authorization")
        }

        var client: [String: Any] = [
            "clientName": variant.clientName, "clientVersion": variant.version, "hl": "en", "gl": "US",
        ]
        client.merge(variant.extraClient) { _, new in new }
        if variant.sendsVisitorData, let visitorData {
            client["visitorData"] = visitorData
            request.setValue(visitorData, forHTTPHeaderField: "X-Goog-Visitor-Id")
        }
        var playback: [String: Any] = ["html5Preference": "HTML5_PREF_WANTS"]
        if variant.sendsSignatureTimestamp, let sts { playback["signatureTimestamp"] = sts }
        var body: [String: Any] = [
            "context": ["client": client], "videoId": videoId, "racyCheckOk": true, "contentCheckOk": true,
            "playbackContext": ["contentPlaybackContext": playback],
        ]
        body.merge(variant.extraBody) { _, new in new }
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
            let responseVisitorData = (json["responseContext"] as? [String: Any])?["visitorData"] as? String
            let dataSync =
                ((json["responseContext"] as? [String: Any])?["mainAppWebResponseContext"] as? [String: Any])?[
                    "datasyncId"] as? String
            return ("HTTP \(code) " + summary(json) + " datasyncId=\(dataSync ?? "nil")", responseVisitorData)
        } catch {
            return ("error \(error.localizedDescription)", nil)
        }
    }

    /// Playability, SABR, and the tallest video format per kind of link (direct URL or
    /// signature-ciphered) and codec.
    private static func summary(_ json: [String: Any]) -> String {
        let status = json["playabilityStatus"] as? [String: Any]
        let streaming = json["streamingData"] as? [String: Any] ?? [:]
        let adaptive = streaming["adaptiveFormats"] as? [[String: Any]] ?? []
        func tallest(_ include: ([String: Any]) -> Bool) -> String {
            let heights = adaptive.filter(include).compactMap { $0["height"] as? Int }
            return heights.max().map { "\($0)" } ?? "-"
        }
        func mime(_ format: [String: Any]) -> String { format["mimeType"] as? String ?? "" }
        func hasURL(_ format: [String: Any]) -> Bool { format["url"] != nil }
        func ciphered(_ format: [String: Any]) -> Bool { format["signatureCipher"] != nil || format["cipher"] != nil }
        let video = adaptive.filter { mime($0).hasPrefix("video/") }
        let parts = [
            "status=\(status?["status"] ?? "nil")",
            (status?["reason"] as? String).map { "reason=\"\($0)\"" } ?? "",
            "sabr=\(streaming["serverAbrStreamingUrl"] != nil)",
            "hls=\(streaming["hlsManifestUrl"] != nil)",
            "adaptive=\(adaptive.count) video=\(video.count)",
            "withURL=\(adaptive.filter(hasURL).count) ciphered=\(adaptive.filter(ciphered).count)",
            "maxURL[av1]=\(tallest { hasURL($0) && mime($0).contains("av01") })",
            "maxURL[vp9]=\(tallest { hasURL($0) && mime($0).contains("vp9") })",
            "maxURL[h264]=\(tallest { hasURL($0) && mime($0).contains("avc1") })",
            "maxCiphered=\(tallest { ciphered($0) && mime($0).hasPrefix("video/") })",
            "maxListed=\(tallest { mime($0).hasPrefix("video/") })",
        ]
        return parts.filter { !$0.isEmpty }.joined(separator: " ")
    }

    private static func write(_ lines: [String]) {
        guard let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else {
            return
        }
        try? FileManager.default.createDirectory(at: caches, withIntermediateDirectories: true)
        let text = lines.joined(separator: "\n") + "\n"
        try? text.write(to: caches.appendingPathComponent("web-session-probe.txt"), atomically: true, encoding: .utf8)
    }
}
#endif

#if DEBUG && os(tvOS)
import AVFoundation

// MARK: - PlaybackDiagnosticsDump
//
// Debug-only: with `--debug-dump-playback`, writes what AVPlayer reports about the current item
// (status, error log with HTTP status per request, access log) plus the view model's route and
// formats to Library/Caches/playback-dump.txt, `delay` after the player screen opens.
@MainActor
enum PlaybackDiagnosticsDump {
    static var isRequested: Bool { ProcessInfo.processInfo.arguments.contains("--debug-dump-playback") }

    static func schedule(vm: PlaybackViewModel, delay: Duration = .seconds(25)) {
        guard isRequested else { return }
        Task { @MainActor in
            try? await Task.sleep(for: delay)
            var lines = ["playback dump — \(Date())"]
            lines.append("video=\(vm.currentVideo?.id ?? "nil") route=\(String(describing: vm.webSessionRoute))")
            lines.append("formats=\(vm.availableFormats.map(\.qualityLabel))")
            lines.append("error=\(vm.error.map { String(describing: $0) } ?? "nil")")
            let player = vm.player
            lines.append(
                "rate=\(player.rate) timeControl=\(player.timeControlStatus.rawValue) waiting=\(player.reasonForWaitingToPlay?.rawValue ?? "nil") time=\(player.currentTime().seconds)"
            )
            if let item = player.currentItem {
                lines.append(
                    "item status=\(item.status.rawValue) error=\(item.error.map { String(describing: $0) } ?? "nil")")
                lines.append("item asset=\((item.asset as? AVURLAsset)?.url.absoluteString.prefix(80) ?? "?")")
                for event in item.errorLog()?.events ?? [] {
                    let uri =
                        event.uri.map { u -> String in
                            let comps = URLComponents(string: u)
                            let itag = comps?.queryItems?.first { $0.name == "itag" }?.value ?? "-"
                            return "\(comps?.host ?? "?")\(comps?.path.prefix(40) ?? "") itag=\(itag)"
                        } ?? "nil"
                    lines.append(
                        "errorLog: status=\(event.errorStatusCode) domain=\(event.errorDomain) comment=\(event.errorComment ?? "") uri=\(uri)"
                    )
                }
                for event in item.accessLog()?.events ?? [] {
                    lines.append(
                        "accessLog: indicated=\(Int(event.indicatedBitrate)) observed=\(Int(event.observedBitrate)) segments=\(event.numberOfMediaRequests) stalls=\(event.numberOfStalls) bytes=\(event.numberOfBytesTransferred) uri=\(event.uri?.prefix(60) ?? "nil")"
                    )
                }
            } else {
                lines.append("no current item")
            }
            let text = lines.joined(separator: "\n") + "\n"
            if let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first {
                try? text.write(
                    to: caches.appendingPathComponent("playback-dump.txt"), atomically: true, encoding: .utf8)
            }
        }
    }
}
#endif

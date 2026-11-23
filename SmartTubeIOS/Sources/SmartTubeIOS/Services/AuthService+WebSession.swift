#if canImport(WebKit)
import CryptoKit
import Foundation
import SmartTubeIOSCore
import WebKit

// MARK: - YouTube web session
//
// Cookies from signing in on YouTube's website (see `WebSignInView`). They pass YouTube's
// "Sign in to confirm you're not a bot" check where the TV OAuth token does not. The
// cookies live in both cookie stores: WebKit's (read by the embed player) and
// `HTTPCookieStorage.shared` (sent by InnerTube's URLSession with SAPISIDHASH auth).

extension AuthService {

    /// Copies the web session from WebKit's cookie store into `HTTPCookieStorage.shared` and
    /// uses its SAPISID for SAPISIDHASH auth. Returns false if the store holds no session.
    @discardableResult
    func adoptWebSession(from store: WKHTTPCookieStore) async -> Bool {
        let cookies = WebSession.sessionCookies(await store.allCookies())
        guard let value = WebSession.sapisid(in: cookies) else { return false }
        for cookie in cookies {
            HTTPCookieStorage.shared.setCookie(cookie)
        }
        sapisid = value
        await tokenManager.setSAPISID(value)
        authLog.notice("[web-session] adopted \(cookies.count) cookies from the web sign-in")
        return true
    }

    /// Signs out of the web session: removes its cookies from both stores and drops SAPISID.
    func clearWebSession() async {
        let store = WKWebsiteDataStore.default().httpCookieStore
        for cookie in WebSession.sessionCookies(await store.allCookies()) {
            await store.deleteCookie(cookie)
        }
        for cookie in WebSession.sessionCookies(HTTPCookieStorage.shared.cookies ?? []) {
            HTTPCookieStorage.shared.deleteCookie(cookie)
        }
        sapisid = nil
        await tokenManager.setSAPISID(nil)
        authLog.notice("[web-session] cleared")
    }

    #if DEBUG
    /// Spike probe: `/player` with the web session's cookies, sent the way yt-dlp sends
    /// cookie-authenticated requests, for the WEB (Safari), MWEB and TVHTML5 clients.
    /// Logs playability and whether YouTube treated the request as signed in.
    func debugProbeWebSession(videoId: String = "cc5C8hRblBY") async {
        typealias Clients = InnerTubeClients
        let clients = [
            DebugProbeClient(
                name: Clients.WebSafari.name, id: Clients.WebSafari.nameID, version: Clients.WebSafari.version,
                ua: Clients.WebSafari.userAgent),
            DebugProbeClient(
                name: Clients.MWEB.name, id: Clients.MWEB.nameID, version: Clients.MWEB.version,
                ua: Clients.MWEB.userAgent),
            DebugProbeClient(
                name: Clients.TV.name, id: Clients.TV.nameID, version: Clients.TV.version, ua: Clients.TV.userAgent),
        ]
        let player: YouTubePlayerScript
        do {
            player = try await YouTubePlayerScript.fetchCurrent()
        } catch {
            authLog.notice("[web-session] probe: player script failed \(String(describing: error))")
            return
        }
        var visitorData: String?
        for client in clients {
            let (result, vd) = await debugProbe(
                videoId: videoId, client: client, visitorData: visitorData, player: player)
            visitorData = visitorData ?? vd
            authLog.notice("[web-session] probe \(client.name): \(result)")
        }
    }

    private func debugProbe(
        videoId: String, client: DebugProbeClient, visitorData: String?,
        player: YouTubePlayerScript
    ) async -> (String, String?) {
        guard let url = URL(string: "https://www.youtube.com/youtubei/v1/player?prettyPrint=false") else {
            return ("bad URL", nil)
        }
        let origin = "https://www.youtube.com"
        let cookies = HTTPCookieStorage.shared.cookies(for: url) ?? []
        func value(_ name: String) -> String? { cookies.first { $0.name == name }?.value }
        let ts = Int(Date().timeIntervalSince1970)
        func hash(_ scheme: String, _ cookie: String?) -> String? {
            guard let cookie else { return nil }
            let digest = Insecure.SHA1.hash(data: Data("\(ts) \(cookie) \(origin)".utf8))
            return "\(scheme) \(ts)_" + digest.map { String(format: "%02x", $0) }.joined()
        }
        let auth = [
            hash("SAPISIDHASH", value("SAPISID")),
            hash("SAPISID1PHASH", value("__Secure-1PAPISID")),
            hash("SAPISID3PHASH", value("__Secure-3PAPISID")),
        ].compactMap { $0 }.joined(separator: " ")

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(origin, forHTTPHeaderField: "Origin")
        request.setValue(origin, forHTTPHeaderField: "X-Origin")
        request.setValue(client.ua, forHTTPHeaderField: "User-Agent")
        request.setValue(client.id, forHTTPHeaderField: "X-YouTube-Client-Name")
        request.setValue(client.version, forHTTPHeaderField: "X-YouTube-Client-Version")
        request.setValue("0", forHTTPHeaderField: "X-Goog-AuthUser")
        request.setValue("true", forHTTPHeaderField: "X-Youtube-Bootstrap-Logged-In")
        if !auth.isEmpty { request.setValue(auth, forHTTPHeaderField: "Authorization") }
        var clientFields: [String: Any] = ["clientName": client.name, "clientVersion": client.version, "hl": "en"]
        if let visitorData {
            clientFields["visitorData"] = visitorData
            request.setValue(visitorData, forHTTPHeaderField: "X-Goog-Visitor-Id")
        }
        let body: [String: Any] = [
            "context": ["client": clientFields],
            "videoId": videoId,
            "playbackContext": [
                "contentPlaybackContext": ["html5Preference": "HTML5_PREF_WANTS", "signatureTimestamp": player.signatureTimestamp]
            ],
        ]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
            let status = json["playabilityStatus"] as? [String: Any]
            let context = (json["responseContext"] as? [String: Any])?["mainAppWebResponseContext"] as? [String: Any]
            let streaming = json["streamingData"] as? [String: Any]
            var hlsCheck = ""
            if let hls = (streaming?["hlsManifestUrl"] as? String).flatMap(URL.init(string:)) {
                hlsCheck = await debugProbeHLS(hls, userAgent: client.ua, player: player)
            }
            let formats = (streaming?["adaptiveFormats"] as? [[String: Any]]) ?? []
            let ciphered = formats.filter { $0["signatureCipher"] != nil }.count
            let vd = (json["responseContext"] as? [String: Any])?["visitorData"] as? String
            let line = "HTTP \(code) cookies=\(cookies.count) authParts=\(auth.split(separator: " ").count / 2) "
                + "loggedOut=\(context?["loggedOut"] ?? "nil") status=\(status?["status"] ?? "nil") "
                + "reason=\(status?["reason"] ?? "") streams=\(streaming != nil) "
                + "hls=\(streaming?["hlsManifestUrl"] != nil) adaptive=\(formats.count) ciphered=\(ciphered) "
                + "sentVD=\(visitorData != nil) \(hlsCheck)"
            return (line, vd)
        } catch {
            return ("error \(error.localizedDescription)", nil)
        }
    }

    /// Fetches the HLS master and its highest variant playlist, then the first and last
    /// segment as-is and with `n` solved by `NChallengeSolver`, and reports each HTTP status.
    private func debugProbeHLS(_ manifest: URL, userAgent: String, player: YouTubePlayerScript) async -> String {
        let session = URLSession(configuration: .ephemeral)
        func get(_ url: URL, range: Bool = false) async -> (Int, String) {
            var request = URLRequest(url: url)
            request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
            if range { request.setValue("bytes=0-1023", forHTTPHeaderField: "Range") }
            guard let (data, response) = try? await session.data(for: request) else { return (0, "") }
            return ((response as? HTTPURLResponse)?.statusCode ?? 0, String(bytes: data, encoding: .utf8) ?? "")
        }
        func urls(in playlist: String) -> [URL] {
            playlist.split(separator: "\n").filter { $0.hasPrefix("http") }.compactMap { URL(string: String($0)) }
        }
        func nValue(_ url: URL) -> String? {
            let parts = url.path.split(separator: "/")
            guard let index = parts.firstIndex(of: "n"), index + 1 < parts.count else { return nil }
            return String(parts[index + 1])
        }
        let (manifestCode, manifestBody) = await get(manifest)
        guard let variant = urls(in: manifestBody).last else { return "manifest=\(manifestCode) variant=none" }
        let (variantCode, variantBody) = await get(variant)
        let segments = urls(in: variantBody)
        guard let first = segments.first, let last = segments.last else {
            return "manifest=\(manifestCode) variant=\(variantCode) segments=0"
        }
        var result = "manifest=\(manifestCode) variant=\(variantCode) segments=\(segments.count) player=\(player.version)"
        let challenges = Array(Set([first, last].compactMap(nValue)))
        let solutions: [String: String]
        do {
            let start = Date()
            solutions = try await NChallengeSolver.shared.solve(challenges, player: player)
            result += " solveMs=\(Int(Date().timeIntervalSince(start) * 1000))"
        } catch {
            return result + " solveError=\(String(describing: error))"
        }
        for (label, segment) in [("first", first), ("last", last)] {
            let (raw, _) = await get(segment, range: true)
            result += " \(label)Raw=\(raw)"
            guard let challenge = nValue(segment), let solved = solutions[challenge],
                let fixed = URL(string: segment.absoluteString.replacingOccurrences(of: "/n/\(challenge)/", with: "/n/\(solved)/"))
            else {
                result += " \(label)Solved=none"
                continue
            }
            let (code, _) = await get(fixed, range: true)
            result += " \(label)Solved=\(code) changed=\(fixed != segment) nLen=\(challenge.count)->\(solved.count)"
            if label == "first" {
                var timeline: [String] = []
                for attempt in 1...5 {
                    try? await Task.sleep(for: .milliseconds(1500))
                    let (retry, _) = await get(fixed, range: true)
                    timeline.append("\(attempt * 1500)ms:\(retry)")
                }
                result += " retries=[\(timeline.joined(separator: ","))]"
            }
        }
        return result
    }
    #endif
}

#if DEBUG
/// A client profile for the spike probe.
private struct DebugProbeClient {
    let name: String
    let id: String
    let version: String
    let ua: String
}
#endif
#endif

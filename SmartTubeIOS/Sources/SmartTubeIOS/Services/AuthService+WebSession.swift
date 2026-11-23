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
        typealias C = InnerTubeClients
        let clients: [(name: String, id: String, version: String, ua: String)] = [
            (C.WebSafari.name, C.WebSafari.nameID, C.WebSafari.version, C.WebSafari.userAgent),
            (C.MWEB.name, C.MWEB.nameID, C.MWEB.version, C.MWEB.userAgent),
            (C.TV.name, C.TV.nameID, C.TV.version, C.TV.userAgent),
        ]
        var visitorData: String?
        for client in clients {
            let (result, vd) = await debugProbe(videoId: videoId, client: client, visitorData: visitorData)
            visitorData = visitorData ?? vd
            authLog.notice("[web-session] probe \(client.name): \(result)")
        }
    }

    private func debugProbe(
        videoId: String, client: (name: String, id: String, version: String, ua: String), visitorData: String?
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
                "contentPlaybackContext": ["html5Preference": "HTML5_PREF_WANTS", "signatureTimestamp": 20775]
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
                hlsCheck = await debugProbeHLS(hls, userAgent: client.ua)
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

    /// Fetches the HLS master, its last (highest) variant playlist and that playlist's first
    /// segment, the way AVPlayer would (no cookies), and reports each HTTP status.
    private func debugProbeHLS(_ master: URL, userAgent: String) async -> String {
        let session = URLSession(configuration: .ephemeral)
        func get(_ url: URL, range: Bool = false) async -> (Int, String) {
            var request = URLRequest(url: url)
            request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
            if range { request.setValue("bytes=0-1023", forHTTPHeaderField: "Range") }
            guard let (data, response) = try? await session.data(for: request) else { return (0, "") }
            return ((response as? HTTPURLResponse)?.statusCode ?? 0, String(decoding: data, as: UTF8.self))
        }
        func lastURL(in playlist: String) -> URL? {
            playlist.split(separator: "\n").last { $0.hasPrefix("http") }.flatMap { URL(string: String($0)) }
        }
        let (masterCode, masterBody) = await get(master)
        guard let variant = lastURL(in: masterBody) else { return "master=\(masterCode) variant=none" }
        let (variantCode, variantBody) = await get(variant)
        guard let segment = lastURL(in: variantBody) else {
            return "master=\(masterCode) variant=\(variantCode) segment=none"
        }
        let (segmentCode, _) = await get(segment, range: true)
        var result =
            "master=\(masterCode) variant=\(variantCode) segment=\(segmentCode) "
            + "segmentHasN=\(segment.path.contains("/n/")) segmentHasPot=\(segment.path.contains("/pot/")) "
            + "rqh1=\(segment.path.contains("/rqh/1")) variantRqh1=\(variant.path.contains("/rqh/1")) "
        var plain = URLRequest(url: segment)
        plain.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        let noRange = (try? await session.data(for: plain)).flatMap { ($0.1 as? HTTPURLResponse)?.statusCode } ?? 0
        let withCookies = (try? await URLSession.shared.data(for: plain)).flatMap {
            ($0.1 as? HTTPURLResponse)?.statusCode
        } ?? 0
        result += "noRange=\(noRange) withCookies=\(withCookies)"
        #if targetEnvironment(simulator)
        let descrambled = await YouTubeNDescrambler.shared.descrambleURL(segment)
        if descrambled != segment {
            let (code, _) = await get(descrambled, range: true)
            result += " descrambledSegment=\(code)"
        }
        #endif
        return result
    }
    #endif
}
#endif

import Foundation

/// A YouTube web session: the cookies from a real sign-in on accounts.google.com.
///
/// On a network YouTube has flagged, every `/player` request answers "Sign in to confirm
/// you're not a bot". The TV device-code OAuth token does not pass that check, and it cannot
/// be exchanged for web cookies (OAuthLogin / Multilogin need a scope only Chrome's client
/// gets). Cookies from signing in on the website itself do pass it.
public enum WebSession {

    /// Google's sign-in page for YouTube; returns to the mobile site when done.
    public static let signInURL = URL(
        string: "https://accounts.google.com/ServiceLogin?service=youtube&continue=https%3A%2F%2Fm.youtube.com%2F")!

    /// Mobile Safari user agent for the sign-in web view. A web view's default user agent
    /// lacks the `Version/… Safari/…` tokens, which Google treats as an embedded browser.
    public static let userAgent =
        "Mozilla/5.0 (iPhone; CPU iPhone OS 18_5 like Mac OS X) AppleWebKit/605.1.15 "
        + "(KHTML, like Gecko) Version/18.5 Mobile/15E148 Safari/604.1"

    private static let sessionDomains = ["youtube.com", "google.com"]

    /// True once the sign-in has landed back on YouTube with a SAPISID cookie for youtube.com.
    public static func isComplete(url: URL?, cookies: [HTTPCookie]) -> Bool {
        guard let host = url?.host?.lowercased(), matches(host, "youtube.com") else { return false }
        return sapisid(in: cookies) != nil
    }

    /// The SAPISID value for youtube.com among `cookies`, if any.
    public static func sapisid(in cookies: [HTTPCookie]) -> String? {
        cookies.first { $0.name == "SAPISID" && matches($0.domain, "youtube.com") && !$0.value.isEmpty }?.value
    }

    /// The youtube.com and google.com cookies that make up the session.
    public static func sessionCookies(_ cookies: [HTTPCookie]) -> [HTTPCookie] {
        cookies.filter { cookie in sessionDomains.contains { matches(cookie.domain, $0) } }
    }

    /// The SAPISID of a web session already in `HTTPCookieStorage.shared`, if any.
    public static func storedSAPISID() -> String? {
        guard let youtube = URL(string: "https://www.youtube.com") else { return nil }
        return sapisid(in: HTTPCookieStorage.shared.cookies(for: youtube) ?? [])
    }

    /// `domain` is `base` or one of its subdomains (cookie domains may carry a leading dot).
    static func matches(_ domain: String, _ base: String) -> Bool {
        let host = domain.lowercased().drop { $0 == "." }
        return host == base || host.hasSuffix("." + base)
    }
}

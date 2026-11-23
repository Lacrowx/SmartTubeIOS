import Foundation
import SmartTubeIOSCore

#if canImport(WebKit)
import WebKit
#endif

// MARK: - YouTube web session
//
// Cookies from signing in on YouTube's website (`WebSignInView`, or sent from a phone to the
// TV with `WebSessionPairing`). They pass YouTube's "Sign in to confirm you're not a bot"
// check where the TV OAuth token does not. They live in `HTTPCookieStorage.shared`, which
// InnerTube's URLSession sends, and on iOS/macOS also in WebKit's store (the embed player).

extension AuthService {

    /// Adopts a web session's cookies. Returns false if they hold no YouTube session.
    @discardableResult
    func adoptWebSession(cookies: [HTTPCookie]) async -> Bool {
        let session = WebSession.sessionCookies(cookies)
        guard let value = WebSession.sapisid(in: session) else { return false }
        for cookie in session {
            HTTPCookieStorage.shared.setCookie(cookie)
        }
        sapisid = value
        await tokenManager.setSAPISID(value)
        authLog.notice("[web-session] adopted \(session.count) cookies")
        return true
    }

    /// Signs out of the web session: removes its cookies and drops SAPISID.
    func clearWebSession() async {
        #if canImport(WebKit)
        let store = WKWebsiteDataStore.default().httpCookieStore
        for cookie in WebSession.sessionCookies(await store.allCookies()) {
            await store.deleteCookie(cookie)
        }
        #endif
        for cookie in WebSession.sessionCookies(HTTPCookieStorage.shared.cookies ?? []) {
            HTTPCookieStorage.shared.deleteCookie(cookie)
        }
        sapisid = nil
        await tokenManager.setSAPISID(nil)
        authLog.notice("[web-session] cleared")
    }

    #if canImport(WebKit)
    /// Adopts the web session from WebKit's cookie store after the website sign-in.
    @discardableResult
    func adoptWebSession(from store: WKHTTPCookieStore) async -> Bool {
        await adoptWebSession(cookies: await store.allCookies())
    }
    #endif
}

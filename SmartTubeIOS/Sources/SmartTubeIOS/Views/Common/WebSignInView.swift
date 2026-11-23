#if canImport(WebKit)
import SmartTubeIOSCore
import SwiftUI
import WebKit
import os

private let webSignInLog = Logger(subsystem: appSubsystem, category: "WebSignIn")

// MARK: - WebSignInView

/// Signs in to YouTube's website in a web view and adopts the resulting cookies, so
/// playback can pass YouTube's "Sign in to confirm you're not a bot" check.
struct WebSignInView: View {
    @Environment(AuthService.self) private var auth
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Text(
                    "Signing in on YouTube's website lets videos play when YouTube blocks your network. YouTube's terms don't allow third-party apps, so this may put your account at risk."
                )
                .font(.footnote)
                .foregroundStyle(.secondary)
                .padding()
                WebSignInWebView { store in
                    if await auth.adoptWebSession(from: store) {
                        WebSignInSession.shared.end()
                        dismiss()
                    }
                }
            }
            .navigationTitle("Sign in to YouTube")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        WebSignInSession.shared.end()
                        dismiss()
                    }
                }
            }
        }
        // Only Cancel or a finished sign-in end the session, so a swipe can't lose it.
        .interactiveDismissDisabled()
    }
}

// MARK: - WebSignInSession

/// Owns the sign-in web view for the whole sign-in, independent of SwiftUI's view lifetime.
/// SwiftUI rebuilds the sheet's view when the app returns from the background (for example
/// after fetching a 2-step code from Messages); a view-owned web view would then start the
/// sign-in over from the first page.
@MainActor
final class WebSignInSession: NSObject, WKNavigationDelegate {
    static let shared = WebSignInSession()

    private var webView: WKWebView?
    private var onComplete: (@MainActor (WKHTTPCookieStore) async -> Void)?
    private var completed = false

    /// The sign-in web view: the one in progress, or a new one on the sign-in page.
    func webView(onComplete: @escaping @MainActor (WKHTTPCookieStore) async -> Void) -> WKWebView {
        self.onComplete = onComplete
        if let webView { return webView }
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.customUserAgent = WebSession.userAgent
        webView.navigationDelegate = self
        webView.load(URLRequest(url: WebSession.signInURL))
        self.webView = webView
        completed = false
        return webView
    }

    /// Discards the web view; the next sign-in starts on the first page.
    func end() {
        webView?.navigationDelegate = nil
        webView = nil
        onComplete = nil
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        Task { await checkCompletion(webView) }
    }

    /// iOS may end a backgrounded web view's content process; reload the page it was on.
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        webSignInLog.notice("web content process ended; reloading the current page")
        webView.reload()
    }

    private func checkCompletion(_ webView: WKWebView) async {
        guard !completed, webView === self.webView else { return }
        let store = webView.configuration.websiteDataStore.httpCookieStore
        let cookies = await store.allCookies()
        let host = webView.url?.host ?? "nil"
        webSignInLog.notice(
            "page loaded host=\(host, privacy: .public) cookies=\(WebSession.sessionCookies(cookies).count)")
        guard WebSession.isComplete(url: webView.url, cookies: cookies) else { return }
        completed = true
        webSignInLog.notice("web sign-in complete")
        await onComplete?(store)
    }
}

// MARK: - Web view

@MainActor
private struct WebSignInWebView {
    /// Called with the cookie store once the sign-in has completed.
    let onComplete: @MainActor (WKHTTPCookieStore) async -> Void

    func makeWebView() -> WKWebView { WebSignInSession.shared.webView(onComplete: onComplete) }
}

#if os(macOS)
extension WebSignInWebView: NSViewRepresentable {
    func makeNSView(context: Context) -> WKWebView { makeWebView() }
    func updateNSView(_ nsView: WKWebView, context: Context) {}
}
#else
extension WebSignInWebView: UIViewRepresentable {
    func makeUIView(context: Context) -> WKWebView { makeWebView() }
    func updateUIView(_ uiView: WKWebView, context: Context) {}
}
#endif
#endif

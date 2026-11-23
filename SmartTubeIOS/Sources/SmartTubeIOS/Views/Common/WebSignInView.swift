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
                    if await auth.adoptWebSession(from: store) { dismiss() }
                }
            }
            .navigationTitle("Sign in to YouTube")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }
}

// MARK: - Web view

@MainActor
private struct WebSignInWebView {
    /// Called with the cookie store once the sign-in has completed.
    let onComplete: @MainActor (WKHTTPCookieStore) async -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onComplete: onComplete) }

    func makeWebView(coordinator: Coordinator) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.customUserAgent = WebSession.userAgent
        webView.navigationDelegate = coordinator
        webView.load(URLRequest(url: WebSession.signInURL))
        return webView
    }

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate {
        private let onComplete: @MainActor (WKHTTPCookieStore) async -> Void
        private var completed = false

        init(onComplete: @escaping @MainActor (WKHTTPCookieStore) async -> Void) {
            self.onComplete = onComplete
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            Task { await checkCompletion(webView) }
        }

        private func checkCompletion(_ webView: WKWebView) async {
            guard !completed else { return }
            let store = webView.configuration.websiteDataStore.httpCookieStore
            let cookies = await store.allCookies()
            let host = webView.url?.host ?? "nil"
            webSignInLog.notice(
                "page loaded host=\(host, privacy: .public) cookies=\(WebSession.sessionCookies(cookies).count)")
            guard WebSession.isComplete(url: webView.url, cookies: cookies) else { return }
            completed = true
            webSignInLog.notice("web sign-in complete")
            await onComplete(store)
        }
    }
}

#if os(macOS)
extension WebSignInWebView: NSViewRepresentable {
    func makeNSView(context: Context) -> WKWebView { makeWebView(coordinator: context.coordinator) }
    func updateNSView(_ nsView: WKWebView, context: Context) {}
}
#else
extension WebSignInWebView: UIViewRepresentable {
    func makeUIView(context: Context) -> WKWebView { makeWebView(coordinator: context.coordinator) }
    func updateUIView(_ uiView: WKWebView, context: Context) {}
}
#endif
#endif

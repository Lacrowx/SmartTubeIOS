#if os(tvOS)
import SmartTubeIOSCore
import SwiftUI

// MARK: - WebSessionPairingView

/// Apple TV: receives a YouTube website sign-in from an iPhone, iPad or Mac on the same
/// network (see `WebSessionPairing`). The TV has no web view to sign in with itself.
struct WebSessionPairingView: View {
    @Environment(AuthService.self) private var auth
    @Environment(\.dismiss) private var dismiss
    @State private var receiver = WebSessionPairingReceiver()

    var body: some View {
        VStack(spacing: 40) {
            Text("Use YouTube Website Sign-In from iPhone")
                .font(.title2).fontWeight(.bold)
            content
            Button("Done") { dismiss() }
        }
        .padding(60)
        .onAppear {
            receiver.start { cookies in await auth.adoptWebSession(cookies: cookies) }
        }
        .onDisappear { receiver.stop() }
    }

    @ViewBuilder
    private var content: some View {
        switch receiver.state {
        case .starting:
            ProgressView()
        case .waiting(let invitation):
            HStack(alignment: .center, spacing: 60) {
                QRCodeView(content: invitation.url.absoluteString)
                    .frame(width: 400, height: 400)
                VStack(alignment: .leading, spacing: 20) {
                    Text("1. On your iPhone, sign in to the YouTube website in SmartTube's Settings.")
                    Text("2. Scan this code with the iPhone's camera and confirm in SmartTube.")
                    Text("The iPhone must be on the same network as this Apple TV.")
                        .foregroundStyle(.secondary)
                    Text(
                        "This lets videos play when YouTube blocks your network. YouTube's terms don't allow third-party apps, so this may put your account at risk."
                    )
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                }
                .frame(maxWidth: 800, alignment: .leading)
            }
        case .received:
            Label("Signed in to the YouTube website.", systemImage: AppSymbol.checkmark)
        case .failed(let message):
            VStack(spacing: 20) {
                Text(message)
                Button("Try Again") {
                    receiver.start { cookies in await auth.adoptWebSession(cookies: cookies) }
                }
            }
        }
    }
}
#endif

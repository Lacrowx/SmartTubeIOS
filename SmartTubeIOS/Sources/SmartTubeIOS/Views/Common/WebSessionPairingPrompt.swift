import SmartTubeIOSCore
import SwiftUI

// MARK: - WebSessionPairingPrompt

/// iPhone, iPad, Mac: after the Apple TV's pairing code is scanned (a `smarttube://pair-tv`
/// link, see `WebSessionPairing`), asks before sending the YouTube website sign-in to the TV,
/// sends it, and reports the result.
struct WebSessionPairingPrompt: ViewModifier {
    @Binding var invitation: WebSessionPairing.Invitation?
    @State private var result: String?

    func body(content: Content) -> some View {
        content
            .alert(
                "Send YouTube Website Sign-In to Apple TV?",
                isPresented: Binding(get: { invitation != nil }, set: { if !$0 { invitation = nil } }),
                presenting: invitation
            ) { invitation in
                Button("Send") { send(to: invitation) }
                Button("Cancel", role: .cancel) {}
            } message: { invitation in
                Text(
                    "SmartTube sends your YouTube website sign-in to the Apple TV at \(invitation.host). Only continue if you just scanned the code on your own TV."
                )
            }
            .alert("Apple TV", isPresented: Binding(get: { result != nil }, set: { if !$0 { result = nil } })) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(result ?? "")
            }
    }

    private func send(to invitation: WebSessionPairing.Invitation) {
        Task { @MainActor in
            do {
                try await WebSessionPairingSender.send(to: invitation)
                result = "Sent. The Apple TV can now play videos when YouTube blocks your network."
            } catch WebSessionPairingSender.SendError.noSession {
                result = "Sign in to the YouTube website in Settings first, then scan the code again."
            } catch {
                result = "Couldn't reach the Apple TV. Check that both are on the same network."
            }
        }
    }
}

extension View {
    /// Handles a scanned Apple TV pairing code (see `WebSessionPairingPrompt`).
    public func webSessionPairingPrompt(_ invitation: Binding<WebSessionPairing.Invitation?>) -> some View {
        modifier(WebSessionPairingPrompt(invitation: invitation))
    }
}

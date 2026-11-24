import SmartTubeIOSCore
import SwiftUI

// MARK: - WebSessionRouteToast
//
// Says, when playback starts, that YouTube blocked the network and which web-session route
// plays the video (`WebSessionRoute`). The same route is listed in Stats for Nerds.

private struct WebSessionRouteToast: ViewModifier {
    let route: WebSessionRoute?
    @State private var message: String?

    func body(content: Content) -> some View {
        content
            // Longer than the other toasts: on a TV it is read from across the room.
            .toast(message: $message, duration: .seconds(5))
            .onChange(of: route) { _, newRoute in
                message = newRoute?.notice
            }
    }
}

extension View {
    /// Shows `route`'s notice as a toast each time it changes to a route.
    func webSessionRouteToast(_ route: WebSessionRoute?) -> some View {
        modifier(WebSessionRouteToast(route: route))
    }
}

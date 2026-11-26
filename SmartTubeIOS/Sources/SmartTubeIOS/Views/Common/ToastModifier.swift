import SwiftUI

// MARK: - ToastModifier
//
// A lightweight, self-dismissing message pill that floats near the bottom of
// any view.  Designed to be applied once at an appropriate ancestor — the
// modifier owns the show/hide lifecycle so callers only need to write a value.
//
// Usage:
//   .toast(message: $someStringBinding)
//
// The binding is set to nil automatically after 2 seconds (or the given duration) so callers never
// have to schedule their own dismissal.

private struct ToastModifier: ViewModifier {
    @Binding var message: String?
    let duration: Duration
    @State private var dismissTask: Task<Void, Never>?

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .bottom) {
                toastPill
            }
            .onChange(of: message) { _, newValue in
                dismissTask?.cancel()
                guard newValue != nil else { return }
                dismissTask = Task {
                    try? await Task.sleep(for: duration)
                    guard !Task.isCancelled else { return }
                    message = nil
                }
            }
    }

    @ViewBuilder
    private var toastPill: some View {
        if let text = message {
            Text(text)
                .font(.subheadline.weight(.semibold))
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                #if os(tvOS)
                .glassEffect(.regular, in: Capsule())
                #else
                .foregroundStyle(.white)
                .background(.black.opacity(0.72), in: Capsule())
                #endif
                .padding(.bottom, 32)
                .transition(.opacity.combined(with: .scale(scale: 0.92, anchor: .bottom)))
                .accessibilityIdentifier("player.toast")
        }
    }
}

extension View {
    /// Displays a self-dismissing toast pill when `message` is non-nil.
    /// The binding is automatically cleared after `duration` (2 seconds by default).
    func toast(message: Binding<String?>, duration: Duration = .seconds(2)) -> some View {
        modifier(ToastModifier(message: message, duration: duration))
    }
}

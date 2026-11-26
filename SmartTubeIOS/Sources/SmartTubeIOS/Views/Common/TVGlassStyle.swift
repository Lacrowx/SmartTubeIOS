import SwiftUI

// MARK: - Action button styles
//
// One definition for the buttons of empty states, sign-in and headers. On tvOS they are
// Liquid Glass, which brings the system focus treatment (focused glass lights up and
// lifts). iOS and macOS keep the bordered styles; their minimums predate glass.

extension View {
    /// The main action of a screen or empty state (Sign In, Retry, Refresh, Search).
    @ViewBuilder func primaryActionButtonStyle() -> some View {
        #if os(tvOS)
        buttonStyle(.glassProminent)
        #else
        buttonStyle(.borderedProminent)
        #endif
    }

    /// A secondary action next to content (Follow, Cancel).
    @ViewBuilder func secondaryActionButtonStyle() -> some View {
        #if os(tvOS)
        buttonStyle(.glass)
        #else
        buttonStyle(.bordered)
        #endif
    }
}

#if os(tvOS)
// MARK: - TVChipButtonStyle
//
// The one definition of a chip-bar chip on tvOS: glass, with the selected chip in the
// prominent (tinted) glass, so focused and selected look different in both themes.

struct TVChipButtonStyle: PrimitiveButtonStyle {
    let isSelected: Bool
    @Environment(SettingsStore.self) private var store

    func makeBody(configuration: Configuration) -> some View {
        // `GlassButtonStyle(_ glass:)` (one style with a tint) needs tvOS 26.1.
        if isSelected {
            // The system accent on tvOS is neutral, which makes prominent glass look like
            // plain glass; fall back to YouTube red.
            Button(configuration)
                .buttonStyle(.glassProminent)
                .tint(store.settings.accentColor.color ?? .red)
        } else {
            Button(configuration).buttonStyle(.glass)
        }
    }
}

extension PrimitiveButtonStyle where Self == TVChipButtonStyle {
    static func tvChip(isSelected: Bool) -> TVChipButtonStyle { TVChipButtonStyle(isSelected: isSelected) }
}
#endif

import SwiftUI

/// Text-color affordance for the selection action bar: the native `ColorPicker`
/// well, wrapped in glass at the same documented button size as its neighbours
/// so the bar reads as one set of controls.
///
/// The well *is* the button — one tap opens the system color picker, with no
/// intermediate popover of our own, so the control behaves exactly like every
/// other color control on the platform (including the system picker's own
/// saved-swatch row, which is where favorites live; see `TextColorMemory` for
/// why we don't draw a recents row alongside it).
struct TextColorWell: View {
    /// Current color of the selection, as `#RRGGBB`.
    let currentHex: String
    /// Called with a `#RRGGBB` string each time the user picks. Fires
    /// continuously while dragging inside the system picker — the host
    /// coalesces before writing history.
    let onPick: (String) -> Void

    @Environment(\.self) private var environment

    /// Binding the well drives. Reads the selection's live color so the well
    /// matches what's on canvas; writes resolve back to hex through the
    /// environment (an adaptive `Color` needs one).
    private var pickerBinding: Binding<Color> {
        Binding(
            get: { Color(hex: currentHex) ?? DesignSystem.Colors.primary },
            set: { onPick(canvasColorHexString(from: $0.resolve(in: environment))) }
        )
    }

    var body: some View {
        ColorPicker("Text Color", selection: pickerBinding, supportsOpacity: false)
            .labelsHidden()
            .accessibilityLabel("Text color")
            // `ColorPicker` sizes its well itself and ignores `controlSize`,
            // so the surrounding glass is sized explicitly to the same metric
            // the glass buttons use.
            .frame(
                width: CanvasActionBarMetrics.buttonSide,
                height: CanvasActionBarMetrics.buttonSide
            )
            .glassEffect(.regular.interactive(), in: .circle)
    }
}

#Preview {
    TextColorWell(currentHex: "#3977F8", onPick: { _ in })
        .padding(40)
        .background(Color.gray.opacity(0.2))
}

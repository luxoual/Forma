import SwiftUI

/// Color affordance for the selection action bar (text color, frame fill):
/// the native `ColorPicker`
/// well, wrapped in glass at the same documented button size as its neighbours
/// so the bar reads as one set of controls.
///
/// The well *is* the button — one tap opens the system color picker, with no
/// intermediate popover of our own, so the control behaves exactly like every
/// other color control on the platform (including the system picker's own
/// saved-swatch row, which is where favorites live; see `TextColorMemory` for
/// why we don't draw a recents row alongside it).
struct TextColorWell: View {
    /// Current color of the selection, as `#RRGGBB` (or `#RRGGBBAA` when
    /// `supportsOpacity` is on and the color is see-through).
    let currentHex: String
    /// Called with a hex string each time the user picks. Fires
    /// continuously while dragging inside the system picker — the host
    /// coalesces before writing history.
    let onPick: (String) -> Void
    /// Names the well for VoiceOver ("Text color", "Frame color").
    var label: String = "Text color"
    /// Shows the system picker's opacity slider. On for frame fills, so a
    /// frame can tint what's behind it; off for text, which stays solid so
    /// it stays readable.
    var supportsOpacity: Bool = false

    @Environment(\.self) private var environment

    /// Binding the well drives. Reads the selection's live color so the well
    /// matches what's on canvas; writes resolve back to hex through the
    /// environment (an adaptive `Color` needs one).
    private var pickerBinding: Binding<Color> {
        Binding(
            get: { Color(hex: currentHex) ?? DesignSystem.Colors.primary },
            set: {
                onPick(canvasColorHexString(
                    from: $0.resolve(in: environment),
                    includeOpacity: supportsOpacity
                ))
            }
        )
    }

    var body: some View {
        ColorPicker(label, selection: pickerBinding, supportsOpacity: supportsOpacity)
            .labelsHidden()
            .accessibilityLabel(label)
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

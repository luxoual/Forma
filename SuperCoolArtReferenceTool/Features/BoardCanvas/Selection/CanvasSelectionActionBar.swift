import SwiftUI

/// Shared sizing for the selection action bar's controls.
enum CanvasActionBarMetrics {
    /// Height (and, for icon-only controls, width) of a `.controlSize(.large)`
    /// button on iOS. Published in the Human Interface Guidelines' button
    /// shape table — mini 28, small 32, regular 44, **large 52**, extra large
    /// 64 — whose names map 1:1 onto SwiftUI's `ControlSize`.
    ///
    /// Applied explicitly to every control in the bar, including the ones that
    /// would pick it up from `.controlSize(.large)` anyway, so that a control
    /// which *doesn't* honour `controlSize` (`ColorPicker`) still lands on the
    /// same outline as its neighbours.
    static let buttonSide: CGFloat = 52
}

/// Floating action bar shown next to the current canvas selection. Appears
/// whenever one or more items are selected and no drag/resize/marquee is in
/// progress. Host view is responsible for positioning the bar in screen space.
struct CanvasSelectionActionBar: View {
    /// Current text color of the selection as `#RRGGBB`, or nil when the
    /// selection contains no text elements (color controls hide then).
    let textColorHex: String?
    let onPickTextColor: (String) -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            // The color well is inserted conditionally rather than kept
            // mounted like the bar itself. The stale-glass-backdrop problem
            // that forces `SelectionActionBarLayer` to stay mounted is a
            // *launch-time* hazard — a glass view inserted before the canvas
            // beneath it has settled. By the time a user has selected a text
            // element the canvas has long since composited, so this samples
            // correctly on insert.
            if let textColorHex {
                TextColorWell(
                    currentHex: textColorHex,
                    onPick: onPickTextColor
                )
            }

            // Title is kept for VoiceOver, then hidden visually so only the
            // trash icon shows in the button.
            Button("Delete", systemImage: "trash", role: .destructive, action: onDelete)
                .labelStyle(.iconOnly)
                .buttonStyle(.glass)
                .tint(.red)
                .controlSize(.large)
                .frame(
                    width: CanvasActionBarMetrics.buttonSide,
                    height: CanvasActionBarMetrics.buttonSide
                )
        }
    }
}

#Preview("Text selected") {
    CanvasSelectionActionBar(
        textColorHex: "#3977F8",
        onPickTextColor: { _ in },
        onDelete: {}
    )
    .padding()
    .background(Color.gray.opacity(0.2))
}

#Preview("Image selected") {
    CanvasSelectionActionBar(
        textColorHex: nil,
        onPickTextColor: { _ in },
        onDelete: {}
    )
    .padding()
    .background(Color.gray.opacity(0.2))
}

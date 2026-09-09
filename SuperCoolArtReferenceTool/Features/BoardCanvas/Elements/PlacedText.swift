import SwiftUI

/// Free-floating text element. `worldRect` is cached: origin is the
/// authored anchor; size is re-derived from rendered screen size / scale
/// each time the view measures itself (see `TextElementView.onMeasured`).
/// The cached size is what hit-testing, marquee, and bounding-box math
/// read, so it stays consistent with what the user sees on screen.
struct PlacedText: Identifiable {
    let id: UUID
    var content: String
    var worldRect: CGRect
    var zIndex: Int
    var fontSize: CGFloat
    /// Authoritative color state, stored as `#RRGGBB` rather than a `Color`
    /// so it round-trips through `CMCanvasElementPayload.text` and can be
    /// snapshotted for undo without needing an `EnvironmentValues` to
    /// resolve. Views read the derived `color` below.
    var colorHex: String
    /// Nil = auto-width (grow horizontally with content). Non-nil =
    /// fixed wrap width in world units (text reflows inside this box,
    /// height stays content-derived). Set by side-handle drag.
    var wrapWidth: CGFloat? = nil

    /// Render color derived from `colorHex`. Falls back to the palette's
    /// primary when the stored hex is malformed (e.g. a manifest written by
    /// an older/other build).
    var color: Color {
        Color(hex: colorHex) ?? DesignSystem.Colors.primary
    }
}

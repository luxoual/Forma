import SwiftUI

/// Free-floating text element. `worldRect` is cached: origin is the
/// authored anchor; size is re-derived from rendered screen size / scale
/// each time the view measures itself (see `TextElementView.onMeasured`).
/// The cached size is what hit-testing, marquee, and bounding-box math
/// read, so it stays consistent with what the user sees on screen.
struct PlacedText: Identifiable, Equatable {
    let id: UUID
    var content: String
    var worldRect: CGRect
    var zIndex: Int
    var fontSize: CGFloat
    var color: Color
    /// Nil = auto-width (grow horizontally with content). Non-nil =
    /// fixed wrap width in world units (text reflows inside this box,
    /// height stays content-derived). Set by side-handle drag.
    var wrapWidth: CGFloat? = nil
    var parentFrameID: UUID? = nil
}

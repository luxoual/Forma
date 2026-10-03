import SwiftUI

/// A nil boundary leaves the view intact; a null intersection hides it.
struct FrameClipShape: Shape {
    var boundary: CGRect?

    func path(in rect: CGRect) -> Path {
        let visible = boundary.map { rect.intersection($0) } ?? rect
        guard !visible.isNull, !visible.isEmpty else { return Path() }
        return Path(visible)
    }
}

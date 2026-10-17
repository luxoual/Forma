import SwiftUI

/// A nil boundary leaves the view intact; a null intersection hides it.
///
/// `clipsToBounds` decides whether the view's own bounds also clip. Keep it
/// `true` for hit shapes, so a tap can't land outside the item. Set it
/// `false` for masks applied in canvas space (after `.position`). There the
/// bounds are the canvas, which stops at the toolbar, so clipping to them
/// would cut an item off where it slides under the toolbar.
struct FrameClipShape: Shape {
    var boundary: CGRect?
    var clipsToBounds = true

    /// Lets the clip move with its item during an animated camera move (the
    /// home button's glide). Without it, the item glided but its clip jumped
    /// straight to the end spot, so the item was cut away for the whole glide
    /// and popped in at the end.
    ///
    /// Only a real rectangle animates. A nil boundary (no clip) or a null one
    /// (fully hidden) has nothing sensible to blend toward, so it snaps.
    var animatableData: CGRect.AnimatableData {
        get {
            guard let boundary, !boundary.isNull else { return CGRect.zero.animatableData }
            return boundary.animatableData
        }
        set {
            guard let current = boundary, !current.isNull else { return }
            var next = current
            next.animatableData = newValue
            boundary = next
        }
    }

    func path(in rect: CGRect) -> Path {
        let visible: CGRect
        if clipsToBounds {
            visible = boundary.map { rect.intersection($0) } ?? rect
        } else {
            // No frame to clip to: grow past the canvas by its own size on
            // every side, which covers any toolbar or safe-area inset.
            visible = boundary ?? rect.insetBy(dx: -rect.width, dy: -rect.height)
        }
        guard !visible.isNull, !visible.isEmpty else { return Path() }
        return Path(visible)
    }
}

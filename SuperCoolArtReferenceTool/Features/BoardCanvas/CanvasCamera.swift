import SwiftUI

/// Encapsulates the two degrees of freedom that define where the canvas
/// camera is pointing: a translation offset (world-origin → screen-center)
/// and a uniform zoom scale.
///
/// Extracted from `BoardCanvasView` so all four write sites (pinch, pan,
/// home button, landing snap) go through one place, and the type can be
/// injected or observed independently of the view in future refactors.
@Observable
final class CanvasCamera {
    var offset: CGSize = .zero
    var scale: CGFloat = 1.0

    /// Pivot-preserving zoom: compute the new `offset` that keeps the world
    /// point currently under `anchor` (screen-space) pinned after scale changes.
    ///
    /// Invariant: `worldPoint = (anchor - offset) / scale` must equal
    /// `(anchor - newOffset) / newScale`.
    static func zoomAnchoredOffset(
        anchor: CGPoint,
        oldOffset: CGSize,
        oldScale: CGFloat,
        newScale: CGFloat
    ) -> CGSize {
        let worldX = (anchor.x - oldOffset.width) / oldScale
        let worldY = (anchor.y - oldOffset.height) / oldScale
        return CGSize(
            width: anchor.x - worldX * newScale,
            height: anchor.y - worldY * newScale
        )
    }
}

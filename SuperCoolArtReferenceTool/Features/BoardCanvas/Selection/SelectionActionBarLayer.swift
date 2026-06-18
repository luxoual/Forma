import SwiftUI

/// Positions `CanvasSelectionActionBar` beneath the current selection.
///
/// Kept permanently mounted (stable view identity) and shown via
/// opacity rather than inserted with `if`: a Liquid Glass backdrop filter on a
/// freshly inserted view samples its backdrop before the canvas beneath it has
/// settled, caching the wrong light/dark variant. A persistent view never
/// takes that bad first sample, so the glass tracks the canvas immediately.
struct SelectionActionBarLayer: View {
    /// Selection bounding box in world space, or nil when nothing is selected.
    let boundingBox: CGRect?
    let scale: CGFloat
    let offset: CGSize
    /// True while a drag/resize/marquee is in progress — the bar hides then.
    let isInteracting: Bool
    let onCreateFrame: (() -> Void)?
    let onDelete: () -> Void

    /// Last visible center, so the bar fades out in place instead of snapping
    /// to the origin once the selection (and its bounding box) is gone.
    @State private var lastCenter: CGPoint = .zero

    private var isVisible: Bool { boundingBox != nil && !isInteracting }

    /// Live center for the *current* selection — `nil` when there's nothing
    /// selected. Kept independent of `lastCenter` to avoid a self-dependency:
    /// `onChange` watches the bounding box, not a value that depends on its
    /// own cached output.
    private var liveCenter: CGPoint? {
        guard let box = boundingBox else { return nil }
        return CGPoint(x: box.midX * scale + offset.width,
                       y: box.maxY * scale + offset.height + 32)
    }

    /// While `isInteracting` is true the bar parks at `lastCenter` instead
    /// of tracking the live bbox. Re-publishing a moving position every
    /// gesture frame was spawning a fresh `.snappy` animation per frame —
    /// invisible (opacity 0), but the animation churn ate frame budget and
    /// caused visible jitter in the dragged element (text resize especially).
    private var displayCenter: CGPoint {
        isVisible ? (liveCenter ?? lastCenter) : lastCenter
    }

    /// Animate selection appear/disappear, but **snap** on transitions into
    /// or out of interaction. Without this gate, the gesture-start moment
    /// kicks off a 0.2s opacity *and* position animation on the (invisible)
    /// bar; both eat frame budget for the drag's first ~0.2s, which shows
    /// up as visible jitter in the element being dragged.
    private var transitionAnimation: Animation? {
        isInteracting ? nil : .snappy(duration: 0.2)
    }

    var body: some View {
        CanvasSelectionActionBar(onCreateFrame: onCreateFrame, onDelete: onDelete)
            .position(displayCenter)
            .opacity(isVisible ? 1 : 0)
            .allowsHitTesting(isVisible)
            .animation(transitionAnimation, value: isVisible)
            .animation(transitionAnimation, value: displayCenter)
            .onChange(of: liveCenter) { _, new in
                if isVisible, let new { lastCenter = new }
            }
    }
}

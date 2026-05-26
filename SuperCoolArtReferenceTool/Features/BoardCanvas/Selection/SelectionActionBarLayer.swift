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
    let onDelete: () -> Void

    /// Last visible center, so the bar fades out in place instead of snapping
    /// to the origin once the selection (and its bounding box) is gone.
    @State private var lastCenter: CGPoint = .zero

    private var isVisible: Bool { boundingBox != nil && !isInteracting }

    private var center: CGPoint {
        guard let box = boundingBox else { return lastCenter }
        return CGPoint(x: box.midX * scale + offset.width,
                       y: box.maxY * scale + offset.height + 32)
    }

    var body: some View {
        CanvasSelectionActionBar(onDelete: onDelete)
            .position(center)
            .opacity(isVisible ? 1 : 0)
            .allowsHitTesting(isVisible)
            .animation(.snappy(duration: 0.2), value: isVisible)
            .animation(.snappy(duration: 0.2), value: center)
            .onChange(of: center) { _, new in
                if isVisible { lastCenter = new }
            }
    }
}

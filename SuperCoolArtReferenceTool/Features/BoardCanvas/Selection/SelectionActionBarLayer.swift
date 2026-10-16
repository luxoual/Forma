import SwiftUI

/// Positions `CanvasSelectionActionBar` beneath the current selection.
///
/// The bar fades in and out, but never slides. It always appears already in
/// place under the new selection, instead of gliding over from wherever the
/// last one was.
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
    /// Current text color of the selection as `#RRGGBB`, or nil when the
    /// selection holds no text (the color controls hide then).
    let textColorHex: String?
    let onPickTextColor: (String) -> Void
    /// Fill of the selected frame(s), or nil when no frame is selected.
    var frameFillHex: String? = nil
    var onPickFrameFill: (String) -> Void = { _ in }
    let onCreateFrame: (() -> Void)?
    var onRemoveFrame: (() -> Void)? = nil
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

    /// While hidden, the bar stays at `lastCenter` instead of tracking the
    /// live bbox, so a fade-out happens where the bar was last seen rather
    /// than following a selection that's gone or mid-gesture.
    private var displayCenter: CGPoint {
        isVisible ? (liveCenter ?? lastCenter) : lastCenter
    }

    /// Fade on selection appear/disappear, and when a gesture ends, but
    /// **snap** hidden the moment a gesture starts. Without this gate, the
    /// gesture-start moment
    /// kicks off a 0.2s opacity animation on the (invisible) bar, which eats
    /// frame budget for the drag's first ~0.2s and shows up as visible
    /// jitter in the element being dragged.
    ///
    /// Ease-out rather than a spring: a spring's overshoot is clipped at
    /// opacity 1, so the fade-in ended abruptly. The fade-out is a little
    /// shorter, because things leaving should get out of the way.
    private var transitionAnimation: Animation? {
        if isInteracting { return nil }
        return .easeOut(duration: isVisible ? 0.2 : 0.15)
    }

    var body: some View {
        CanvasSelectionActionBar(
            textColorHex: textColorHex,
            onPickTextColor: onPickTextColor,
            frameFillHex: frameFillHex,
            onPickFrameFill: onPickFrameFill,
            onCreateFrame: onCreateFrame,
            onRemoveFrame: onRemoveFrame,
            onDelete: onDelete
        )
            .position(displayCenter)
            // Moves always land instantly, even when they happen in the same
            // update as the fade-in, or inside someone else's `withAnimation`.
            // A plain `.animation(_:value: isVisible)` would also animate this
            // position, which is the slide from the old selection we don't want.
            .animation(nil, value: displayCenter)
            // Scoped so the fade animates opacity and nothing else.
            .animation(transitionAnimation) { content in
                content.opacity(isVisible ? 1 : 0)
            }
            .allowsHitTesting(isVisible)
            // An invisible bar still holds a Delete button. Keep VoiceOver
            // and keyboard focus from landing on it.
            .accessibilityHidden(!isVisible)
            // Watch the live center only while the bar is visible, so the
            // value also changes when the bar *becomes* visible. Watching
            // `liveCenter` alone missed this: a pan moves the selection while
            // the bar is hidden, then the pan ends without moving it again,
            // so `lastCenter` kept the pre-pan spot and the next fade-out
            // jumped back there.
            .onChange(of: isVisible ? liveCenter : nil, initial: true) { _, new in
                if let new { lastCenter = new }
            }
    }
}

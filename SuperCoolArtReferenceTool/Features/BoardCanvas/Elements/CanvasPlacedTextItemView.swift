import SwiftUI

struct CanvasPlacedTextItemView: View {
    @Binding var placed: PlacedText
    let scale: CGFloat
    let position: CGPoint
    var clipRect: CGRect? = nil
    /// Live tint while a frame resize is about to change this text's frame.
    var hint: FrameMembershipHint? = nil
    let isEditing: Bool
    let isSelected: Bool
    let isMultiSelected: Bool
    let onCommitEdit: () -> Void
    let onTap: () -> Void

    /// The text's on-screen box, in canvas coordinates.
    private var screenBounds: CGRect {
        CGRect(x: position.x - placed.worldRect.width * scale / 2,
               y: position.y - placed.worldRect.height * scale / 2,
               width: placed.worldRect.width * scale, height: placed.worldRect.height * scale)
    }

    private var hitRect: CGRect {
        clipRect.map { screenBounds.intersection($0) } ?? screenBounds
    }

    var body: some View {
        TextElementView(
            placed: $placed,
            scale: scale,
            isEditing: isEditing,
            isSelected: isSelected,
            isMultiSelected: isMultiSelected,
            onCommitEdit: onCommitEdit
        )
        // The leaving fade goes before `.position`, so it filters only the
        // text, not a canvas-sized view. `TextElementView` holds no state,
        // and a text being edited never shows the fade, so swapping it in
        // and out can't drop a live text field.
        .frameMembershipLeavingEffect(hint == .leaving && !isEditing)
        .position(x: position.x, y: position.y)
        // After `.position` this view fills the canvas, so the outline is
        // drawn at the text's box in canvas coordinates. Drawing it before
        // `.position` would land in the text's unscaled layout box instead.
        .frameMembershipOutline(hint, in: Rectangle(), rect: screenBounds)
        // Order matters: `.position` makes this view fill the whole canvas,
        // so the mask and hit shape below work in canvas coordinates, the
        // same space `clipRect` and `hitRect` are in. Moving them above
        // `.position` would need a conversion to local space (as
        // `CanvasPlacedImageItemView.localClip` does).
        .mask(FrameClipShape(boundary: clipRect, clipsToBounds: false))
        .contentShape(FrameClipShape(boundary: hitRect))
        .onTapGesture(perform: onTap)
        .accessibilityAddTraits(.isButton)
        .zIndex(Double(placed.zIndex))
    }
}

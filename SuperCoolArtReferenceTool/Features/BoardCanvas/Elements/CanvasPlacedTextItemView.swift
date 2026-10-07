import SwiftUI

struct CanvasPlacedTextItemView: View {
    @Binding var placed: PlacedText
    let scale: CGFloat
    let position: CGPoint
    var clipRect: CGRect? = nil
    let isEditing: Bool
    let isSelected: Bool
    let isMultiSelected: Bool
    let onCommitEdit: () -> Void
    let onTap: () -> Void

    private var hitRect: CGRect {
        let bounds = CGRect(x: position.x - placed.worldRect.width * scale / 2,
                            y: position.y - placed.worldRect.height * scale / 2,
                            width: placed.worldRect.width * scale, height: placed.worldRect.height * scale)
        return clipRect.map { bounds.intersection($0) } ?? bounds
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
        .position(x: position.x, y: position.y)
        // Order matters: `.position` makes this view fill the whole canvas,
        // so the mask and hit shape below work in canvas coordinates, the
        // same space `clipRect` and `hitRect` are in. Moving them above
        // `.position` would need a conversion to local space (as
        // `CanvasPlacedImageItemView.localClip` does).
        .mask(FrameClipShape(boundary: clipRect))
        .contentShape(FrameClipShape(boundary: hitRect))
        .onTapGesture(perform: onTap)
        .accessibilityAddTraits(.isButton)
        .zIndex(Double(placed.zIndex))
    }
}

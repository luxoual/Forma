import SwiftUI

struct CanvasPlacedTextItemView: View {
    @Binding var placed: PlacedText
    let scale: CGFloat
    let position: CGPoint
    let isEditing: Bool
    let isSelected: Bool
    let isMultiSelected: Bool
    let onCommitEdit: () -> Void
    let onTap: () -> Void

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
        .onTapGesture(perform: onTap)
        .zIndex(Double(placed.zIndex))
    }
}

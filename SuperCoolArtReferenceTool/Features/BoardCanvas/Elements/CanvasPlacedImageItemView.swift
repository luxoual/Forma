import SwiftUI

struct CanvasPlacedImageItemView: View {
    let url: URL
    let targetMaxPixelSize: Int
    let isInteracting: Bool
    let size: CGSize
    let position: CGPoint
    let isSelected: Bool
    let isMultiSelected: Bool
    let activeHandle: HandlePosition?
    let zIndex: Int
    let onTap: () -> Void

    var body: some View {
        FileImageView(url: url, targetMaxPixelSize: targetMaxPixelSize, isInteracting: isInteracting)
            .frame(width: size.width, height: size.height)
            .overlay {
                if isSelected && !isMultiSelected {
                    SelectionOverlay(activeHandle: activeHandle)
                } else if isSelected && isMultiSelected {
                    Rectangle()
                        .strokeBorder(DesignSystem.Colors.tertiary.opacity(0.5), lineWidth: 1)
                }
            }
            .onTapGesture(perform: onTap)
            .position(x: position.x, y: position.y)
            .shadow(radius: isInteracting ? 0 : 1)
            .zIndex(Double(zIndex))
    }
}

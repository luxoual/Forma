import SwiftUI

struct CanvasPlacedImageItemView: View {
    let url: URL
    let targetMaxPixelSize: Int
    let isInteracting: Bool
    let size: CGSize
    let position: CGPoint
    var clipRect: CGRect? = nil
    let isSelected: Bool
    let isMultiSelected: Bool
    let activeHandle: HandlePosition?
    let zIndex: Int
    /// Live tint while a frame resize is about to change this image's frame.
    var hint: FrameMembershipHint? = nil
    let onTap: () -> Void

    private var localClip: CGRect? {
        clipRect.map { rect in
            rect.isNull ? .null : rect.offsetBy(dx: -position.x + size.width / 2,
                                               dy: -position.y + size.height / 2)
        }
    }

    var body: some View {
        // The leaving fade goes inside `FileImageView`, on the plain
        // `Image`, so the filters run on the picture alone and not on the
        // loading placeholder.
        FileImageView(url: url, targetMaxPixelSize: targetMaxPixelSize, isInteracting: isInteracting,
                      isLeavingFrame: hint == .leaving)
            .frame(width: size.width, height: size.height)
            .frameMembershipOutline(hint, in: Rectangle())
            .mask(FrameClipShape(boundary: localClip))
            .overlay {
                if isSelected && !isMultiSelected {
                    SelectionOverlay(handles: HandlePosition.corners, activeHandle: activeHandle)
                } else if isSelected && isMultiSelected {
                    Rectangle()
                        .strokeBorder(DesignSystem.Colors.tertiary.opacity(0.5), lineWidth: 1)
                }
            }
            .contentShape(FrameClipShape(boundary: localClip))
            .onTapGesture(perform: onTap)
            .accessibilityAddTraits(.isButton)
            .position(x: position.x, y: position.y)
            .shadow(radius: isInteracting ? 0 : 1)
            .zIndex(Double(zIndex))
    }
}

import SwiftUI

struct CanvasScreenRectBorderView: View {
    let screenRect: CGRect
    let lineWidth: CGFloat
    let color: Color
    var cornerRadius: CGFloat = 0

    var body: some View {
        Group {
            if cornerRadius > 0 {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(color, lineWidth: lineWidth)
            } else {
                Rectangle()
                    .strokeBorder(color, lineWidth: lineWidth)
            }
        }
        .frame(width: screenRect.width, height: screenRect.height)
        .position(x: screenRect.midX, y: screenRect.midY)
        .allowsHitTesting(false)
    }
}

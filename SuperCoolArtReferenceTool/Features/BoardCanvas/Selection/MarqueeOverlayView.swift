import SwiftUI

struct MarqueeOverlayView: View {
    let screenRect: CGRect

    var body: some View {
        Rectangle()
            .fill(DesignSystem.Colors.tertiary.opacity(0.08))
            .overlay(
                Rectangle()
                    .strokeBorder(
                        style: StrokeStyle(lineWidth: 1.5, dash: [6, 4])
                    )
                    .foregroundStyle(DesignSystem.Colors.tertiary)
            )
            .frame(width: screenRect.width, height: screenRect.height)
            .position(x: screenRect.midX, y: screenRect.midY)
    }
}

import SwiftUI

struct MarqueeOverlayView: View {
    let screenRect: CGRect

    var body: some View {
        Rectangle()
            .fill(DesignSystem.Colors.tertiary.opacity(0.08))
            .stroke(DesignSystem.Colors.tertiary, lineWidth: 1.5)
            .frame(width: screenRect.width, height: screenRect.height)
            .position(x: screenRect.midX, y: screenRect.midY)
    }
}

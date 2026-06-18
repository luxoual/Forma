import SwiftUI

struct CanvasPlacedFrameView: View {
    let title: String
    let screenRect: CGRect
    let isSelected: Bool
    let zIndex: Int
    let onTap: () -> Void

    var body: some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(
                    isSelected ? DesignSystem.Colors.tertiary : DesignSystem.Colors.secondary.opacity(0.55),
                    style: StrokeStyle(lineWidth: isSelected ? 2 : 1.25, dash: [10, 6])
                )
                .background(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(DesignSystem.Colors.tertiary.opacity(0.035))
                )
                .allowsHitTesting(false)

            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(isSelected ? DesignSystem.Colors.tertiary : DesignSystem.Colors.primary)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(.ultraThinMaterial, in: Capsule())
                .offset(x: 10, y: -30)
                .onTapGesture(perform: onTap)
        }
        .frame(width: screenRect.width, height: screenRect.height)
        .position(x: screenRect.midX, y: screenRect.midY)
        .zIndex(Double(zIndex))
    }
}

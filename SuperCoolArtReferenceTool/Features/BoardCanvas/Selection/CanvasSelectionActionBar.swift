import SwiftUI

/// Floating action bar shown next to the current canvas selection. Appears
/// whenever one or more items are selected and no drag/resize/marquee is in
/// progress. Host view is responsible for positioning the bar in screen space.
struct CanvasSelectionActionBar: View {
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 4) {
            Button(action: onDelete) {
                Image(systemName: "trash")
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(DesignSystem.Colors.destructive)
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Delete")
        }
        .padding(.horizontal, 4)
        .background(DesignSystem.Colors.primary, in: .rect(cornerRadius: 10))
        .shadow(color: .black.opacity(0.3), radius: 8, x: 2, y: 2)
    }
}

#Preview {
    CanvasSelectionActionBar(onDelete: {})
        .padding()
        .background(Color.gray.opacity(0.2))
}

import SwiftUI

/// Floating action bar shown next to the current canvas selection. Appears
/// whenever one or more items are selected and no drag/resize/marquee is in
/// progress. Host view is responsible for positioning the bar in screen space.
struct CanvasSelectionActionBar: View {
    let onDelete: () -> Void

    var body: some View {
        Button(action: onDelete) {
            Image(systemName: "trash")
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(DesignSystem.Colors.destructive)
        }
        .buttonStyle(.glass)
        .controlSize(.large)
        .accessibilityLabel("Delete")
    }
}

#Preview {
    CanvasSelectionActionBar(onDelete: {})
        .padding()
        .background(Color.gray.opacity(0.2))
}

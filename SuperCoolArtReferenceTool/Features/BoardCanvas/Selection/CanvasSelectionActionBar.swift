import SwiftUI

/// Floating action bar shown next to the current canvas selection. Appears
/// whenever one or more items are selected and no drag/resize/marquee is in
/// progress. Host view is responsible for positioning the bar in screen space.
struct CanvasSelectionActionBar: View {
    let onCreateFrame: (() -> Void)?
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            if let onCreateFrame {
                Button("Create Frame", systemImage: "square.on.square", action: onCreateFrame)
                    .labelStyle(.iconOnly)
                    .buttonStyle(.glass)
                    .tint(DesignSystem.Colors.tertiary)
                    .controlSize(.large)
            }

            Button("Delete", systemImage: "trash", role: .destructive, action: onDelete)
                .labelStyle(.iconOnly)
                .buttonStyle(.glass)
                .tint(.red)
                .controlSize(.large)
        }
    }
}

#Preview {
    CanvasSelectionActionBar(onCreateFrame: {}, onDelete: {})
        .padding()
        .background(Color.gray.opacity(0.2))
}

import SwiftUI

/// Context menu shown when an item is long-pressed on the canvas.
///
/// Attached per-item via `.contextMenu { CanvasContextMenu(onDelete: …) }`.
/// Kept as a small ViewBuilder-producing type so additional actions (duplicate,
/// bring-to-front, etc.) can be added here without touching the render loop.
struct CanvasContextMenu: View {
    let onDelete: () -> Void

    var body: some View {
        Button(role: .destructive, action: onDelete) {
            Label("Delete", systemImage: "trash")
        }
    }
}

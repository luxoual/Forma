import SwiftUI

@Observable
final class CanvasSelectionState {
    var selectedIDs: Set<UUID> = []
    /// World-space offset being applied during an active drag-move
    var dragOffset: CGSize = .zero
    /// Whether a move drag is in progress
    var isDragging: Bool = false

    func select(_ id: UUID, extending: Bool = false) {
        if extending {
            if selectedIDs.contains(id) {
                selectedIDs.remove(id)
            } else {
                selectedIDs.insert(id)
            }
        } else {
            selectedIDs = [id]
        }
    }

    func clearSelection() {
        selectedIDs.removeAll()
    }
}

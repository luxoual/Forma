import SwiftUI

@Observable
final class CanvasSelectionState {
    var selectedIDs: Set<UUID> = []
    /// World-space offset being applied during an active drag-move
    var dragOffset: CGSize = .zero
    /// Whether a move drag is in progress
    var isDragging: Bool = false

    // MARK: - Resize state

    /// Which handle is being dragged (nil when not resizing)
    var resizeHandle: HandlePosition?
    /// The element's world rect at resize start
    var resizeStartRect: CGRect?
    /// The live world rect during resize (used for rendering)
    var resizeCurrentRect: CGRect?
    /// The ID of the element being resized
    var resizeElementID: UUID?

    var isResizing: Bool { resizeHandle != nil }

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

    func clearResize() {
        resizeHandle = nil
        resizeStartRect = nil
        resizeCurrentRect = nil
        resizeElementID = nil
    }
}

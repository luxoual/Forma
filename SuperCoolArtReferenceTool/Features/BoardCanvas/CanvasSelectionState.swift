import SwiftUI

@Observable
@MainActor
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

    // MARK: - Marquee state

    /// World-space anchor point of the marquee drag
    var marqueeStartWorld: CGPoint?
    /// World-space current corner of the marquee drag
    var marqueeCurrentWorld: CGPoint?

    var isMarqueeing: Bool { marqueeStartWorld != nil }

    /// Normalized world-space rect of the active marquee
    var marqueeWorldRect: CGRect? {
        guard let start = marqueeStartWorld, let current = marqueeCurrentWorld else { return nil }
        return CGRect(
            x: min(start.x, current.x),
            y: min(start.y, current.y),
            width: abs(current.x - start.x),
            height: abs(current.y - start.y)
        )
    }

    func clearMarquee() {
        marqueeStartWorld = nil
        marqueeCurrentWorld = nil
    }

    // MARK: - Group resize state

    /// Original world rects of all selected items at resize start
    var groupResizeStartRects: [UUID: CGRect]?
    /// Group bounding box at resize start
    var groupResizeBBoxStart: CGRect?
    /// Live group bounding box during resize
    var groupResizeBBoxCurrent: CGRect?

    var isGroupResizing: Bool { groupResizeStartRects != nil }

    func clearGroupResize() {
        groupResizeStartRects = nil
        groupResizeBBoxStart = nil
        groupResizeBBoxCurrent = nil
        resizeHandle = nil
    }
}

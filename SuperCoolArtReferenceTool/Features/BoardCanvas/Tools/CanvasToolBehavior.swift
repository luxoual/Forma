import SwiftUI

enum DragMode {
    case pan
    case moveItem
    case resizeItem
    case marqueeSelect
    case none
}

/// Lightweight item descriptor for synchronous hit-testing against in-memory placed images.
struct HitTestItem {
    let id: UUID
    let worldRect: CGRect
    let zIndex: Int
}

protocol CanvasToolBehavior {
    /// Synchronous mode decision using in-memory placed images (no store round-trip).
    @MainActor
    func dragBegan(
        worldStart: CGPoint,
        items: [HitTestItem],
        selection: CanvasSelectionState
    ) -> DragMode

    /// Called when a specific item was tapped. Hit-testing is already done by
    /// the view layer (per-item `.onTapGesture`), so no world-point lookup is
    /// needed here.
    @MainActor
    func tappedItem(
        id: UUID,
        store: LocalBoardStore,
        selection: CanvasSelectionState
    ) async

    /// Called when the empty canvas was tapped (no item under the tap).
    @MainActor
    func tappedEmpty(selection: CanvasSelectionState)
}

struct PointerToolBehavior: CanvasToolBehavior {
    @MainActor
    func dragBegan(
        worldStart: CGPoint,
        items: [HitTestItem],
        selection: CanvasSelectionState
    ) -> DragMode {
        if let hit = Self.topmostItem(at: worldStart, in: items) {
            if !selection.selectedIDs.contains(hit.id) {
                selection.select(hit.id)
            }
            return .moveItem
        } else {
            return .pan
        }
    }

    static func topmostItem(at point: CGPoint, in items: [HitTestItem]) -> HitTestItem? {
        items.filter { $0.worldRect.contains(point) }
             .max(by: { $0.zIndex < $1.zIndex })
    }

    @MainActor
    func tappedItem(
        id: UUID,
        store: LocalBoardStore,
        selection: CanvasSelectionState
    ) async {
        selection.select(id)
        await store.moveToTop(elementIDs: [id])
    }

    @MainActor
    func tappedEmpty(selection: CanvasSelectionState) {
        selection.clearSelection()
    }
}

struct GroupToolBehavior: CanvasToolBehavior {
    @MainActor
    func dragBegan(worldStart: CGPoint, items: [HitTestItem], selection: CanvasSelectionState) -> DragMode {
        if let hit = PointerToolBehavior.topmostItem(at: worldStart, in: items) {
            if !selection.selectedIDs.contains(hit.id) {
                selection.select(hit.id, extending: true)
            }
            return .moveItem
        } else {
            return .marqueeSelect
        }
    }

    @MainActor
    func tappedItem(id: UUID, store: LocalBoardStore, selection: CanvasSelectionState) async {
        selection.select(id, extending: true)
    }

    @MainActor
    func tappedEmpty(selection: CanvasSelectionState) {
        selection.clearSelection()
    }
}

struct TextToolBehavior: CanvasToolBehavior {
    @MainActor
    func dragBegan(
        worldStart: CGPoint,
        items: [HitTestItem],
        selection: CanvasSelectionState
    ) -> DragMode {
        if let hit = PointerToolBehavior.topmostItem(at: worldStart, in: items) {
            if !selection.selectedIDs.contains(hit.id) {
                selection.select(hit.id)
            }
            return .moveItem
        }
        return .pan
    }

    @MainActor
    func tappedItem(
        id: UUID,
        store: LocalBoardStore,
        selection: CanvasSelectionState
    ) async {
        selection.select(id)
        await store.moveToTop(elementIDs: [id])
    }

    @MainActor
    func tappedEmpty(selection: CanvasSelectionState) {
        // Empty-canvas placement is handled by BoardCanvasView's tap handler,
        // which has the world point. This just clears any prior selection so
        // the new text becomes the active focus.
        selection.clearSelection()
    }
}

func toolBehavior(for tool: CanvasTool) -> CanvasToolBehavior {
    switch tool {
    case .pointer: return PointerToolBehavior()
    case .group: return GroupToolBehavior()
    case .text: return TextToolBehavior()
    }
}

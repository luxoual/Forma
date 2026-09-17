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
    ///
    /// `extending` is the caller's read of the hardware Shift key at touch-down
    /// (see `KeyModifierMonitor`). Passed in rather than read here so the
    /// behaviors stay pure functions of their inputs.
    @MainActor
    func tappedItem(
        id: UUID,
        extending: Bool,
        store: LocalBoardStore,
        selection: CanvasSelectionState
    ) async

    /// Called when the empty canvas was tapped (no item under the tap).
    @MainActor
    func tappedEmpty(selection: CanvasSelectionState)
}

/// Topmost (highest `zIndex`) item whose world rect contains `point`.
/// Shared by every behavior — hit-testing doesn't vary per tool.
func topmostItem(at point: CGPoint, in items: [HitTestItem]) -> HitTestItem? {
    items.filter { $0.worldRect.contains(point) }
         .max(by: { $0.zIndex < $1.zIndex })
}

/// The canvas's single general-purpose selection tool.
///
/// - Tap an item: select just that item, and bring it to the top.
/// - Shift-tap an item: toggle it in or out of the current selection. Requires
///   a hardware keyboard; on touch alone the marquee is the multi-select path.
/// - Drag from empty canvas: marquee select (always replaces).
/// - Drag from an item: move the selection.
///
/// Two-finger pan is installed at the canvas level and stays live throughout,
/// which is what makes it fine for a one-finger drag on empty canvas to marquee
/// rather than pan.
struct GroupToolBehavior: CanvasToolBehavior {
    @MainActor
    func dragBegan(worldStart: CGPoint, items: [HitTestItem], selection: CanvasSelectionState) -> DragMode {
        if let hit = topmostItem(at: worldStart, in: items) {
            if !selection.selectedIDs.contains(hit.id) {
                selection.select(hit.id, extending: true)
            }
            return .moveItem
        } else {
            return .marqueeSelect
        }
    }

    @MainActor
    func tappedItem(id: UUID, extending: Bool, store: LocalBoardStore, selection: CanvasSelectionState) async {
        // `select(extending:)` toggles, so a shift-tap on an already-selected
        // item removes it — the desktop convention.
        selection.select(id, extending: extending)
        guard !extending else { return }
        // Only a plain tap promotes: raising z-order on every shift-tap would
        // reshuffle the stack while the user is still assembling a selection.
        await store.moveToTop(elementIDs: [id])
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
        if let hit = topmostItem(at: worldStart, in: items) {
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
        extending: Bool,
        store: LocalBoardStore,
        selection: CanvasSelectionState
    ) async {
        selection.select(id, extending: extending)
        guard !extending else { return }
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
    case .group: return GroupToolBehavior()
    case .text: return TextToolBehavior()
    }
}

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
    /// Frames are big boxes drawn *behind* their contents and often nested
    /// inside each other, so they're ranked differently from images and
    /// text when working out what's under a finger (see `topmostItem`).
    var isFrame: Bool = false
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

/// The item a finger at `point` is grabbing. Shared by every behavior —
/// hit-testing doesn't vary per tool.
///
/// Images and text win over frames, and the topmost (highest `zIndex`) of
/// those wins. Only when the point is on bare frame area does a frame get
/// picked, and then it's the smallest one. Nested frames sit inside each
/// other, so the smallest frame under the finger is the innermost one, which
/// is what the user sees as "the frame I'm touching." Ranking frames by
/// `zIndex` instead would sometimes grab the outer frame.
func topmostItem(at point: CGPoint, in items: [HitTestItem]) -> HitTestItem? {
    let hits = items.filter { $0.worldRect.contains(point) }
    if let item = hits.filter({ !$0.isFrame }).max(by: { $0.zIndex < $1.zIndex }) {
        return item
    }
    return hits.filter(\.isFrame).min(by: {
        $0.worldRect.width * $0.worldRect.height < $1.worldRect.width * $1.worldRect.height
    })
}

/// True when the finger at `point` is on something already selected.
/// Starting a drag there should move the selection as-is — not pull in
/// whatever else happens to overlap that spot (like the outer frame around a
/// selected inner frame).
@MainActor
func pointHitsSelection(_ point: CGPoint, in items: [HitTestItem], selection: CanvasSelectionState) -> Bool {
    items.contains { selection.selectedIDs.contains($0.id) && $0.worldRect.contains(point) }
}

/// The canvas's single general-purpose selection tool.
///
/// - Tap an item: select just that item, and bring it to the top.
/// - Shift-tap an item: toggle it in or out of the current selection. Requires
///   a hardware keyboard; on touch alone the marquee is the multi-select path.
/// - Drag from empty canvas: marquee select (always replaces).
/// - Drag from a selected item: move the whole selection.
/// - Drag from an unselected item: select just that item and move it. This
///   matches Figma and Freeform; build a multi-selection first (marquee or
///   shift-tap) to drag several things at once.
///
/// Two-finger pan is installed at the canvas level and stays live throughout,
/// which is what makes it fine for a one-finger drag on empty canvas to marquee
/// rather than pan.
struct GroupToolBehavior: CanvasToolBehavior {
    @MainActor
    func dragBegan(worldStart: CGPoint, items: [HitTestItem], selection: CanvasSelectionState) -> DragMode {
        if pointHitsSelection(worldStart, in: items, selection: selection) {
            return .moveItem
        }
        if let hit = topmostItem(at: worldStart, in: items) {
            selection.select(hit.id)
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
        if pointHitsSelection(worldStart, in: items, selection: selection) {
            return .moveItem
        }
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

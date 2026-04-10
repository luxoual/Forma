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
    func dragBegan(
        worldStart: CGPoint,
        items: [HitTestItem],
        selection: CanvasSelectionState
    ) -> DragMode

    /// Called on tap (drag that ends without meaningful translation).
    func tapped(
        worldPoint: CGPoint,
        store: LocalBoardStore,
        selection: CanvasSelectionState
    ) async
}

struct PointerToolBehavior: CanvasToolBehavior {
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

    func tapped(
        worldPoint: CGPoint,
        store: LocalBoardStore,
        selection: CanvasSelectionState
    ) async {
        let point = SIMD2<Double>(Double(worldPoint.x), Double(worldPoint.y))
        if let header = await store.topmostHeader(at: point) {
            await MainActor.run { selection.select(header.id) }
            await store.moveToTop(elementIDs: [header.id])
        } else {
            await MainActor.run { selection.clearSelection() }
        }
    }
}

struct GroupToolBehavior: CanvasToolBehavior {
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

    func tapped(worldPoint: CGPoint, store: LocalBoardStore, selection: CanvasSelectionState) async {
        let point = SIMD2<Double>(Double(worldPoint.x), Double(worldPoint.y))
        if let header = await store.topmostHeader(at: point) {
            await MainActor.run { selection.select(header.id, extending: true) }
        } else {
            await MainActor.run { selection.clearSelection() }
        }
    }
}

func toolBehavior(for tool: CanvasTool) -> CanvasToolBehavior {
    switch tool {
    case .pointer: return PointerToolBehavior()
    case .group: return GroupToolBehavior()
    }
}

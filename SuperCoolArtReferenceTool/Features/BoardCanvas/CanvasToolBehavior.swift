import SwiftUI

enum DragMode {
    case pan
    case moveItem
    case resizeItem
    case none
}

protocol CanvasToolBehavior {
    /// Called on first drag event to decide what this drag does.
    func dragBegan(
        worldStart: CGPoint,
        store: LocalBoardStore,
        selection: CanvasSelectionState
    ) async -> DragMode

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
        store: LocalBoardStore,
        selection: CanvasSelectionState
    ) async -> DragMode {
        let point = SIMD2<Double>(Double(worldStart.x), Double(worldStart.y))
        if let header = await store.topmostHeader(at: point) {
            if !selection.selectedIDs.contains(header.id) {
                await MainActor.run { selection.select(header.id) }
            }
            await store.moveToTop(elementIDs: Array(selection.selectedIDs))
            return .moveItem
        } else {
            return .pan
        }
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
    func dragBegan(worldStart: CGPoint, store: LocalBoardStore, selection: CanvasSelectionState) async -> DragMode {
        return .pan
    }

    func tapped(worldPoint: CGPoint, store: LocalBoardStore, selection: CanvasSelectionState) async {
        // Future: toggle group membership
    }
}

func toolBehavior(for tool: CanvasTool) -> CanvasToolBehavior {
    switch tool {
    case .pointer: return PointerToolBehavior()
    case .group: return GroupToolBehavior()
    }
}

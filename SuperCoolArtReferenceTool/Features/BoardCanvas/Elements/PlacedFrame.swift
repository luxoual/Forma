import Foundation
import CoreGraphics

struct PlacedFrame: Identifiable, Equatable {
    let id: UUID
    var title: String
    var worldRect: CGRect
    var zIndex: Int
    var parentFrameID: UUID? = nil
}

/// An explicit nil parent means the item belongs directly to the board.
struct FrameMembership {
    let elementID: UUID
    let parentID: UUID?
}

/// Geometry shared by dropping, clipping, and interaction tests.
enum FrameGeometry {
    static func ancestors(of parentID: UUID?, in frames: [PlacedFrame]) -> [PlacedFrame] {
        let lookup = Dictionary(uniqueKeysWithValues: frames.map { ($0.id, $0) })
        var result: [PlacedFrame] = []
        var visited: Set<UUID> = []
        var next = parentID
        while let id = next, visited.insert(id).inserted, let frame = lookup[id] {
            result.append(frame)
            next = frame.parentFrameID
        }
        return result
    }

    /// Operate on the selected containers, not on their selected descendants
    /// a second time. This keeps an existing subtree intact when regrouping.
    static func selectionRoots(_ ids: Set<UUID>, parents: [UUID: UUID], frames: [PlacedFrame]) -> Set<UUID> {
        ids.filter { id in
            !ancestors(of: parents[id], in: frames).contains { ids.contains($0.id) }
        }
    }

    static func clipRect(parentID: UUID?, frames: [PlacedFrame]) -> CGRect? {
        ancestors(of: parentID, in: frames).reduce(nil as CGRect?) { clip, frame in
            clip.map { $0.intersection(frame.worldRect) } ?? frame.worldRect
        }
    }

    static func dropTarget(at point: CGPoint, frames: [PlacedFrame], excluding: Set<UUID>) -> UUID? {
        frames.filter { frame in
            !excluding.contains(frame.id) && frame.worldRect.contains(point) &&
            (clipRect(parentID: frame.parentFrameID, frames: frames)?.contains(point) ?? true)
        }.sorted { lhs, rhs in
            let leftDepth = ancestors(of: lhs.parentFrameID, in: frames).count
            let rightDepth = ancestors(of: rhs.parentFrameID, in: frames).count
            if leftDepth != rightDepth { return leftDepth > rightDepth }
            let leftArea = lhs.worldRect.width * lhs.worldRect.height
            let rightArea = rhs.worldRect.width * rhs.worldRect.height
            if leftArea != rightArea { return leftArea < rightArea }
            if lhs.zIndex != rhs.zIndex { return lhs.zIndex > rhs.zIndex }
            return lhs.id.uuidString < rhs.id.uuidString
        }.first?.id
    }
}

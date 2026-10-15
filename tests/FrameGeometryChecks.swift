import Foundation
import CoreGraphics

// Run with:
// swiftc -module-cache-path /tmp/forma-swift-cache \
//   SuperCoolArtReferenceTool/Features/BoardCanvas/Elements/PlacedFrame.swift \
//   tests/FrameGeometryChecks.swift -o /tmp/forma-frame-checks && /tmp/forma-frame-checks
@main
struct FrameGeometryChecks {
    static func main() {
        let outer = PlacedFrame(id: UUID(), title: "Outer", worldRect: CGRect(x: 0, y: 0, width: 200, height: 200), zIndex: 0)
        let inner = PlacedFrame(id: UUID(), title: "Inner", worldRect: CGRect(x: 100, y: 100, width: 150, height: 150), zIndex: 1, parentFrameID: outer.id)
        let other = PlacedFrame(id: UUID(), title: "Other", worldRect: CGRect(x: 300, y: 0, width: 200, height: 200), zIndex: 2)
        let frames = [outer, inner, other]
        func target(_ x: CGFloat, _ y: CGFloat, excluding: Set<UUID> = []) -> UUID? {
            FrameGeometry.dropTarget(at: CGPoint(x: x, y: y), frames: frames, excluding: excluding)
        }
        precondition(target(50, 50) == outer.id, "Drop into a frame")
        precondition(target(-20, 50) == nil, "Drop outside detaches")
        precondition(target(350, 50) == other.id, "Drop into another frame")
        precondition(target(150, 150) == inner.id, "Innermost frame wins")
        precondition(target(225, 225) == nil, "Clipped parts of a nested frame cannot accept drops")
        precondition(target(150, 150, excluding: [outer.id, inner.id]) == nil, "A moved frame cannot become its own descendant")
        precondition(target(150, 150, excluding: [inner.id]) == outer.id, "A moved nested frame can remain in its parent")
        precondition(FrameGeometry.clipRect(parentID: nil, frames: frames) == nil, "Board items are unclipped")
        let clip = FrameGeometry.clipRect(parentID: inner.id, frames: frames)!
        precondition(clip == CGRect(x: 100, y: 100, width: 100, height: 100), "All ancestor boundaries clip")
        let enlargedImage = CGRect(x: 50, y: 50, width: 400, height: 400)
        precondition(enlargedImage.intersection(clip) == clip, "Resized image overflow is hidden")
        var shrunk = outer
        shrunk.worldRect.size = CGSize(width: 120, height: 120)
        precondition(FrameGeometry.clipRect(parentID: inner.id, frames: [shrunk, inner]) == CGRect(x: 100, y: 100, width: 20, height: 20), "Shrinking a boundary changes clipping")
        precondition(inner.worldRect == CGRect(x: 100, y: 100, width: 150, height: 150), "Clipping leaves child geometry intact")
        var disjoint = inner
        disjoint.worldRect.origin = CGPoint(x: 250, y: 250)
        precondition(FrameGeometry.clipRect(parentID: disjoint.id, frames: [outer, disjoint])!.isNull, "Fully outside children are hidden")
        var cyclic = outer
        cyclic.parentFrameID = inner.id
        precondition(FrameGeometry.ancestors(of: cyclic.id, in: [cyclic, inner]).count == 2, "Malformed imported cycles terminate")
        let image = UUID()
        let text = UUID()
        let looseImage = UUID()
        let parents = [image: inner.id, text: inner.id, inner.id: outer.id]
        let childSelection: Set<UUID> = [inner.id, image, text]
        let roots = FrameGeometry.selectionRoots(childSelection, parents: parents, frames: frames)
        precondition(roots == [inner.id], "Selecting a child frame and its contents must keep the subtree intact")
        let newParent = UUID()
        var regroupedParents = parents
        for id in roots { regroupedParents[id] = newParent }
        precondition(regroupedParents[inner.id] == newParent, "The child frame joins the new parent")
        precondition(regroupedParents[image] == inner.id && regroupedParents[text] == inner.id,
                     "Regrouping must not flatten image and text membership")
        precondition(FrameGeometry.selectionRoots([outer.id, image], parents: parents, frames: frames) == [outer.id],
                     "An ancestor protects descendants even when the intermediate frame is not selected")
        precondition(FrameGeometry.selectionRoots([inner.id, image, looseImage], parents: parents, frames: frames) == [inner.id, looseImage],
                     "Mixed selections preserve the subtree while including unrelated items")
        precondition(FrameGeometry.selectionRoots([image, text], parents: parents, frames: frames) == [image, text],
                     "Selecting children alone still allows independent movement")
        precondition(target(50, 50) == outer.id && target(150, 150) == inner.id,
                     "Dragging a child out can change its parent, while dragging inside preserves it")
        print("21 frame geometry and hierarchy checks passed")
    }
}

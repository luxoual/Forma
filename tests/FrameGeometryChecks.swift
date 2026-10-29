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
        let membershipChecks = MembershipChecks.run()
        print("\(21 + membershipChecks) frame geometry, hierarchy, and membership checks passed")
    }
}

/// Artboard membership: center-based ownership, resize join/leave, draw order.
enum MembershipChecks {
    static func item(_ id: UUID, _ rect: CGRect, parent: UUID?, frame: Bool = false) -> MembershipCandidate {
        MembershipCandidate(id: id, rect: rect, parentID: parent, isFrame: frame)
    }

    static func box(_ x: CGFloat, _ y: CGFloat, _ size: CGFloat = 20) -> CGRect {
        CGRect(x: x - size / 2, y: y - size / 2, width: size, height: size)
    }

    static func parents(_ changes: [FrameMembership]) -> [UUID: UUID?] {
        Dictionary(uniqueKeysWithValues: changes.map { ($0.elementID, $0.parentID) })
    }

    static func run() -> Int {
        var count = 0
        func check(_ condition: Bool, _ message: String) {
            precondition(condition, message)
            count += 1
        }

        let board = PlacedFrame(id: UUID(), title: "Board", worldRect: CGRect(x: 0, y: 0, width: 1000, height: 1000), zIndex: 5)
        let child = PlacedFrame(id: UUID(), title: "Child", worldRect: CGRect(x: 100, y: 100, width: 200, height: 200), zIndex: 1, parentFrameID: board.id)
        let sibling = PlacedFrame(id: UUID(), title: "Sibling", worldRect: CGRect(x: 2000, y: 0, width: 300, height: 300), zIndex: 0)

        // Draw order: parent below child even when the child has a lower zIndex.
        let order = FrameGeometry.drawOrder([child, board, sibling]).map(\.id)
        check(order == [sibling.id, board.id, child.id], "Parents draw below children; siblings by zIndex")
        var loopA = PlacedFrame(id: UUID(), title: "A", worldRect: .zero, zIndex: 0)
        let loopB = PlacedFrame(id: UUID(), title: "B", worldRect: .zero, zIndex: 1, parentFrameID: loopA.id)
        loopA.parentFrameID = loopB.id
        check(FrameGeometry.drawOrder([loopA, loopB]).count == 2, "Frames in a malformed cycle are still drawn")

        // A moved item belongs to the innermost frame holding its center.
        let image = UUID()
        let frames = [board, child, sibling]
        var moved = FrameGeometry.reassign(changed: [item(image, box(200, 200), parent: nil)], frames: frames)
        check(parents(moved)[image] == child.id, "A dropped item joins the innermost frame under its center")
        moved = FrameGeometry.reassign(changed: [item(image, box(500, 500), parent: child.id)], frames: frames)
        check(parents(moved)[image] == board.id, "Leaving a child frame falls back to the next frame out")
        moved = FrameGeometry.reassign(changed: [item(image, box(-500, -500), parent: board.id)], frames: frames)
        check(moved.count == 1 && moved[0].parentID == nil, "Leaving every frame lands on the board")
        moved = FrameGeometry.reassign(changed: [item(image, box(200, 200), parent: child.id)], frames: frames)
        check(moved.isEmpty, "Only real changes are reported")

        // Drops: one answer for the whole selection, from the finger.
        let leftItem = UUID()
        let rightItem = UUID()
        // Two board items straddling the sibling frame's left edge (x = 2000).
        let straddling = [item(leftItem, box(1990, 150), parent: nil), item(rightItem, box(2040, 150), parent: nil)]
        var dropped = FrameGeometry.dropMemberships(roots: straddling, finger: CGPoint(x: 2010, y: 150),
                                                    frames: frames, excluding: [])
        check(parents(dropped)[leftItem] == sibling.id && parents(dropped)[rightItem] == sibling.id,
              "A selection dropped across a frame edge joins the finger's frame together")
        dropped = FrameGeometry.dropMemberships(roots: straddling, finger: CGPoint(x: 1990, y: 150),
                                                frames: frames, excluding: [])
        check(dropped.isEmpty, "A selection dropped with the finger outside stays on the board together")

        // A moved frame takes the finger's frame as parent; it never lands in itself.
        let landed = PlacedFrame(id: child.id, title: "Child", worldRect: CGRect(x: 2050, y: 50, width: 200, height: 200), zIndex: 1, parentFrameID: board.id)
        dropped = FrameGeometry.dropMemberships(
            roots: [item(child.id, landed.worldRect, parent: board.id, frame: true)],
            finger: CGPoint(x: 2150, y: 150), frames: [board, landed, sibling], excluding: [child.id]
        )
        check(parents(dropped)[child.id] == sibling.id, "A moved frame takes the frame under the finger as parent")

        // A dragged frame bigger than the target keeps its parent; the other roots still join.
        let bigFrame = UUID()
        dropped = FrameGeometry.dropMemberships(
            roots: [item(bigFrame, CGRect(x: 1900, y: 0, width: 600, height: 600), parent: nil, frame: true),
                    item(image, box(2100, 100), parent: nil)],
            finger: CGPoint(x: 2100, y: 100), frames: frames, excluding: [bigFrame]
        )
        check(parents(dropped)[bigFrame] == nil && parents(dropped)[image] == sibling.id,
              "A frame never moves into a smaller frame, but its fellow dragged items still join")

        // Resizing: grow the child over a loose board-level image and an image of the board frame.
        let boardImage = UUID()
        let farImage = UUID()
        var grown = child
        grown.worldRect = CGRect(x: 100, y: 100, width: 500, height: 500)
        let touched = [
            item(boardImage, box(450, 450), parent: board.id),
            item(farImage, box(900, 900), parent: board.id),
        ]
        var resized = FrameGeometry.reassign(
            changed: [item(child.id, grown.worldRect, parent: board.id, frame: true)],
            touched: touched, resizedFrameIDs: [child.id], frames: [board, grown, sibling]
        )
        check(parents(resized)[boardImage] == child.id, "Growing a frame pulls in items whose center is now inside")
        check(parents(resized)[farImage] == nil, "Items outside the grown frame keep their frame")
        check(parents(resized)[child.id] == nil, "The resized frame keeps its parent while its center stays inside it")

        // Shrinking: members whose center is now outside leave; the rest stay.
        let inside = UUID()
        let outside = UUID()
        var shrunk = child
        shrunk.worldRect = CGRect(x: 100, y: 100, width: 100, height: 100)
        resized = FrameGeometry.reassign(
            changed: [item(child.id, shrunk.worldRect, parent: board.id, frame: true)],
            touched: [item(inside, box(150, 150), parent: child.id), item(outside, box(250, 250), parent: child.id)],
            resizedFrameIDs: [child.id], frames: [board, shrunk, sibling]
        )
        check(parents(resized)[outside] == board.id, "Shrinking a frame drops members to the next frame out")
        check(parents(resized)[inside] == nil, "Members still centered inside stay")
        let hints = FrameGeometry.hints(
            for: resized, previousParents: [outside: child.id, inside: child.id], resizedFrameIDs: [child.id]
        )
        check(hints[outside] == .leaving && hints[inside] == nil, "Leaving members get the leaving tint")
        let joinHints = FrameGeometry.hints(
            for: [FrameMembership(elementID: boardImage, parentID: child.id)],
            previousParents: [boardImage: board.id], resizedFrameIDs: [child.id]
        )
        check(joinHints[boardImage] == .joining, "Joining items get the joining tint")

        // A touched item in an unrelated, unresized frame keeps its explicit frame.
        let explicitlyLoose = UUID()
        resized = FrameGeometry.reassign(
            changed: [], touched: [item(explicitlyLoose, box(800, 800), parent: nil)],
            resizedFrameIDs: [child.id], frames: [board, grown, sibling]
        )
        check(resized.isEmpty, "A resize leaves explicit choices alone unless the resized frame is involved")

        // A touched frame joins only a bigger frame, so no cycles and no frame vanishes into a smaller one.
        let small = PlacedFrame(id: UUID(), title: "Small", worldRect: CGRect(x: 400, y: 400, width: 60, height: 60), zIndex: 2, parentFrameID: board.id)
        resized = FrameGeometry.reassign(
            changed: [item(child.id, grown.worldRect, parent: board.id, frame: true)],
            touched: [item(small.id, small.worldRect, parent: board.id, frame: true),
                      item(board.id, board.worldRect, parent: nil, frame: true)],
            resizedFrameIDs: [child.id], frames: [board, grown, sibling, small]
        )
        check(parents(resized)[small.id] == child.id, "A smaller frame inside the grown frame nests into it")
        check(parents(resized)[board.id] == nil, "A frame never joins its own descendant")
        var huge = child
        huge.worldRect = CGRect(x: -100, y: -100, width: 1200, height: 1200)
        resized = FrameGeometry.reassign(
            changed: [item(child.id, huge.worldRect, parent: board.id, frame: true)],
            touched: [item(board.id, board.worldRect, parent: nil, frame: true)],
            resizedFrameIDs: [child.id], frames: [board, huge, sibling]
        )
        check(parents(resized)[board.id] == nil && parents(resized)[child.id] == nil,
              "A child grown past its parent's center can't swallow the parent")

        // Shrinking a frame doesn't yank grandchildren out of a nested frame that is now partly hidden.
        let grandchild = UUID()
        var tightBoard = board
        tightBoard.worldRect = CGRect(x: 0, y: 0, width: 180, height: 180)
        resized = FrameGeometry.reassign(
            changed: [item(board.id, tightBoard.worldRect, parent: nil, frame: true)],
            touched: [item(grandchild, box(250, 250), parent: child.id)],
            resizedFrameIDs: [board.id], frames: [tightBoard, child, sibling]
        )
        check(parents(resized)[grandchild] == nil, "Items inside an unresized nested frame stay put")

        // Two resized frames overlapping: the innermost (here, smallest) wins the tie.
        let left = PlacedFrame(id: UUID(), title: "L", worldRect: CGRect(x: 0, y: 0, width: 400, height: 400), zIndex: 0)
        let right = PlacedFrame(id: UUID(), title: "R", worldRect: CGRect(x: 100, y: 100, width: 200, height: 200), zIndex: 1)
        let shared = UUID()
        resized = FrameGeometry.reassign(
            changed: [item(left.id, left.worldRect, parent: nil, frame: true),
                      item(right.id, right.worldRect, parent: nil, frame: true)],
            touched: [item(shared, box(150, 150), parent: nil)],
            resizedFrameIDs: [left.id, right.id], frames: [left, right]
        )
        check(parents(resized)[right.id] == left.id, "A smaller resized frame nests in the bigger one around its center")
        check(parents(resized)[shared] == right.id, "Overlapping resized frames: the innermost one wins")

        // The live preview a frame resize shows (`FrameGeometry.membershipPreview`).
        func preview(
            changed: [MembershipCandidate], touched: [MembershipCandidate] = [],
            resizedFrameIDs: Set<UUID>, frames: [PlacedFrame]
        ) -> MembershipPreview? {
            FrameGeometry.membershipPreview(changed: changed, touched: touched,
                                            resizedFrameIDs: resizedFrameIDs, frames: frames)
        }

        // No frame resized: no preview at all, even when items moved.
        check(preview(changed: [item(image, box(200, 200), parent: nil)], resizedFrameIDs: [],
                      frames: frames) == nil,
              "Resizing only images and text shows no preview")

        // Join: growing the child pulls in a board-frame image.
        let grownPreview = preview(
            changed: [item(child.id, grown.worldRect, parent: board.id, frame: true)],
            touched: [item(boardImage, box(450, 450), parent: board.id),
                      item(farImage, box(900, 900), parent: board.id)],
            resizedFrameIDs: [child.id], frames: [board, grown, sibling]
        )
        check(grownPreview?.hints == [boardImage: .joining], "Preview: only the pulled-in item shows the joining tint")
        check(grownPreview?.parents == [boardImage: child.id], "Preview: the joining item's new parent is the grown frame")

        // Leave: shrinking the child pushes one member out to the board frame.
        let shrunkPreview = preview(
            changed: [item(child.id, shrunk.worldRect, parent: board.id, frame: true)],
            touched: [item(inside, box(150, 150), parent: child.id), item(outside, box(250, 250), parent: child.id)],
            resizedFrameIDs: [child.id], frames: [board, shrunk, sibling]
        )
        check(shrunkPreview?.hints == [outside: .leaving], "Preview: only the pushed-out member shows the leaving tint")
        check(shrunkPreview?.parents == [outside: board.id], "Preview: the leaving member falls to the next frame out")
        // Clipping follows the preview parent, so the leaving member isn't
        // cut away by the frame it is leaving.
        let clipChain = FrameGeometry.ancestors(of: child.id, in: [board, shrunk, sibling],
                                                parentOverrides: [:])
        check(clipChain.map(\.id) == [child.id, board.id], "Ancestors walk from the parent outward")
        let overridden = FrameGeometry.ancestors(of: shrunkPreview?.parents[outside] ?? nil,
                                                 in: [board, shrunk, sibling],
                                                 parentOverrides: shrunkPreview?.parents ?? [:])
        check(overridden.map(\.id) == [board.id], "A leaving member clips only to its preview parent")

        // Nested: growing the board frame doesn't steal a grandchild from an
        // unresized nested frame, but a smaller frame inside it nests in.
        var wideBoard = board
        wideBoard.worldRect = CGRect(x: 0, y: 0, width: 1200, height: 1200)
        let nestedPreview = preview(
            changed: [item(board.id, wideBoard.worldRect, parent: nil, frame: true)],
            touched: [item(grandchild, box(150, 150), parent: child.id),
                      item(child.id, child.worldRect, parent: board.id, frame: true),
                      item(farImage, box(1100, 1100), parent: nil)],
            resizedFrameIDs: [board.id], frames: [wideBoard, child, sibling]
        )
        check(nestedPreview?.hints == [farImage: .joining], "Preview: nested members keep their own frame")
        // A nested frame moved by the preview carries its contents' clip along.
        let movedNest = FrameGeometry.ancestors(of: child.id, in: [board, child],
                                                parentOverrides: [child.id: nil])
        check(movedNest.map(\.id) == [child.id], "Parent overrides re-route the chain for nested frames")

        // A dropped frame captures still items centered inside its final rect.
        // The mover starts at (0, 0) and is dropped at (500, 500, 300, 300).
        let container = PlacedFrame(id: UUID(), title: "Container", worldRect: CGRect(x: 0, y: 0, width: 1200, height: 1200), zIndex: 0)
        let mover = PlacedFrame(id: UUID(), title: "Mover", worldRect: CGRect(x: 500, y: 500, width: 300, height: 300), zIndex: 1)
        let nest = PlacedFrame(id: UUID(), title: "Nest", worldRect: CGRect(x: 700, y: 520, width: 80, height: 80), zIndex: 2, parentFrameID: container.id)
        let centered = UUID()
        let passedOver = UUID()
        let nested = UUID()
        let edgeItem = UUID()
        func drop(
            _ frames: [PlacedFrame], stationary: [MembershipCandidate], finger: CGPoint
        ) -> FrameGeometry.MoveDrop {
            FrameGeometry.moveDrop(
                roots: [item(mover.id, mover.worldRect, parent: nil, frame: true)],
                stationary: stationary, finger: finger, frames: frames, moving: [mover.id]
            )
        }
        let still = [
            item(centered, box(600, 600), parent: container.id),
            // On the path from (0, 0) to (500, 500), never inside the final rect.
            item(passedOver, box(250, 250), parent: container.id),
            item(nested, box(740, 560), parent: nest.id),
            // Overlaps the final rect, but its center is outside it.
            item(edgeItem, box(805, 650), parent: container.id),
            item(nest.id, nest.worldRect, parent: container.id, frame: true),
        ]
        let landing = drop([container, mover, nest], stationary: still, finger: CGPoint(x: 520, y: 700))
        let captured = parents(landing.captures)
        check(parents(landing.rootChanges) == [mover.id: container.id],
              "A dropped frame's own parent still follows the finger")
        check(captured[centered] == mover.id, "A dropped frame captures items centered inside its final rect")
        check(captured[passedOver] == nil, "Items the frame only passed over are not captured")
        check(captured[edgeItem] == nil, "Items centered outside the final rect are not captured")
        check(captured[nest.id] == mover.id, "A smaller frame centered inside nests into the dropped frame")
        check(captured[nested] == nil, "Items in a smaller nested frame stay in it")
        check(landing.capturePreview?.hints[centered] == .joining && landing.capturePreview?.hints[passedOver] == nil,
              "Captured items show the joining tint while dragging")
        check(landing.highlightedTarget == container.id, "The frame the dragged frame lands in is highlighted")
        check(landing.memberships.count == landing.rootChanges.count + landing.captures.count,
              "The move carries root changes and captures together")

        // A frame bigger than the dropped one is never captured by it.
        let bigger = PlacedFrame(id: UUID(), title: "Bigger", worldRect: CGRect(x: 450, y: 450, width: 420, height: 420), zIndex: 3)
        let guarded = drop([mover, bigger], stationary: [item(bigger.id, bigger.worldRect, parent: nil, frame: true)],
                           finger: CGPoint(x: -100, y: -100))
        check(guarded.captures.isEmpty, "A frame never moves into a smaller dropped frame")
        check(guarded.highlightedTarget == nil, "No highlight when the destination is the current parent")

        // A frame the dropped frame lands in can't also be captured by it.
        let host = PlacedFrame(id: UUID(), title: "Host", worldRect: CGRect(x: 560, y: 560, width: 320, height: 320), zIndex: 4)
        let hosted = drop([mover, host], stationary: [item(host.id, host.worldRect, parent: nil, frame: true)],
                          finger: CGPoint(x: 600, y: 600))
        check(parents(hosted.rootChanges) == [mover.id: host.id] && hosted.captures.isEmpty,
              "A dropped frame never captures the frame it lands in")

        // Moving only images captures nothing.
        let imageDrop = FrameGeometry.moveDrop(
            roots: [item(image, box(600, 600), parent: nil)],
            stationary: [item(centered, box(600, 600), parent: nil)],
            finger: CGPoint(x: 600, y: 600), frames: [mover], moving: [image]
        )
        check(imageDrop.captures.isEmpty && parents(imageDrop.rootChanges) == [image: mover.id],
              "Dragged images join the finger's frame and capture nothing")

        // A dragged frame too big for the frame under the finger goes to the
        // next frame out that is big enough, or the board. It used to keep
        // its old parent, which hid it when it landed outside that parent.
        let oldParent = PlacedFrame(id: UUID(), title: "P", worldRect: CGRect(x: 0, y: 0, width: 1000, height: 1000), zIndex: 0)
        let draggedOut = PlacedFrame(id: UUID(), title: "M", worldRect: CGRect(x: 1200, y: 0, width: 400, height: 400), zIndex: 1, parentFrameID: oldParent.id)
        let smallOnBoard = PlacedFrame(id: UUID(), title: "S", worldRect: CGRect(x: 1300, y: 100, width: 100, height: 100), zIndex: 2)
        let mRoot = item(draggedOut.id, draggedOut.worldRect, parent: oldParent.id, frame: true)
        dropped = FrameGeometry.dropMemberships(
            roots: [mRoot], finger: CGPoint(x: 1350, y: 150),
            frames: [oldParent, draggedOut, smallOnBoard], excluding: [draggedOut.id]
        )
        check(dropped.count == 1 && dropped[0].elementID == draggedOut.id && dropped[0].parentID == nil,
              "A frame dragged out of its parent onto a smaller frame lands on the board, not in the old parent")
        let roomy = PlacedFrame(id: UUID(), title: "Q", worldRect: CGRect(x: 1100, y: -500, width: 2000, height: 2000), zIndex: 0)
        var smallInRoomy = smallOnBoard
        smallInRoomy.parentFrameID = roomy.id
        dropped = FrameGeometry.dropMemberships(
            roots: [mRoot], finger: CGPoint(x: 1350, y: 150),
            frames: [oldParent, draggedOut, smallInRoomy, roomy], excluding: [draggedOut.id]
        )
        check(parents(dropped)[draggedOut.id] == roomy.id,
              "A frame too big for the target joins the next frame out that is big enough")
        let smallInParent = PlacedFrame(id: UUID(), title: "S2", worldRect: CGRect(x: 500, y: 500, width: 100, height: 100), zIndex: 2, parentFrameID: oldParent.id)
        dropped = FrameGeometry.dropMemberships(
            roots: [item(draggedOut.id, CGRect(x: 300, y: 300, width: 400, height: 400), parent: oldParent.id, frame: true)],
            finger: CGPoint(x: 550, y: 550),
            frames: [oldParent, smallInParent], excluding: [draggedOut.id]
        )
        check(dropped.isEmpty, "A frame dropped on a small frame inside its own parent stays in that parent")
        let tooBigDrop = FrameGeometry.moveDrop(
            roots: [mRoot], stationary: [], finger: CGPoint(x: 1350, y: 150),
            frames: [oldParent, draggedOut, smallInRoomy, roomy], moving: [draggedOut.id]
        )
        check(tooBigDrop.target == smallInRoomy.id && tooBigDrop.highlightedTarget == roomy.id,
              "The highlight shows where the frame will really land, not the too-small frame under the finger")

        // The capture preview carries the dragged roots' new parents, so a
        // captured item's clip walk doesn't find the dragged frame still
        // inside the parent it is leaving.
        let capturedOutside = UUID()
        let leavingDrop = FrameGeometry.moveDrop(
            roots: [mRoot],
            stationary: [item(capturedOutside, box(1400, 200), parent: nil)],
            finger: CGPoint(x: 1500, y: 300), frames: [oldParent, draggedOut], moving: [draggedOut.id]
        )
        check(parents(leavingDrop.captures)[capturedOutside] == draggedOut.id,
              "A frame dragged out of its parent still captures what it lands on")
        let leavingPreview = leavingDrop.capturePreview
        check(leavingPreview?.parents[draggedOut.id] == .some(nil) && leavingPreview?.hints[draggedOut.id] == nil,
              "The capture preview moves the dragged frame to its new parent, without a tint on it")
        let capturedChain = FrameGeometry.ancestors(of: draggedOut.id, in: [oldParent, draggedOut],
                                                    parentOverrides: leavingPreview?.parents ?? [:])
        check(capturedChain.map(\.id) == [draggedOut.id],
              "A captured item clips to the dragged frame only, not the frame it is leaving")
        check(landing.capturePreview?.parents[mover.id] == .some(container.id),
              "The capture preview includes the dragged frame's own parent")

        // VoiceOver announcements after a membership change.
        let names = [oldParent.id: "Frame A", roomy.id: "Frame B"]
        let a1 = UUID(), a2 = UUID(), a3 = UUID()
        check(FrameMembershipAnnouncement.message(
            for: [FrameMembership(elementID: a1, parentID: oldParent.id),
                  FrameMembership(elementID: a2, parentID: oldParent.id),
                  FrameMembership(elementID: a3, parentID: nil)],
            previousParents: [a3: oldParent.id], frameNames: names
        ) == "2 items added to Frame A, 1 removed", "Announcement: adds and removes on one frame")
        check(FrameMembershipAnnouncement.message(
            for: [FrameMembership(elementID: a1, parentID: roomy.id)],
            previousParents: [a1: oldParent.id], frameNames: names
        ) == "1 item removed from Frame A; 1 item added to Frame B", "Announcement: a move between frames names both")
        check(FrameMembershipAnnouncement.message(for: [], previousParents: [:], frameNames: names) == nil,
              "Announcement: nothing changed, nothing said")

        // Equal previews compare equal, so the canvas can skip redundant writes.
        check(grownPreview == preview(
            changed: [item(child.id, grown.worldRect, parent: board.id, frame: true)],
            touched: [item(boardImage, box(450, 450), parent: board.id),
                      item(farImage, box(900, 900), parent: board.id)],
            resizedFrameIDs: [child.id], frames: [board, grown, sibling]
        ), "The same pass gives an equal preview")
        return count
    }
}

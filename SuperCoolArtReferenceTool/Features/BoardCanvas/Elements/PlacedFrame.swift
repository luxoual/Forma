import Foundation
import CoreGraphics

struct PlacedFrame: Identifiable, Equatable {
    let id: UUID
    var title: String
    var worldRect: CGRect
    var zIndex: Int
    var parentFrameID: UUID? = nil
    /// `#RRGGBB` background the user picked, or nil to derive one from the
    /// canvas color (see `FrameFill`). Mirrors `.frame(title:fillColor:)`.
    var fillHex: String? = nil
}

/// An explicit nil parent means the item belongs directly to the board.
struct FrameMembership: Equatable {
    let elementID: UUID
    let parentID: UUID?
}

/// One item whose frame might change after a gesture: its id, where it is
/// now, and which frame holds it now.
struct MembershipCandidate {
    let id: UUID
    let rect: CGRect
    let parentID: UUID?
    let isFrame: Bool

    var center: CGPoint { CGPoint(x: rect.midX, y: rect.midY) }
}

/// What a live frame resize or frame drag shows on an item it is about to
/// change.
enum FrameMembershipHint: Equatable {
    /// The item's center is inside a resized or dragged frame, so it will join it.
    case joining
    /// The item's center left the resized frame it belongs to, so it will leave.
    case leaving
}

/// The live result of a frame resize or frame drag, before release: what each item
/// would show, and where it would land, if the finger lifted now.
///
/// It is `Equatable` so the canvas can skip storing an unchanged preview.
/// Most drag updates change no one's frame, and storing an equal value
/// would still redraw every view that reads it.
struct MembershipPreview: Equatable {
    /// The tint each joining or leaving item shows.
    var hints: [UUID: FrameMembershipHint]
    /// The frame each changing item will have. A nil value means the board.
    /// Clipping reads these as overrides (`FrameGeometry.ancestors(of:in:parentOverrides:)`),
    /// so a leaving member isn't cut away by the frame it is leaving.
    var parents: [UUID: UUID?]
}

/// Geometry shared by dropping, clipping, and interaction tests.
enum FrameGeometry {
    /// The frames around an item, innermost first, starting at `parentID`.
    ///
    /// `parentOverrides` swaps in a different parent for listed frames, as
    /// a live resize preview does (`MembershipPreview.parents`). This walks
    /// the chain directly instead of building a `Hierarchy`, because the
    /// canvas calls it once per item on every redraw.
    static func ancestors(
        of parentID: UUID?,
        in frames: [PlacedFrame],
        parentOverrides: [UUID: UUID?] = [:]
    ) -> [PlacedFrame] {
        guard parentID != nil else { return [] }
        var lookup = Dictionary(frames.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for (id, parent) in parentOverrides where lookup[id] != nil {
            lookup[id]?.parentFrameID = parent
        }
        return chain(from: parentID, in: lookup)
    }

    /// Walks up from `id` through `lookup`, stopping at the board, at an id
    /// that names no frame, or when a malformed cycle repeats a frame.
    fileprivate static func chain(from id: UUID?, in lookup: [UUID: PlacedFrame]) -> [PlacedFrame] {
        var result: [PlacedFrame] = []
        var visited: Set<UUID> = []
        var next = id
        while let id = next, visited.insert(id).inserted, let frame = lookup[id] {
            result.append(frame)
            next = frame.parentFrameID
        }
        return result
    }

    /// Operate on the selected containers, not on their selected descendants
    /// a second time. This keeps an existing subtree intact when regrouping.
    static func selectionRoots(_ ids: Set<UUID>, parents: [UUID: UUID], frames: [PlacedFrame]) -> Set<UUID> {
        let hierarchy = Hierarchy(frames)
        return ids.filter { id in
            !hierarchy.ancestors(of: parents[id]).contains { ids.contains($0.id) }
        }
    }

    static func clipRect(parentID: UUID?, frames: [PlacedFrame]) -> CGRect? {
        clip(of: ancestors(of: parentID, in: frames))
    }

    /// The area left after every frame in `chain` cuts it, or nil for none.
    fileprivate static func clip(of chain: [PlacedFrame]) -> CGRect? {
        chain.reduce(nil as CGRect?) { clip, frame in
            clip.map { $0.intersection(frame.worldRect) } ?? frame.worldRect
        }
    }

    /// The innermost frame whose visible area holds `point`, or nil for the
    /// board. `largerThan` keeps a frame from landing inside a smaller frame,
    /// where the smaller one's bounds would hide most of it. `allowing` names
    /// one frame that may be the answer even when it is too small: the
    /// parent a frame already has.
    static func dropTarget(
        at point: CGPoint,
        frames: [PlacedFrame],
        excluding: Set<UUID>,
        largerThan area: CGFloat? = nil,
        allowing kept: UUID? = nil
    ) -> UUID? {
        Hierarchy(frames).owner(at: point, excluding: excluding, largerThan: area, allowing: kept)
    }

    /// The order frames are drawn in, bottom to top. A parent always comes
    /// before its children, so a child frame is never hidden under its
    /// parent's fill. Siblings follow `zIndex`. Each subtree is drawn as one
    /// block, so an unrelated frame stacked above a parent also covers that
    /// parent's child frames, the same as it covers the parent.
    ///
    /// A parent id that names no frame counts as the board. Frames caught in
    /// a malformed parent cycle are never reached from the board, so they go
    /// last, in `zIndex` order, instead of being dropped.
    static func drawOrder(_ frames: [PlacedFrame]) -> [PlacedFrame] {
        let ids = Set(frames.map(\.id))
        let children = Dictionary(grouping: frames) { frame in
            frame.parentFrameID.flatMap { ids.contains($0) ? $0 : nil }
        }
        func byZ(_ lhs: PlacedFrame, _ rhs: PlacedFrame) -> Bool {
            lhs.zIndex != rhs.zIndex ? lhs.zIndex < rhs.zIndex : lhs.id.uuidString < rhs.id.uuidString
        }
        var order: [PlacedFrame] = []
        var visited: Set<UUID> = []
        func visit(_ frame: PlacedFrame) {
            guard visited.insert(frame.id).inserted else { return }
            order.append(frame)
            for child in (children[frame.id] ?? []).sorted(by: byZ) { visit(child) }
        }
        for root in (children[nil] ?? []).sorted(by: byZ) { visit(root) }
        for frame in frames.sorted(by: byZ) where !visited.contains(frame.id) { visit(frame) }
        return order
    }

    /// Works out which frame each item should belong to after a gesture
    /// ends, and returns only the items whose frame changes.
    ///
    /// The rule: an item belongs to the innermost frame whose visible area
    /// holds its center (`dropTarget`'s rule). Two kinds of item get checked:
    ///
    /// - `changed`: items whose own position or size changed. They get the
    ///   rule in full.
    /// - `touched`: items that a resized frame's old or new bounds overlap.
    ///   Their own geometry didn't change, so they only react to the resized
    ///   frames. A member whose center is now outside its resized frame
    ///   leaves, to wherever the rule sends it. An item whose answer is now a
    ///   resized frame joins it. Anything else keeps its frame, so a resize
    ///   can't quietly undo a Remove Frame somewhere else.
    ///
    /// `frames` must hold every frame at its final bounds. `excluding` names
    /// frames that can't take anyone, such as frames being dragged.
    ///
    /// Cycles can't form. An item never targets itself or anything inside
    /// it, and a frame never moves into a smaller frame (it may stay in the
    /// one it's already in). Frames are settled
    /// first, biggest first, because an item's answer depends on how the
    /// frames around it are nested.
    static func reassign(
        changed: [MembershipCandidate],
        touched: [MembershipCandidate] = [],
        resizedFrameIDs: Set<UUID> = [],
        frames: [PlacedFrame],
        excluding: Set<UUID> = []
    ) -> [FrameMembership] {
        var hierarchy = Hierarchy(frames)
        let changedIDs = Set(changed.map(\.id))
        var seen: Set<UUID> = []
        let work = (changed.map { ($0, true) } + touched.map { ($0, false) })
            .filter { item, isChanged in
                (isChanged || !changedIDs.contains(item.id)) && seen.insert(item.id).inserted
            }
            .sorted { lhs, rhs in
                if lhs.0.isFrame != rhs.0.isFrame { return lhs.0.isFrame }
                let leftArea = area(lhs.0.rect)
                let rightArea = area(rhs.0.rect)
                if leftArea != rightArea { return leftArea > rightArea }
                return lhs.0.id.uuidString < rhs.0.id.uuidString
            }

        var result: [FrameMembership] = []
        for (item, isChanged) in work {
            var blocked = excluding
            blocked.insert(item.id)
            if item.isFrame { blocked.formUnion(hierarchy.subtree(of: item.id)) }
            let owner = hierarchy.owner(
                at: item.center, excluding: blocked,
                largerThan: item.isFrame ? area(item.rect) : nil,
                allowing: item.parentID
            )

            let newParent: UUID?
            if isChanged {
                newParent = owner
            } else if let parent = item.parentID, resizedFrameIDs.contains(parent),
                      let parentFrame = hierarchy.lookup[parent],
                      !parentFrame.worldRect.contains(item.center) {
                newParent = owner
            } else if let owner, resizedFrameIDs.contains(owner) {
                newParent = owner
            } else {
                newParent = item.parentID
            }
            guard newParent != item.parentID else { continue }
            result.append(FrameMembership(elementID: item.id, parentID: newParent))
            if item.isFrame { hierarchy.setParent(newParent, of: item.id) }
        }
        return result
    }

    /// Where a dragged selection lands. The whole selection gets one answer:
    /// the innermost visible frame under the finger at the drop point, or
    /// the board. Checking each item's own center split a selection dropped
    /// across a frame edge, with some items joining and others not.
    ///
    /// `roots` are the dragged items whose own frame may change. Their
    /// descendants travel along and keep their parents. `excluding` must
    /// name every moving frame and everything inside them, so nothing lands
    /// inside itself. The other roots still join the target. Returns only
    /// real changes.
    ///
    /// A dragged frame bigger than the target can't join it (a frame never
    /// moves into a smaller frame). It goes to the next frame out under the
    /// finger that is big enough, or to the board. Its current parent counts
    /// as big enough, so a frame dropped inside the parent it already has
    /// stays there.
    ///
    /// It used to keep its old parent no matter where it landed. Drag frame
    /// M out of its parent P and let the finger land on a small frame S, and
    /// M kept P as parent while sitting wholly outside P. P's clipping then
    /// hid all of M.
    static func dropMemberships(
        roots: [MembershipCandidate],
        finger: CGPoint,
        frames: [PlacedFrame],
        excluding: Set<UUID>
    ) -> [FrameMembership] {
        let hierarchy = Hierarchy(frames)
        let target = hierarchy.owner(at: finger, excluding: excluding, largerThan: nil)
        return dropMemberships(roots: roots, target: target, finger: finger,
                               hierarchy: hierarchy, excluding: excluding)
    }

    /// `dropMemberships` once the frame under the finger is known.
    private static func dropMemberships(
        roots: [MembershipCandidate],
        target: UUID?,
        finger: CGPoint,
        hierarchy: Hierarchy,
        excluding: Set<UUID>
    ) -> [FrameMembership] {
        let targetArea = target.flatMap { hierarchy.lookup[$0] }.map { area($0.worldRect) }
        return roots.compactMap { root in
            var newParent = target
            if root.isFrame, let targetArea, targetArea <= area(root.rect) {
                newParent = hierarchy.owner(at: finger, excluding: excluding,
                                            largerThan: area(root.rect), allowing: root.parentID)
            }
            guard newParent != root.parentID else { return nil }
            return FrameMembership(elementID: root.id, parentID: newParent)
        }
    }

    /// Everything a dropped selection does to frame membership.
    struct MoveDrop: Equatable {
        /// The frame under the finger, or nil for the board.
        var target: UUID?
        /// The dragged roots whose own frame changes (`dropMemberships`).
        var rootChanges: [FrameMembership]
        /// Items that stayed still and join a dragged frame, because their
        /// center sits inside its final rect.
        var captures: [FrameMembership]

        /// Both lists, as one `.move` command carries them.
        var memberships: [FrameMembership] { rootChanges + captures }

        /// The frame to highlight while dragging: the frame some dragged
        /// root would actually move into. Usually that is the target. A
        /// dragged frame too big for the target goes to a bigger frame
        /// further out instead, and when that is the only change, that
        /// bigger frame is the one highlighted. Nil when nothing changes
        /// frame, or when the selection lands on the board.
        var highlightedTarget: UUID? {
            let destinations = Set(rootChanges.compactMap(\.parentID))
            if let target, destinations.contains(target) { return target }
            return destinations.count == 1 ? destinations.first : nil
        }

        /// The joining tint for the captured items, and the preview parents
        /// for them and for the dragged roots. Nil when nothing is captured.
        ///
        /// The roots' new parents must be in the preview too. Clipping walks
        /// up from a captured item through the dragged frame to that frame's
        /// parent. Without the roots' entries, the walk still found the
        /// dragged frame inside its old parent, so a frame dragged out of
        /// its parent had its captured items, and their outline, clipped
        /// away by the parent it was leaving.
        var capturePreview: MembershipPreview? {
            guard !captures.isEmpty else { return nil }
            var hints: [UUID: FrameMembershipHint] = [:]
            var parents: [UUID: UUID?] = [:]
            for change in rootChanges {
                parents[change.elementID] = change.parentID
            }
            for capture in captures {
                hints[capture.elementID] = .joining
                parents[capture.elementID] = capture.parentID
            }
            return MembershipPreview(hints: hints, parents: parents)
        }
    }

    /// What dropping a dragged selection does: where the dragged roots land
    /// (`dropMemberships`, from the finger), and which still items the
    /// dragged frames capture.
    ///
    /// A dragged frame works like a frame resized to its final rect. Every
    /// still item whose center lies inside that rect is checked with the
    /// innermost-frame rule (`reassign`). It joins only when a dragged frame
    /// is now the innermost frame around its center. So an item already in
    /// a smaller frame inside that area stays there, and a frame never moves
    /// into a smaller frame. Only the final rect counts: items the frame
    /// passed over on the way are never looked at.
    ///
    /// - `roots`: the dragged roots, at their final rects.
    /// - `stationary`: items that did not move. Only those centered inside
    ///   a dragged frame's final rect are checked; the rest are ignored.
    /// - `frames`: every frame, with the dragged ones at their final rects.
    /// - `moving`: every dragged item and everything inside them. These can
    ///   neither be the drop target nor be captured.
    static func moveDrop(
        roots: [MembershipCandidate],
        stationary: [MembershipCandidate],
        finger: CGPoint,
        frames: [PlacedFrame],
        moving: Set<UUID>
    ) -> MoveDrop {
        let hierarchy = Hierarchy(frames)
        let target = hierarchy.owner(at: finger, excluding: moving, largerThan: nil)
        let rootChanges = dropMemberships(roots: roots, target: target, finger: finger,
                                          hierarchy: hierarchy, excluding: moving)

        let movingFrames = frames.filter { moving.contains($0.id) }
        guard !movingFrames.isEmpty else {
            return MoveDrop(target: target, rootChanges: rootChanges, captures: [])
        }

        // The roots' new parents must be in place before the capture pass,
        // so it sees the nesting the drop creates. That is also what stops
        // a cycle: a frame the dragged frame drops into is its ancestor now,
        // so it can't be captured by it.
        var landed = frames
        let newParents = Dictionary(rootChanges.map { ($0.elementID, $0.parentID) },
                                    uniquingKeysWith: { _, last in last })
        for index in landed.indices {
            if let parent = newParents[landed[index].id] { landed[index].parentFrameID = parent }
        }

        let touched = stationary.filter { item in
            !moving.contains(item.id) && movingFrames.contains { $0.worldRect.contains(item.center) }
        }
        let captures = reassign(
            changed: [], touched: touched,
            resizedFrameIDs: Set(movingFrames.map(\.id)), frames: landed
        )
        return MoveDrop(target: target, rootChanges: rootChanges, captures: captures)
    }

    /// The live-resize tint for each change `reassign` reported: joining
    /// when the new frame is one being resized, leaving when the old one is.
    static func hints(
        for changes: [FrameMembership],
        previousParents: [UUID: UUID?],
        resizedFrameIDs: Set<UUID>
    ) -> [UUID: FrameMembershipHint] {
        var hints: [UUID: FrameMembershipHint] = [:]
        for change in changes {
            if let parent = change.parentID, resizedFrameIDs.contains(parent) {
                hints[change.elementID] = .joining
            } else if let old = previousParents[change.elementID] ?? nil, resizedFrameIDs.contains(old) {
                hints[change.elementID] = .leaving
            }
        }
        return hints
    }

    /// The live preview of a frame resize: the same pass the commit runs
    /// (`reassign`), turned into tints and preview parents.
    ///
    /// Returns nil when no frame is being resized. Resizing only images and
    /// text can't pull anything in or push anything out.
    ///
    /// Each item's previous parent is read from its candidate, so the
    /// caller doesn't have to look anyone up again.
    static func membershipPreview(
        changed: [MembershipCandidate],
        touched: [MembershipCandidate],
        resizedFrameIDs: Set<UUID>,
        frames: [PlacedFrame]
    ) -> MembershipPreview? {
        guard !resizedFrameIDs.isEmpty else { return nil }
        let changes = reassign(changed: changed, touched: touched,
                               resizedFrameIDs: resizedFrameIDs, frames: frames)
        var previousParents: [UUID: UUID?] = [:]
        for item in touched { previousParents[item.id] = item.parentID }
        // A changed item's own entry wins, the same as in `reassign`.
        for item in changed { previousParents[item.id] = item.parentID }
        var parents: [UUID: UUID?] = [:]
        for change in changes { parents[change.elementID] = change.parentID }
        return MembershipPreview(
            hints: hints(for: changes, previousParents: previousParents, resizedFrameIDs: resizedFrameIDs),
            parents: parents
        )
    }

    static func area(_ rect: CGRect) -> CGFloat { rect.width * rect.height }

    /// Frames indexed by id, with the facts the membership pass asks about
    /// each frame worked out once up front.
    ///
    /// `owner` checks every frame for every item. It used to rebuild each
    /// frame's parent chain, depth, and clip for each item, so a pass over
    /// many items redid the same walks over and over. Now they are cached
    /// here: a pass does them once per frame.
    ///
    /// `reassign` changes frame parents as it goes. It must do that through
    /// `setParent`, which refreshes the caches, so later answers see the
    /// new nesting.
    struct Hierarchy {
        private(set) var lookup: [UUID: PlacedFrame]
        /// Each frame's chain from itself out to the board (index 0 is the
        /// frame itself).
        private var chains: [UUID: [PlacedFrame]] = [:]
        /// Each frame's visible area: its bounds cut by every frame around it.
        private var visibleRects: [UUID: CGRect] = [:]
        /// The frames directly inside each frame.
        private var children: [UUID: [UUID]] = [:]

        init(_ frames: [PlacedFrame]) {
            lookup = Dictionary(frames.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            rebuildCaches()
        }

        mutating func setParent(_ parentID: UUID?, of id: UUID) {
            guard lookup[id] != nil else { return }
            lookup[id]?.parentFrameID = parentID
            rebuildCaches()
        }

        private mutating func rebuildCaches() {
            chains = [:]
            visibleRects = [:]
            children = [:]
            for (id, frame) in lookup {
                let chain = FrameGeometry.chain(from: id, in: lookup)
                chains[id] = chain
                visibleRects[id] = FrameGeometry.clip(of: chain)
                if let parent = frame.parentFrameID, lookup[parent] != nil {
                    children[parent, default: []].append(id)
                }
            }
        }

        func ancestors(of parentID: UUID?) -> [PlacedFrame] {
            parentID.flatMap { chains[$0] } ?? []
        }

        func clipRect(parentID: UUID?) -> CGRect? {
            parentID.flatMap { visibleRects[$0] }
        }

        /// How many frames sit around `frame`. Zero for a frame on the board.
        private func depth(of frame: PlacedFrame) -> Int {
            ancestors(of: frame.parentFrameID).count
        }

        /// `id` and every frame nested anywhere inside it.
        func subtree(of id: UUID) -> Set<UUID> {
            var result: Set<UUID> = [id]
            var queue = [id]
            while let next = queue.popLast() {
                for child in children[next] ?? [] where result.insert(child).inserted {
                    queue.append(child)
                }
            }
            return result
        }

        /// `allowing` names a frame that may stay the answer even when it is
        /// smaller than `minimumArea`: a frame grown past its parent's size
        /// stays in that parent rather than popping out.
        func owner(
            at point: CGPoint,
            excluding: Set<UUID>,
            largerThan minimumArea: CGFloat?,
            allowing kept: UUID? = nil
        ) -> UUID? {
            let hits = lookup.values.filter { frame in
                !excluding.contains(frame.id) && frame.worldRect.contains(point) &&
                (frame.id == kept || minimumArea.map { FrameGeometry.area(frame.worldRect) > $0 } ?? true) &&
                (clipRect(parentID: frame.parentFrameID)?.contains(point) ?? true)
            }
            // Deepest first, then smallest, then topmost: the innermost frame.
            let ranked = hits.map { frame in (frame: frame, depth: depth(of: frame)) }
            return ranked.min { lhs, rhs in
                if lhs.depth != rhs.depth { return lhs.depth > rhs.depth }
                let leftArea = FrameGeometry.area(lhs.frame.worldRect)
                let rightArea = FrameGeometry.area(rhs.frame.worldRect)
                if leftArea != rightArea { return leftArea < rightArea }
                if lhs.frame.zIndex != rhs.frame.zIndex { return lhs.frame.zIndex > rhs.frame.zIndex }
                return lhs.frame.id.uuidString < rhs.frame.id.uuidString
            }?.frame.id
        }
    }
}

/// The sentence VoiceOver reads after a gesture changes which frame items
/// belong to. Hints on screen show the change only to people who can see
/// them, so each commit that moves items between frames also says it out
/// loud, for example "2 items added to Frame A, 1 removed".
enum FrameMembershipAnnouncement {
    /// One phrase per frame that gained or lost items, in the order the
    /// frames first appear in `changes`. Moves to or from the board aren't
    /// named on their own: an item that leaves Frame A for the board reads
    /// as "1 item removed from Frame A". Nil when nothing named changed.
    ///
    /// - `previousParents`: each changed item's frame before the gesture.
    ///   A missing entry counts as the board.
    /// - `frameNames`: frame titles by id. A frame with no name here is
    ///   called "a frame".
    static func message(
        for changes: [FrameMembership],
        previousParents: [UUID: UUID?],
        frameNames: [UUID: String]
    ) -> String? {
        var order: [UUID] = []
        var added: [UUID: Int] = [:]
        var removed: [UUID: Int] = [:]
        func note(_ id: UUID) {
            if added[id] == nil && removed[id] == nil { order.append(id) }
        }
        for change in changes {
            let old = previousParents[change.elementID] ?? nil
            guard old != change.parentID else { continue }
            if let old {
                note(old)
                removed[old, default: 0] += 1
            }
            if let new = change.parentID {
                note(new)
                added[new, default: 0] += 1
            }
        }
        func items(_ count: Int) -> String { count == 1 ? "1 item" : "\(count) items" }
        let phrases = order.map { id -> String in
            let name = frameNames[id] ?? "a frame"
            switch (added[id] ?? 0, removed[id] ?? 0) {
            case (let gained, 0): return "\(items(gained)) added to \(name)"
            case (0, let lost): return "\(items(lost)) removed from \(name)"
            case (let gained, let lost): return "\(items(gained)) added to \(name), \(lost) removed"
            }
        }
        return phrases.isEmpty ? nil : phrases.joined(separator: "; ")
    }
}

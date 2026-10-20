import CoreGraphics

/// Where a box goes when one of its resize handles is dragged.
///
/// Pure math with no view state: the canvas passes in the zoom, the flip
/// margin, and the smallest allowed size. That keeps it testable on its own
/// (`tests/ResizeGeometryChecks.swift`).
enum ResizeGeometry {
    /// Which side of the anchor the box sits on, per axis. `true` means the
    /// drag has carried the box past its anchor on that axis.
    typealias Flip = (x: Bool, y: Bool)

    /// The new box for a handle drag on `startRect`.
    ///
    /// The handle's opposite corner or edge (the anchor) stays fixed. The
    /// box spans from the anchor to the finger, so dragging past the anchor
    /// moves the box to the other side of it (Figma-style flip). Content
    /// never mirrors; only the box moves.
    ///
    /// `flipped` says which side the box was on last update. The box only
    /// flips back once the finger is `flipMarginPoints` past the anchor, so
    /// a finger resting right on the anchor doesn't make the box flicker
    /// between sides. That margin is the hysteresis.
    ///
    /// At `minDimension` the box holds its size and jumps across the anchor
    /// when the finger does.
    ///
    /// - Parameters:
    ///   - translation: how far the finger has moved, in screen points.
    ///   - scale: the canvas zoom, to turn screen points into world units.
    ///   - flipMarginPoints: the hysteresis, in screen points.
    ///   - minDimension: the smallest width or height, in world units.
    ///   - lockAspectRatio: whether a corner drag keeps the box's shape.
    static func resizedRect(
        handle: HandlePosition,
        startRect: CGRect,
        translation: CGSize,
        flipped: Flip,
        scale: CGFloat,
        flipMarginPoints: CGFloat,
        minDimension: CGFloat,
        lockAspectRatio: Bool = true
    ) -> (rect: CGRect, flipped: Flip) {
        let worldDX = translation.width / scale
        let worldDY = translation.height / scale
        let margin = flipMarginPoints / scale

        let anchorPt = handle.anchorPosition.point(in: startRect.size)
        let anchorWorld = CGPoint(
            x: startRect.origin.x + anchorPt.x,
            y: startRect.origin.y + anchorPt.y
        )
        let handlePt = handle.point(in: startRect.size)
        let draggedWorld = CGPoint(
            x: startRect.origin.x + handlePt.x + worldDX,
            y: startRect.origin.y + handlePt.y + worldDY
        )

        // Decide which side of the anchor the box sits on, per axis.
        // `reach` is how far the finger is from the anchor in the handle's
        // own direction: positive means the usual side, negative means past
        // the anchor. Crossing the anchor flips; coming back needs `margin`.
        func resolveFlip(direction: CGFloat, finger: CGFloat, anchor: CGFloat, wasFlipped: Bool) -> Bool {
            guard direction != 0 else { return false }
            let reach = (finger - anchor) * direction
            return wasFlipped ? reach < margin : reach < 0
        }
        let flipX = resolveFlip(direction: handle.xDirection, finger: draggedWorld.x,
                                anchor: anchorWorld.x, wasFlipped: flipped.x)
        let flipY = resolveFlip(direction: handle.yDirection, finger: draggedWorld.y,
                                anchor: anchorWorld.y, wasFlipped: flipped.y)
        // Which way the box extends from the anchor: -1 left/up, +1 right/down.
        let sideX = flipX ? -handle.xDirection : handle.xDirection
        let sideY = flipY ? -handle.yDirection : handle.yDirection

        var width = startRect.width
        var height = startRect.height

        if handle.isCorner {
            // Work in sizes (always positive), then place them on the
            // chosen side. That way the aspect lock never sees a sign, and
            // a flip on one axis only falls out of `sideX` / `sideY`.
            let aspect = startRect.width / max(startRect.height, 0.001)
            width = abs(draggedWorld.x - anchorWorld.x)
            height = abs(draggedWorld.y - anchorWorld.y)

            if lockAspectRatio {
                if width / max(aspect, 0.001) > height {
                    height = width / aspect
                } else {
                    width = height * aspect
                }
            }

            width = max(width, minDimension)
            height = max(height, lockAspectRatio ? minDimension / max(aspect, 0.001) : minDimension)
        } else if handle.xDirection != 0 {
            width = max(abs(draggedWorld.x - anchorWorld.x), minDimension)
        } else {
            height = max(abs(draggedWorld.y - anchorWorld.y), minDimension)
        }

        // An edge handle leaves the other axis alone (`side` is 0 there).
        let originX: CGFloat
        if sideX < 0 { originX = anchorWorld.x - width }
        else if sideX > 0 { originX = anchorWorld.x }
        else { originX = startRect.origin.x }
        let originY: CGFloat
        if sideY < 0 { originY = anchorWorld.y - height }
        else if sideY > 0 { originY = anchorWorld.y }
        else { originY = startRect.origin.y }

        return (CGRect(x: originX, y: originY, width: width, height: height), (flipX, flipY))
    }
}

import Foundation
import CoreGraphics

// Compile-only checks for the resize/flip math. Run with:
// swiftc -module-cache-path /tmp/forma-swift-cache \
//   SuperCoolArtReferenceTool/Features/BoardCanvas/Selection/HandlePosition.swift \
//   SuperCoolArtReferenceTool/Features/BoardCanvas/Selection/ResizeGeometry.swift \
//   tests/ResizeGeometryChecks.swift -o /tmp/forma-resize-checks && /tmp/forma-resize-checks
@main
struct ResizeGeometryChecks {
    static func main() {
        var count = 0
        func check(_ condition: Bool, _ message: String) {
            precondition(condition, message)
            count += 1
        }

        // A 100 x 50 box at the origin, zoom 1, 6pt margin, 10-unit floor.
        let box = CGRect(x: 0, y: 0, width: 100, height: 50)
        func resize(
            _ handle: HandlePosition, dx: CGFloat, dy: CGFloat,
            flipped: ResizeGeometry.Flip = (false, false),
            scale: CGFloat = 1, minDimension: CGFloat = 10, lock: Bool = false
        ) -> (rect: CGRect, flipped: ResizeGeometry.Flip) {
            ResizeGeometry.resizedRect(
                handle: handle, startRect: box, translation: CGSize(width: dx, height: dy),
                flipped: flipped, scale: scale, flipMarginPoints: 6,
                minDimension: minDimension, lockAspectRatio: lock
            )
        }

        // Plain resize: the anchor (top-left) stays put.
        var result = resize(.bottomRight, dx: 20, dy: 10)
        check(result.rect == CGRect(x: 0, y: 0, width: 120, height: 60), "A corner drag grows away from the anchor")
        check(!result.flipped.x && !result.flipped.y, "No flip without crossing the anchor")

        // Corner flip: drag bottom-right past the top-left anchor on both axes.
        result = resize(.bottomRight, dx: -130, dy: -80)
        check(result.rect == CGRect(x: -30, y: -30, width: 30, height: 30), "A corner flip moves the box to the anchor's other side")
        check(result.flipped.x && result.flipped.y, "A corner flip flips both axes")

        // One-axis flip: cross only horizontally.
        result = resize(.bottomRight, dx: -130, dy: 10)
        check(result.rect == CGRect(x: -30, y: 0, width: 30, height: 60), "A one-axis flip leaves the other axis on its usual side")
        check(result.flipped.x && !result.flipped.y, "Only the crossed axis flips")

        // Edge flip: drag the right edge past the left edge. Height never changes.
        result = resize(.rightCenter, dx: -150, dy: 40)
        check(result.rect == CGRect(x: -50, y: 0, width: 50, height: 50), "An edge flip moves the box across the anchor edge")
        check(result.flipped.x && !result.flipped.y, "An edge handle never flips the axis it doesn't sit on")
        result = resize(.topCenter, dx: 0, dy: 80)
        check(result.rect == CGRect(x: 0, y: 50, width: 100, height: 30), "A top edge dragged below the bottom flips downward")

        // Hysteresis: once flipped, the box stays flipped until the finger is
        // 6pt back past the anchor. The anchor of .bottomRight is x = 0, and
        // the handle starts at x = 100, so dx = -97 puts the finger 3 past it.
        result = resize(.rightCenter, dx: -97, dy: 0, flipped: (true, false))
        check(result.flipped.x, "Inside the margin a flipped box stays flipped")
        result = resize(.rightCenter, dx: -97, dy: 0, flipped: (false, false))
        check(!result.flipped.x, "The same spot unflipped stays unflipped")
        result = resize(.rightCenter, dx: -93, dy: 0, flipped: (true, false))
        check(!result.flipped.x, "Past the margin the box flips back")
        // The margin is in screen points: at 2x zoom, 6pt is 3 world units.
        result = resize(.rightCenter, dx: -196, dy: 0, flipped: (true, false), scale: 2)
        check(result.flipped.x, "At 2x zoom, 2 world units back (4pt) is still inside the margin")
        result = resize(.rightCenter, dx: -190, dy: 0, flipped: (true, false), scale: 2)
        check(!result.flipped.x, "At 2x zoom, 5 world units back (10pt) is past the margin")

        // Min-size jump: at the floor the box holds its size and jumps across
        // the anchor as soon as the finger crosses it.
        result = resize(.rightCenter, dx: -98, dy: 0)
        check(result.rect == CGRect(x: 0, y: 0, width: 10, height: 50), "Near the anchor the box holds at the minimum size")
        result = resize(.rightCenter, dx: -102, dy: 0)
        check(result.rect == CGRect(x: -10, y: 0, width: 10, height: 50), "Crossing the anchor at the floor jumps the box to the other side")

        // Aspect lock: a corner drag keeps 2:1 even when flipped.
        result = resize(.bottomRight, dx: 100, dy: 0, lock: true)
        check(result.rect == CGRect(x: 0, y: 0, width: 200, height: 100), "Aspect lock keeps the shape on a corner drag")
        result = resize(.bottomRight, dx: -300, dy: -60, lock: true)
        check(result.rect == CGRect(x: -200, y: -100, width: 200, height: 100), "Aspect lock keeps the shape after a flip")
        result = resize(.bottomRight, dx: 50, dy: 0, lock: false)
        check(result.rect.size == CGSize(width: 150, height: 50), "Without the lock a corner drag stretches freely")

        // The highlighted handle mirrors with the flip; (1, 1) is listed explicitly.
        check(HandlePosition.topLeft.flipped(horizontally: true, vertically: true) == .bottomRight, "Flipping top-left both ways gives bottom-right")
        check(HandlePosition.topRight.flipped(horizontally: true, vertically: false) == .topLeft, "Flipping top-right horizontally gives top-left")
        check(HandlePosition.topCenter.flipped(horizontally: true, vertically: false) == .topCenter, "An edge doesn't flip on the axis it doesn't sit on")
        for handle in HandlePosition.allCases {
            check(handle.flipped(horizontally: false, vertically: false) == handle, "No flip leaves \(handle) as is")
        }

        print("\(count) resize geometry checks passed")
    }
}

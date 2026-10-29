import CoreGraphics

enum HandlePosition: CaseIterable {
    case topLeft, topCenter, topRight
    case leftCenter, rightCenter
    case bottomLeft, bottomCenter, bottomRight

    /// The four corner handles. Images and multi-selections offer only
    /// these: a corner drag keeps shapes, while an edge drag would squash
    /// them. Text adds its left/right edges for wrap width
    /// (`TextElementView.textHandles`). A single frame is an empty box, so
    /// it keeps all 8.
    static let corners: Set<HandlePosition> = [.topLeft, .topRight, .bottomLeft, .bottomRight]

    func point(in size: CGSize) -> CGPoint {
        switch self {
        case .topLeft:      return CGPoint(x: 0, y: 0)
        case .topCenter:    return CGPoint(x: size.width / 2, y: 0)
        case .topRight:     return CGPoint(x: size.width, y: 0)
        case .leftCenter:   return CGPoint(x: 0, y: size.height / 2)
        case .rightCenter:  return CGPoint(x: size.width, y: size.height / 2)
        case .bottomLeft:   return CGPoint(x: 0, y: size.height)
        case .bottomCenter: return CGPoint(x: size.width / 2, y: size.height)
        case .bottomRight:  return CGPoint(x: size.width, y: size.height)
        }
    }

    /// The corner/edge that stays fixed during resize
    var anchorPosition: HandlePosition {
        switch self {
        case .topLeft:      return .bottomRight
        case .topCenter:    return .bottomCenter
        case .topRight:     return .bottomLeft
        case .leftCenter:   return .rightCenter
        case .rightCenter:  return .leftCenter
        case .bottomLeft:   return .topRight
        case .bottomCenter: return .topCenter
        case .bottomRight:  return .topLeft
        }
    }

    /// Which way this handle points away from its anchor on each axis:
    /// -1 for left/top, +1 for right/bottom, 0 when the handle sits on the
    /// middle of that axis (an edge handle doesn't move that axis at all).
    var xDirection: CGFloat {
        switch self {
        case .topLeft, .leftCenter, .bottomLeft: return -1
        case .topRight, .rightCenter, .bottomRight: return 1
        case .topCenter, .bottomCenter: return 0
        }
    }

    var yDirection: CGFloat {
        switch self {
        case .topLeft, .topCenter, .topRight: return -1
        case .bottomLeft, .bottomCenter, .bottomRight: return 1
        case .leftCenter, .rightCenter: return 0
        }
    }

    /// The handle in the mirror-image spot. Used when a resize drag crosses
    /// the anchor: dragging `.topRight` past the anchor horizontally turns
    /// it into `.topLeft`. Asking to flip an axis the handle doesn't sit on
    /// (say, `.topCenter` horizontally) changes nothing on that axis.
    func flipped(horizontally: Bool, vertically: Bool) -> HandlePosition {
        var x = xDirection
        var y = yDirection
        if horizontally { x = -x }
        if vertically { y = -y }
        switch (x, y) {
        case (-1, -1): return .topLeft
        case (0, -1):  return .topCenter
        case (1, -1):  return .topRight
        case (-1, 0):  return .leftCenter
        case (1, 0):   return .rightCenter
        case (-1, 1):  return .bottomLeft
        case (0, 1):   return .bottomCenter
        case (1, 1):   return .bottomRight
        default:
            // (0, 0) would be the box's center, where no handle sits. Every
            // handle has a direction on at least one axis, and flipping
            // only changes signs, so this can't happen. Swift still needs a
            // default because the values are `CGFloat`s.
            assertionFailure("No handle at direction (\(x), \(y))")
            return self
        }
    }

    /// Whether this is a corner handle (aspect-ratio locked resize)
    var isCorner: Bool {
        switch self {
        case .topLeft, .topRight, .bottomLeft, .bottomRight: return true
        default: return false
        }
    }

    /// Whether dragging this handle means the left edge moves
    var isLeftSide: Bool {
        switch self {
        case .topLeft, .leftCenter, .bottomLeft: return true
        default: return false
        }
    }

    /// Whether dragging this handle means the top edge moves
    var isTopSide: Bool {
        switch self {
        case .topLeft, .topCenter, .topRight: return true
        default: return false
        }
    }
}

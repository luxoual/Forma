import CoreGraphics

enum HandlePosition: CaseIterable {
    case topLeft, topCenter, topRight
    case leftCenter, rightCenter
    case bottomLeft, bottomCenter, bottomRight

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

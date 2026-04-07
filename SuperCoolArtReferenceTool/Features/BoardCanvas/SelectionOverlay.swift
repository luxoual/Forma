import SwiftUI

struct SelectionOverlay: View {
    private let handleSize: CGFloat = 10
    private let borderWidth: CGFloat = 2

    var body: some View {
        GeometryReader { geo in
            // Border
            Rectangle()
                .strokeBorder(DesignSystem.Colors.tertiary, lineWidth: borderWidth)

            // Corner handles
            ForEach(HandlePosition.allCases, id: \.self) { position in
                handleView
                    .position(position.point(in: geo.size))
            }
        }
    }

    private var handleView: some View {
        RoundedRectangle(cornerRadius: 2)
            .fill(Color.white)
            .frame(width: handleSize, height: handleSize)
            .overlay(
                RoundedRectangle(cornerRadius: 2)
                    .strokeBorder(DesignSystem.Colors.tertiary, lineWidth: 1.5)
            )
    }
}

enum HandlePosition: CaseIterable {
    case topLeft, topRight, bottomLeft, bottomRight

    func point(in size: CGSize) -> CGPoint {
        switch self {
        case .topLeft:     return CGPoint(x: 0, y: 0)
        case .topRight:    return CGPoint(x: size.width, y: 0)
        case .bottomLeft:  return CGPoint(x: 0, y: size.height)
        case .bottomRight: return CGPoint(x: size.width, y: size.height)
        }
    }
}

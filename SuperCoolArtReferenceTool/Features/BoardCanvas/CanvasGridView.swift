import SwiftUI

/// Draws the infinite line-grid background for the canvas. The canvas always
/// occupies the full view (so hit-testing on the empty canvas tap gesture is
/// consistent), but draws nothing when `showGrid` is false.
struct CanvasGridView: View {
    let showGrid: Bool
    let scale: CGFloat
    let offset: CGSize
    let gridSpacing: CGFloat

    var body: some View {
        Canvas { ctx, size in
            guard showGrid else { return }

            let worldMinX = (-offset.width) / scale
            let worldMinY = (-offset.height) / scale
            let worldMaxX = (size.width - offset.width) / scale
            let worldMaxY = (size.height - offset.height) / scale

            var path = Path()
            let spacing = max(8.0, gridSpacing)
            let startX = floor(worldMinX / spacing) * spacing
            let startY = floor(worldMinY / spacing) * spacing

            var x = startX
            while x <= worldMaxX {
                let screenX = x * scale + offset.width
                path.move(to: CGPoint(x: screenX, y: 0))
                path.addLine(to: CGPoint(x: screenX, y: size.height))
                x += spacing
            }
            var y = startY
            while y <= worldMaxY {
                let screenY = y * scale + offset.height
                path.move(to: CGPoint(x: 0, y: screenY))
                path.addLine(to: CGPoint(x: size.width, y: screenY))
                y += spacing
            }

            ctx.stroke(path, with: .color(.gray.opacity(0.25)), lineWidth: 0.5)
        }
    }
}

import SwiftUI

/// Draws the infinite line-grid background for the canvas. The canvas always
/// occupies the full view (so hit-testing on the empty canvas tap gesture is
/// consistent), but draws nothing when `showGrid` is false.
///
/// The grid is drawn with `.ignoresSafeArea()` so it continues under the
/// toolbar. That extends this view's frame upward, moving its `(0, 0)` to the
/// top of the screen, while placed images and text are positioned relative to
/// the safe area (just below the toolbar). `safeAreaInsets` is the size of
/// that extension; adding it to `offset` puts the grid back in the same
/// coordinate space as the content, so a grid line at world `y` lands on the
/// same screen row as an image at world `y`.
struct CanvasGridView: View {
    let showGrid: Bool
    let scale: CGFloat
    let offset: CGSize
    let gridSpacing: CGFloat
    var safeAreaInsets: EdgeInsets = EdgeInsets()

    var body: some View {
        Canvas { ctx, size in
            guard showGrid else { return }

            // Screen position of world origin, in this view's (extended) space.
            let originX = offset.width + safeAreaInsets.leading
            let originY = offset.height + safeAreaInsets.top

            let worldMinX = (-originX) / scale
            let worldMinY = (-originY) / scale
            let worldMaxX = (size.width - originX) / scale
            let worldMaxY = (size.height - originY) / scale

            var path = Path()
            let spacing = max(8.0, gridSpacing)
            let startX = floor(worldMinX / spacing) * spacing
            let startY = floor(worldMinY / spacing) * spacing

            var x = startX
            while x <= worldMaxX {
                let screenX = x * scale + originX
                path.move(to: CGPoint(x: screenX, y: 0))
                path.addLine(to: CGPoint(x: screenX, y: size.height))
                x += spacing
            }
            var y = startY
            while y <= worldMaxY {
                let screenY = y * scale + originY
                path.move(to: CGPoint(x: 0, y: screenY))
                path.addLine(to: CGPoint(x: size.width, y: screenY))
                y += spacing
            }

            ctx.stroke(path, with: .color(.gray.opacity(0.25)), lineWidth: 0.5)
        }
    }
}

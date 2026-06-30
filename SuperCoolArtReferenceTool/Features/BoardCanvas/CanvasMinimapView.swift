import SwiftUI

/// Compact semi-transparent minimap rendered in the bottom-right corner of the
/// canvas. Shows element positions (white rectangles) and the current viewport
/// (blue outline) relative to the full content extents.
struct CanvasMinimapView: View {
    let elementRects: [CGRect]
    let viewportRect: CGRect

    var body: some View {
        Canvas { ctx, size in
            guard !elementRects.isEmpty else { return }
            let world = worldExtents()
            guard world.width > 0.001, world.height > 0.001 else { return }

            for rect in elementRects {
                let mr = project(rect, world: world, into: size)
                let drawn = CGRect(x: mr.minX, y: mr.minY,
                                   width: max(2, mr.width), height: max(2, mr.height))
                ctx.fill(Path(roundedRect: drawn, cornerRadius: 1),
                         with: .color(.white.opacity(0.7)))
            }

            let vr = project(viewportRect, world: world, into: size)
            ctx.fill(Path(vr), with: .color(.white.opacity(0.08)))
            ctx.stroke(Path(vr),
                       with: .color(DesignSystem.Colors.tertiary.opacity(0.9)),
                       lineWidth: 1.5)
        }
        .frame(width: 160, height: 100)
        .background {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(.black.opacity(0.55))
                .stroke(.white.opacity(0.12), lineWidth: 0.5)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func worldExtents() -> CGRect {
        guard let first = elementRects.first else { return viewportRect }
        var bounds = first
        for rect in elementRects.dropFirst() { bounds = bounds.union(rect) }
        bounds = bounds.union(viewportRect)
        let padX = max(64, bounds.width * 0.12)
        let padY = max(64, bounds.height * 0.12)
        return bounds.insetBy(dx: -padX, dy: -padY)
    }

    private func project(_ rect: CGRect, world: CGRect, into size: CGSize) -> CGRect {
        let sx = size.width / world.width
        let sy = size.height / world.height
        return CGRect(
            x: (rect.minX - world.minX) * sx,
            y: (rect.minY - world.minY) * sy,
            width: rect.width * sx,
            height: rect.height * sy
        )
    }
}

import SwiftUI

/// Renders thumbnail-scale placeholder rectangles for images that are below
/// the detail LOD threshold — too small or too numerous to decode at full
/// fidelity. Drawn in a single `Canvas` pass so there's one layer per frame
/// rather than one view per image.
struct CanvasOverviewLayer: View {
    let items: [PlacedImage]
    let scale: CGFloat
    let offset: CGSize

    var body: some View {
        Canvas { ctx, _ in
            for item in items {
                let screenRect = CGRect(
                    x: item.worldRect.origin.x * scale + offset.width,
                    y: item.worldRect.origin.y * scale + offset.height,
                    width: item.worldRect.width * scale,
                    height: item.worldRect.height * scale
                )
                let fillRect = screenRect.integral.insetBy(dx: 0.25, dy: 0.25)
                let fillPath = Path(
                    roundedRect: fillRect,
                    cornerRadius: min(3, min(fillRect.width, fillRect.height) * 0.2)
                )
                ctx.fill(fillPath, with: .color(DesignSystem.Colors.secondary.opacity(0.18)))
                if fillRect.width >= 6, fillRect.height >= 6 {
                    ctx.stroke(
                        fillPath,
                        with: .color(DesignSystem.Colors.secondary.opacity(0.32)),
                        lineWidth: 0.75
                    )
                }
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

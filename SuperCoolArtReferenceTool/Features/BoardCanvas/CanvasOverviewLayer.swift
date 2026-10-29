import SwiftUI

/// Renders thumbnail-scale placeholder rectangles for images that are below
/// the detail LOD threshold — too small or too numerous to decode at full
/// fidelity. Drawn in a single `Canvas` pass so there's one layer per frame
/// rather than one view per image.
struct CanvasOverviewLayer: View {
    let items: [PlacedImage]
    let scale: CGFloat
    let offset: CGSize
    /// Live join/leave tints during a frame resize, keyed by image id. Same
    /// meaning as `FrameMembershipHintStyle`, drawn into the one canvas pass.
    var hints: [UUID: FrameMembershipHint] = [:]

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
                let hint = hints[item.id]
                let fillColor: Color = switch hint {
                case .joining: FrameMembershipHintStyle.joiningTint
                case .leaving: DesignSystem.Colors.secondary.opacity(0.18 * FrameMembershipHintStyle.leavingOpacity)
                case nil: DesignSystem.Colors.secondary.opacity(0.18)
                }
                ctx.fill(fillPath, with: .color(fillColor))
                // The hint outline replaces the idle border, so a hint never
                // relies on the fill color alone (see `FrameMembershipHintStyle`).
                // A white line under the accent keeps it visible on blue.
                if hint != nil {
                    ctx.stroke(fillPath, with: .color(FrameMembershipHintStyle.contrastLine),
                               lineWidth: FrameMembershipHintStyle.outlineWidth + 2 * FrameMembershipHintStyle.contrastLineWidth)
                }
                switch hint {
                case .joining:
                    ctx.stroke(fillPath, with: .color(FrameMembershipHintStyle.accent),
                               lineWidth: FrameMembershipHintStyle.outlineWidth)
                case .leaving:
                    ctx.stroke(fillPath, with: .color(FrameMembershipHintStyle.accent),
                               style: StrokeStyle(lineWidth: FrameMembershipHintStyle.outlineWidth,
                                                  dash: FrameMembershipHintStyle.leavingDash))
                case nil:
                    if fillRect.width >= 6, fillRect.height >= 6 {
                        ctx.stroke(
                            fillPath,
                            with: .color(DesignSystem.Colors.secondary.opacity(0.32)),
                            lineWidth: 0.75
                        )
                    }
                }
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

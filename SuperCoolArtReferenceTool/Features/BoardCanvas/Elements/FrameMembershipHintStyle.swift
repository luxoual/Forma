import SwiftUI

/// How an item looks while a frame resize or frame drag is about to change its frame.
///
/// Each hint has three parts: a badge, an outline, and a color change. The
/// badge and outline are always drawn, so the hint never depends on color
/// alone.
///
/// - The badge says which way the item is going: a small accent circle with
///   "+" in the top-right corner of a joining item, "−" on a leaving one.
///   Selection and the marquee are also blue lines, so an outline alone read
///   as "selected". No selection chrome has a badge, so the badge is what
///   tells a hint apart.
/// - Joining: a solid accent-blue outline plus a 25% wash of the same blue.
///   The wash alone vanished on blue photos; the outline still shows there.
/// - Leaving: a dashed accent-blue outline, and the item turns grayscale at
///   45% opacity, so it reads as "falling away." Grayscale alone did
///   nothing to a black-and-white sketch; the dashes still show there.
///
/// Every accent line sits on a 1pt white line, so it still shows on a blue
/// image. The badge, outline width, and dashes are in screen points, so they
/// stay the same size at every zoom level.
///
/// With Reduce Transparency on, a leaving item changes brightness instead of
/// turning see-through (`reducedTransparencyBrightness`): darker on a light
/// canvas, brighter on a dark one. Darkening on a near-black canvas made the
/// item all but vanish.
enum FrameMembershipHintStyle {
    static let accent = DesignSystem.Colors.tertiary
    /// The light line under every accent line.
    static let contrastLine = DesignSystem.Colors.text
    static let contrastLineWidth: CGFloat = 1
    static let joiningTint = accent.opacity(0.25)
    static let outlineWidth: CGFloat = 1.5
    static let leavingDash: [CGFloat] = [6, 4]
    static let leavingOpacity = 0.45
    /// How far a leaving item's brightness shifts when Reduce Transparency
    /// is on. Applied as a darkening on a light canvas, a brightening on a
    /// dark one.
    static let reducedTransparencyBrightness = 0.35
    /// Diameter of the "+" / "−" badge, in screen points.
    static let badgeSize: CGFloat = 16
    /// Gap between the badge and the item's corner, in screen points.
    static let badgeInset: CGFloat = 4
}

/// The outline, the badge, and (for joining) the wash drawn over an item
/// with a hint. It holds no state, so it can come and go freely.
private struct FrameMembershipHintMark<S: InsettableShape>: View {
    let hint: FrameMembershipHint
    let shape: S

    private typealias Style = FrameMembershipHintStyle

    var body: some View {
        ZStack(alignment: .topTrailing) {
            switch hint {
            case .joining:
                shape.fill(Style.joiningTint)
                // The white line is drawn wider and underneath, so 1pt of
                // it shows just inside the accent line.
                shape.strokeBorder(Style.contrastLine, lineWidth: Style.outlineWidth + Style.contrastLineWidth)
                shape.strokeBorder(Style.accent, lineWidth: Style.outlineWidth)
            case .leaving:
                shape.strokeBorder(Style.contrastLine, lineWidth: Style.outlineWidth + Style.contrastLineWidth)
                shape.strokeBorder(
                    Style.accent,
                    style: StrokeStyle(lineWidth: Style.outlineWidth, dash: Style.leavingDash)
                )
            }
            badge.padding(Style.badgeInset)
        }
    }

    private var badge: some View {
        Image(systemName: hint == .joining ? "plus" : "minus")
            .font(.system(size: 9, weight: .heavy))
            .foregroundStyle(Style.contrastLine)
            .frame(width: Style.badgeSize, height: Style.badgeSize)
            .background(Circle().fill(Style.accent))
            .overlay(Circle().strokeBorder(Style.contrastLine, lineWidth: Style.contrastLineWidth))
            // VoiceOver hears the change as an announcement on commit
            // instead (`FrameMembershipAnnouncement`).
            .accessibilityHidden(true)
    }
}

/// Grays out a leaving item and fades it, or with Reduce Transparency on,
/// shifts its brightness away from the canvas.
///
/// The filters stay in place for every item, set to zero when the item
/// isn't leaving. That keeps the view the same view either way, so turning
/// the hint on or off never resets `@State` inside it.
private struct FrameMembershipLeavingEffect: ViewModifier {
    let isLeaving: Bool
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.canvasIsDark) private var canvasIsDark

    private var brightness: Double {
        guard isLeaving, reduceTransparency else { return 0 }
        let shift = FrameMembershipHintStyle.reducedTransparencyBrightness
        return canvasIsDark ? shift : -shift
    }

    func body(content: Content) -> some View {
        content
            .grayscale(isLeaving ? 1 : 0)
            .brightness(brightness)
            .opacity(isLeaving && !reduceTransparency ? FrameMembershipHintStyle.leavingOpacity : 1)
    }
}

extension View {
    /// The leaving item's grayscale and fade. See `FrameMembershipLeavingEffect`.
    func frameMembershipLeavingEffect(_ isLeaving: Bool) -> some View {
        modifier(FrameMembershipLeavingEffect(isLeaving: isLeaving))
    }

    /// Draws the hint's outline, badge, and joining wash as `shape`. With
    /// `rect` nil the shape fills this view. Pass `rect` when this view is
    /// larger than the item, such as text after `.position`, which fills the
    /// canvas. Nil `hint` draws nothing.
    func frameMembershipOutline<S: InsettableShape>(
        _ hint: FrameMembershipHint?,
        in shape: S,
        rect: CGRect? = nil
    ) -> some View {
        overlay {
            if let hint {
                if let rect {
                    FrameMembershipHintMark(hint: hint, shape: shape)
                        .frame(width: rect.width, height: rect.height)
                        .position(x: rect.midX, y: rect.midY)
                        .allowsHitTesting(false)
                } else {
                    FrameMembershipHintMark(hint: hint, shape: shape)
                        .allowsHitTesting(false)
                }
            }
        }
    }
}

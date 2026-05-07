import SwiftUI

/// Shared resize handle used by both single-item and group selection overlays.
private struct ResizeHandleView: View {
    private let size: CGFloat = 10

    var body: some View {
        RoundedRectangle(cornerRadius: 2)
            .fill(Color.white)
            .frame(width: size, height: size)
            .overlay(
                RoundedRectangle(cornerRadius: 2)
                    .strokeBorder(DesignSystem.Colors.tertiary, lineWidth: 1.5)
            )
    }
}

struct SelectionOverlay: View {
    private let borderWidth: CGFloat = 2

    /// Which handles to render. Defaults to all 8; text elements pass a
    /// restricted set (corners + left/right) since top/bottom edge drags
    /// have no meaningful semantic for text — height is always
    /// content-derived.
    var handles: Set<HandlePosition> = Set(HandlePosition.allCases)

    var body: some View {
        GeometryReader { geo in
            Rectangle()
                .strokeBorder(DesignSystem.Colors.tertiary, lineWidth: borderWidth)

            ForEach(HandlePosition.allCases.filter { handles.contains($0) }, id: \.self) { position in
                ResizeHandleView()
                    .position(position.point(in: geo.size))
            }
        }
    }
}

/// Selection overlay for a multi-select group bounding box (dashed border).
struct GroupSelectionOverlay: View {
    private let borderWidth: CGFloat = 2

    var body: some View {
        GeometryReader { geo in
            Rectangle()
                .strokeBorder(
                    style: StrokeStyle(lineWidth: borderWidth, dash: [8, 4])
                )
                .foregroundStyle(DesignSystem.Colors.tertiary)

            ForEach(HandlePosition.allCases, id: \.self) { position in
                ResizeHandleView()
                    .position(position.point(in: geo.size))
            }
        }
    }
}

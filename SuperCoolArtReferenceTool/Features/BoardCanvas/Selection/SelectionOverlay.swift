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
    /// The handle the user is currently dragging. While non-nil, only that
    /// handle is shown — the other seven hide so they don't visually
    /// compete with the active gesture. `nil` means "not resizing", and
    /// every handle in `handles` is rendered.
    var activeHandle: HandlePosition? = nil

    var body: some View {
        GeometryReader { geo in
            Rectangle()
                .strokeBorder(DesignSystem.Colors.tertiary, lineWidth: borderWidth)

            ForEach(visibleHandles, id: \.self) { position in
                ResizeHandleView()
                    .position(position.point(in: geo.size))
            }
        }
    }

    private var visibleHandles: [HandlePosition] {
        let baseline = HandlePosition.allCases.filter { handles.contains($0) }
        if let activeHandle, baseline.contains(activeHandle) {
            return [activeHandle]
        }
        return baseline
    }
}

/// Selection overlay for a multi-select group bounding box. Solid border
/// at the same weight as the single-element overlay so multi-select reads
/// as a stronger version of the same affordance rather than a different
/// visual language.
struct GroupSelectionOverlay: View {
    private let borderWidth: CGFloat = 2

    /// The handle currently being dragged for the group resize. See
    /// `SelectionOverlay.activeHandle` for the same idea — only that handle
    /// renders during the gesture, the rest hide.
    var activeHandle: HandlePosition? = nil

    var body: some View {
        GeometryReader { geo in
            Rectangle()
                .strokeBorder(DesignSystem.Colors.tertiary, lineWidth: borderWidth)

            ForEach(visibleHandles, id: \.self) { position in
                ResizeHandleView()
                    .position(position.point(in: geo.size))
            }
        }
    }

    private var visibleHandles: [HandlePosition] {
        if let activeHandle { return [activeHandle] }
        return HandlePosition.allCases
    }
}

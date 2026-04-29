import SwiftUI

/// Positions the canvas toolbar (vertically centered) and the settings button
/// (bottom corner) on the left or right edge of the canvas, based on the
/// user's toolbar-side preference.
struct CanvasOverlayLayout: View {
    let side: ToolbarSide
    @Binding var activeTool: CanvasTool
    let onBack: () -> Void
    let onUndo: () -> Void
    let onRedo: () -> Void
    let onAddItem: () -> Void
    let onSettings: () -> Void

    var body: some View {
        let edge: Edge.Set = (side == .left) ? .leading : .trailing
        let frameAlignment: Alignment = (side == .left) ? .leading : .trailing

        Group {
            VStack {
                CanvasBackButton(onTap: onBack)
                    .padding(.leading, 16)
                    .padding(.top, 16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Spacer()
            }

            CanvasToolbar(
                activeTool: $activeTool,
                onUndo: onUndo,
                onRedo: onRedo,
                onAddItem: onAddItem
            )
            .padding(edge, 16)
            .frame(maxWidth: .infinity, alignment: frameAlignment)

            VStack {
                Spacer()
                CanvasSettingsButton(onTap: onSettings)
                    .padding(.leading, 16)
                    .padding(.bottom, 16)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

struct CanvasBackButton: View {
    var onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            Image(systemName: "chevron.left")
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(DesignSystem.Colors.text)
                .padding(12)
                .frame(width: 68)
                .background(
                    RoundedRectangle(cornerRadius: 12)
                        .fill(DesignSystem.Colors.primary)
                        .shadow(color: .black.opacity(0.3), radius: 8, x: 2, y: 2)
                )
                .contentShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Back to home")
    }
}

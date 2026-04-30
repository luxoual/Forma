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
    var canvasName: String

    var body: some View {
        let edge: Edge.Set = (side == .left) ? .leading : .trailing
        let frameAlignment: Alignment = (side == .left) ? .leading : .trailing

        Group {
            VStack {
                CanvasStatusbar(onTap: onBack, canvasName: canvasName)
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

//
//  CanvasNavigationToolbar.swift
//  SuperCoolArtReferenceTool
//

import SwiftUI

/// Native `.toolbar` content for the canvas view.
///
/// Extracted into its own `ToolbarContent` struct so SwiftUI gets a stable
/// type to diff (a computed `@ToolbarContentBuilder` property collapses into
/// the parent body and inflates type-check time).
///
/// Layout:
/// - Leading: an empty, invisible slot. The back button, board name, and
///   outliner toggle are drawn by `CanvasHUDView`, floated over this slot by
///   `ContentView` (see that type for why). The slot reports its on-screen
///   frame through `onHUDFrameChange` so the HUD can line up with it.
/// - Trailing: tools+add / undo-redo / home+settings, split by `ToolbarSpacer`
///   so each group renders as its own glass capsule. Add lives with the
///   tools because it's the other put-stuff-on-the-canvas action, not a
///   settings affordance. Home lives with settings because both are
///   view-level navigation, not edit-history actions.
/// - All buttons use `Label("Title", systemImage: …)` so the system overflow
///   menu can populate from titles when the bar collapses.
struct CanvasNavigationToolbar: ToolbarContent {
    /// Size reserved for `CanvasHUDView` in the leading slot.
    let hudSize: CGSize
    /// Called with the slot's frame in global coordinates whenever it moves.
    let onHUDFrameChange: (CGRect) -> Void
    @Binding var activeTool: CanvasTool
    /// Mirrors of `UndoManager.canUndo` / `canRedo`, kept by
    /// `CanvasCommandHistory`, so the buttons grey out when there's nothing
    /// to do.
    let canUndo: Bool
    let canRedo: Bool
    let onUndo: () -> Void
    let onRedo: () -> Void
    let onHome: () -> Void
    let onAddItem: () -> Void
    let onSettings: () -> Void

    var body: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            Color.clear
                .frame(width: hudSize.width, height: hudSize.height)
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame in
                    onHUDFrameChange(frame)
                }
                .accessibilityHidden(true)
        }
        // No glass pill behind the empty slot; the HUD brings its own.
        .sharedBackgroundVisibility(.hidden)

        // Tools + add — discrete Buttons in a single group so they share one
        // glass capsule. Active tool gets a tertiary tint *and* the
        // .isSelected accessibility trait so VoiceOver knows which one is on.
        // Add isn't a mode toggle (no .isSelected, no tint), it just lives
        // here because it's the same kind of "put stuff on the canvas"
        // action as the tools next to it.
        ToolbarItemGroup(placement: .topBarTrailing) {
            toolButton(.group, label: "Select", icon: "rectangle.dashed")
            toolButton(.text, label: "Text", icon: "textformat")
            Button("Add", systemImage: "plus", action: onAddItem)
        }

        ToolbarSpacer(.fixed, placement: .topBarTrailing)

        ToolbarItemGroup(placement: .topBarTrailing) {
            Button(action: onUndo) {
                Label("Undo", systemImage: "arrow.uturn.backward")
            }
            .disabled(!canUndo)
            Button(action: onRedo) {
                Label("Redo", systemImage: "arrow.uturn.forward")
            }
            .disabled(!canRedo)
        }

        ToolbarSpacer(.fixed, placement: .topBarTrailing)

        ToolbarItemGroup(placement: .topBarTrailing) {
            Button("Fit to Content", systemImage: "house", action: onHome)
            Button(action: onSettings) {
                Label("Settings", systemImage: "gear")
            }
        }
    }

    private func toolButton(_ tool: CanvasTool, label: String, icon: String) -> some View {
        let isActive = activeTool == tool
        return Button { activeTool = tool } label: {
            Label(label, systemImage: icon)
        }
        .tint(isActive ? DesignSystem.Colors.tertiary : nil)
        .accessibilityAddTraits(isActive ? [.isSelected] : [])
    }
}

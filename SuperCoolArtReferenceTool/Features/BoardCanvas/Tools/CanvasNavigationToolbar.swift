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
/// - Leading group: back chevron + board name pill (no nested glass).
/// - Trailing: tools+add / undo-redo / home+settings, split by `ToolbarSpacer`
///   so each group renders as its own glass capsule. Add lives with the
///   tools because it's the other put-stuff-on-the-canvas action, not a
///   settings affordance. Home lives with settings because both are
///   view-level navigation, not edit-history actions.
/// - All buttons use `Label("Title", systemImage: …)` so the system overflow
///   menu can populate from titles when the bar collapses.
struct CanvasNavigationToolbar: ToolbarContent {
    let boardName: String
    @Binding var activeTool: CanvasTool
    let onBack: () -> Void
    let onUndo: () -> Void
    let onRedo: () -> Void
    let onHome: () -> Void
    let onAddItem: () -> Void
    let onSettings: () -> Void

    var body: some ToolbarContent {
        ToolbarItemGroup(placement: .topBarLeading) {
            Button(action: onBack) {
                Label("Back to home", systemImage: "chevron.left")
            }

            // Disabled glass button as a board-name label — the system
            // treats it as a real toolbar control so it respects `maxWidth`,
            // where a bare `Text` is squeezed to chevron width.
            Button { } label: {
                Text(boardName)
                    .font(.headline)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: 220)
            }
            .tint(DesignSystem.Colors.tertiary)
            .allowsHitTesting(false)
            .accessibilityRemoveTraits(.isButton)
        }

        // Tools + add — discrete Buttons in a single group so they share one
        // glass capsule. Active tool gets a tertiary tint *and* the
        // .isSelected accessibility trait so VoiceOver knows which one is on.
        // Add isn't a mode toggle (no .isSelected, no tint), it just lives
        // here because it's the same kind of "put stuff on the canvas"
        // action as the tools next to it.
        ToolbarItemGroup(placement: .topBarTrailing) {
            toolButton(.pointer, label: "Pointer", icon: "arrow.up.left")
            toolButton(.group, label: "Group", icon: "rectangle.dashed")
            toolButton(.text, label: "Text", icon: "textformat")
            Button("Add", systemImage: "plus", action: onAddItem)
        }

        ToolbarSpacer(.fixed, placement: .topBarTrailing)

        ToolbarItemGroup(placement: .topBarTrailing) {
            Button(action: onUndo) {
                Label("Undo", systemImage: "arrow.uturn.backward")
            }
            Button(action: onRedo) {
                Label("Redo", systemImage: "arrow.uturn.forward")
            }
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

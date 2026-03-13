//
//  CanvasToolbar.swift
//  SuperCoolArtReferenceTool
//
//  Created by andy lin on 3/13/26.
//

import SwiftUI

/// Toolbar overlay for canvas interaction
/// Left-aligned vertical toolbar with tool options
struct CanvasToolbar: View {
    @Binding var activeTool: CanvasTool
    var onUndo: () -> Void
    var onRedo: () -> Void
    var onAddItem: () -> Void
    
    @Namespace private var toolNamespace
    
    var body: some View {
        VStack(spacing: 12) {
            // Pointer tool
            ToolbarButton(
                icon: "arrow.up.left",
                isActive: activeTool == .pointer,
                namespace: toolNamespace,
                id: CanvasTool.pointer
            ) {
                activeTool = .pointer
            }
            
            // Group tool
            ToolbarButton(
                icon: "rectangle.dashed",
                isActive: activeTool == .group,
                namespace: toolNamespace,
                id: CanvasTool.group
            ) {
                activeTool = .group
            }
            
            Divider()
                .background(DesignSystem.Colors.secondary)
                .frame(height: 1)
                .padding(.vertical, 4)
            
            // Undo
            ToolbarButton(
                icon: "arrow.uturn.backward",
                isActive: false,
                namespace: nil,
                id: nil
            ) {
                onUndo()
            }
            
            // Redo
            ToolbarButton(
                icon: "arrow.uturn.forward",
                isActive: false,
                namespace: nil,
                id: nil
            ) {
                onRedo()
            }
            
            Divider()
                .background(DesignSystem.Colors.secondary)
                .frame(height: 1)
                .padding(.vertical, 4)
            
            // Add new item
            ToolbarButton(
                icon: "plus",
                isActive: false,
                namespace: nil,
                id: nil
            ) {
                onAddItem()
            }
        }
        .padding(12)
        .frame(width: 68) // Fixed width: 44pt button + 12pt padding on each side
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(DesignSystem.Colors.primary)
                .shadow(color: .black.opacity(0.3), radius: 8, x: 2, y: 2)
        )
    }
}

/// Individual toolbar button component
private struct ToolbarButton: View {
    let icon: String
    let isActive: Bool
    let namespace: Namespace.ID?
    let id: CanvasTool?
    let action: () -> Void
    
    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 20, weight: .medium))
                .foregroundStyle(isActive ? DesignSystem.Colors.primary : DesignSystem.Colors.secondary)
                .frame(width: 44, height: 44)
                .background {
                    if isActive, let namespace = namespace, let _ = id {
                        RoundedRectangle(cornerRadius: 8)
                            .fill(DesignSystem.Colors.tertiary)
                            .matchedGeometryEffect(id: "activeButton", in: namespace)
                    }
                }
        }
        .buttonStyle(.plain)
        .animation(.smooth(duration: 0.3), value: isActive)
    }
}

/// Available canvas tools
enum CanvasTool: Equatable {
    case pointer
    case group
}

// MARK: - Preview

#Preview("Canvas Toolbar") {
    @Previewable @State var activeTool: CanvasTool = .pointer
    
    ZStack(alignment: .leading) {
        // Simulated canvas background
        Color.gray.opacity(0.2)
            .ignoresSafeArea()
        
        CanvasToolbar(
            activeTool: $activeTool,
            onUndo: { print("Undo") },
            onRedo: { print("Redo") },
            onAddItem: { print("Add Item") }
        )
        .padding(.leading, 16)
    }
}

#Preview("Canvas Toolbar - Portrait", traits: .portrait) {
    @Previewable @State var activeTool: CanvasTool = .pointer
    
    ZStack(alignment: .leading) {
        Color.gray.opacity(0.2)
            .ignoresSafeArea()
        
        CanvasToolbar(
            activeTool: $activeTool,
            onUndo: { print("Undo") },
            onRedo: { print("Redo") },
            onAddItem: { print("Add Item") }
        )
        .padding(.leading, 16)
    }
}

#Preview("Canvas Toolbar - Landscape", traits: .landscapeLeft) {
    @Previewable @State var activeTool: CanvasTool = .pointer
    
    ZStack(alignment: .leading) {
        Color.gray.opacity(0.2)
            .ignoresSafeArea()
        
        CanvasToolbar(
            activeTool: $activeTool,
            onUndo: { print("Undo") },
            onRedo: { print("Redo") },
            onAddItem: { print("Add Item") }
        )
        .padding(.leading, 16)
    }
}

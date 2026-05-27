//
//  CanvasSettingsView.swift
//  SuperCoolArtReferenceTool
//
//  Created by andy lin on 3/25/26.
//

import SwiftUI

/// Settings sheet for canvas options
struct CanvasSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    
    @Binding var showGrid: Bool
    @Binding var toolbarSide: ToolbarSide
    @Binding var canvasColor: Color

    var body: some View {
        NavigationStack {
            // Standard Form: it adopts Liquid Glass for its grouped rows,
            // nav bar, and controls automatically. We deliberately set no
            // backgrounds, row backgrounds, or toolbar materials — overriding
            // them is what suppressed the glass before. Our only customization
            // is the brand accent, applied once via .tint so it flows into the
            // toggle, picker, color well, and Done button.
            Form {
                Section("Canvas") {
                    ColorPicker("Canvas Color", selection: $canvasColor, supportsOpacity: false)

                    Toggle("Show Grid", isOn: $showGrid)

                    Picker("Toolbar Position", selection: $toolbarSide) {
                        Text("Left").tag(ToolbarSide.left)
                        Text("Right").tag(ToolbarSide.right)
                    }
                }

                Section("About") {
                    LabeledContent("Version", value: "1.0.0")
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .tint(DesignSystem.Colors.tertiary)
    }
}

enum ToolbarSide: String, Codable {
    case left
    case right
}

#Preview {
    @Previewable @State var showGrid = true
    @Previewable @State var toolbarSide = ToolbarSide.left
    @Previewable @State var canvasColor = Color.white

    CanvasSettingsView(showGrid: $showGrid, toolbarSide: $toolbarSide, canvasColor: $canvasColor)
}

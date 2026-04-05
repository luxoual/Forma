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
        NavigationView {
            List {
                Section("Canvas") {
                    HStack {
                        Text("Canvas Color")
                            .foregroundStyle(DesignSystem.Colors.text)
                        Spacer()
                        ZStack {
                            RoundedRectangle(cornerRadius: 8)
                                .fill(canvasColor)
                                .stroke(Color.white.opacity(0.3), lineWidth: 1)
                                .frame(width: 48, height: 28)
                                .allowsHitTesting(false)
                            ColorPicker("", selection: $canvasColor, supportsOpacity: false)
                                .labelsHidden()
                                .scaleEffect(CGSize(width: 2.0, height: 2.0))
                                .opacity(0.015)
                        }
                        .frame(width: 48, height: 28)
                        .clipped()
                    }

                    Toggle("Show Grid", isOn: $showGrid)
                        .tint(DesignSystem.Colors.tertiary)
                        .foregroundStyle(DesignSystem.Colors.text)

                    HStack {
                        Text("Toolbar Position")
                            .foregroundStyle(DesignSystem.Colors.text)
                        Spacer()
                        Picker("Toolbar Position", selection: $toolbarSide) {
                            Text("Left")
                                .tag(ToolbarSide.left)
                            Text("Right")
                                .tag(ToolbarSide.right)
                        }
                        .labelsHidden()
                        .tint(DesignSystem.Colors.secondary)
                    }
                }
                .listRowBackground(DesignSystem.Colors.primary)
                
                Section("About") {
                    HStack {
                        Text("Version")
                            .foregroundStyle(DesignSystem.Colors.text)
                        Spacer()
                        Text("1.0.0")
                            .foregroundStyle(DesignSystem.Colors.secondary)
                    }
                }
                .listRowBackground(DesignSystem.Colors.primary)
            }
            .scrollContentBackground(.hidden)
            .background(Color.black)
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(DesignSystem.Colors.primary, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        dismiss()
                    }
                    .foregroundStyle(DesignSystem.Colors.tertiary)
                }
            }
        }
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

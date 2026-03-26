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
    
    var body: some View {
        NavigationView {
            List {
                Section("Canvas") {
                    HStack {
                        Text("Grid")
                        Spacer()
                        Text("On")
                            .foregroundStyle(DesignSystem.Colors.secondary)
                    }
                    
                    HStack {
                        Text("Grid Spacing")
                        Spacer()
                        Text("128 pt")
                            .foregroundStyle(DesignSystem.Colors.secondary)
                    }
                }
                
                Section("About") {
                    HStack {
                        Text("Version")
                        Spacer()
                        Text("1.0.0")
                            .foregroundStyle(DesignSystem.Colors.secondary)
                    }
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
        }
    }
}

#Preview {
    CanvasSettingsView()
}

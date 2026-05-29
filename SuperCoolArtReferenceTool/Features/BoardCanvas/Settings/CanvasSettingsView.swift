//
//  CanvasSettingsView.swift
//  SuperCoolArtReferenceTool
//
//  Created by andy lin on 3/25/26.
//

import SwiftUI
import UIKit

/// Settings sheet for canvas options.
///
/// A sheet can't live-sample the canvas the way the toolbar buttons do (it
/// sits behind a dimming scrim), so we bridge the gap manually: a translucent
/// material gives the frosted-glass look, and `preferredColorScheme` — derived
/// from the canvas color's luminance — flips the whole panel light/dark to
/// match the canvas, keeping text legible and avoiding a flashbang.
struct CanvasSettingsView: View {
    @Environment(\.dismiss) private var dismiss

    @Binding var showGrid: Bool
    @Binding var canvasColor: Color

    /// `.dark` over a dark canvas, `.light` over a light one (Rec. 709 luminance).
    private var canvasColorScheme: ColorScheme {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        UIColor(canvasColor).getRed(&r, green: &g, blue: &b, alpha: &a)
        let luminance = 0.2126 * r + 0.7152 * g + 0.0722 * b
        return luminance < 0.5 ? .dark : .light
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Canvas") {
                    ColorPicker("Canvas Color", selection: $canvasColor, supportsOpacity: false)

                    Toggle("Show Grid", isOn: $showGrid)
                }
                .listRowBackground(Color.clear)

                Section("About") {
                    LabeledContent("Version", value: "1.0.0")
                }
                .listRowBackground(Color.clear)
            }
            // Hide the Form's opaque grouped background so the translucent
            // presentation material (and the blurred canvas) shows through.
            .scrollContentBackground(.hidden)
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .tint(DesignSystem.Colors.tertiary)
        .presentationBackground(.thinMaterial)
        .preferredColorScheme(canvasColorScheme)
    }
}

#Preview {
    @Previewable @State var showGrid = true
    @Previewable @State var canvasColor = Color.white

    CanvasSettingsView(showGrid: $showGrid, canvasColor: $canvasColor)
}

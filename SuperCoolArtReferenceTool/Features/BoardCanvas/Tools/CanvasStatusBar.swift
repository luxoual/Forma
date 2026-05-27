//
//  CanvasStatusBar.swift
//  SuperCoolArtReferenceTool
//
//  Created by andy lin on 4/28/26.
//

import SwiftUI

struct CanvasStatusBar: View {
    var onTap: () -> Void
    var canvasName: String
    var body: some View {
        HStack{
            CanvasBackButton(onTap: onTap)
            CanvasBoardName(canvasName: canvasName)
        }
    }
}

struct CanvasBackButton: View {
    var onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            Image(systemName: "chevron.left")
                .font(.system(size: 20, weight: .semibold))
                .frame(width: 24, height: 24)
        }
        .buttonStyle(.glass)
        .controlSize(.large)
        .accessibilityLabel("Back to home")
        .tint(DesignSystem.Colors.tertiary)
    }
}

struct CanvasBoardName: View {
    var canvasName: String

    var body: some View {
        // A non-interactive glass button rather than plain Text: the glass
        // *button style* is what gives the label vibrant, backdrop-adaptive
        // tinting (a Text over .glassEffect doesn't get that). allowsHitTesting
        // keeps the enabled/vibrant look while making it non-tappable, and the
        // button trait is removed so VoiceOver reads it as a label.
        Button {
        } label: {
            Text(canvasName)
                .font(.headline)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: 250, alignment: .center)
        }
        .buttonStyle(.glass)
        .buttonBorderShape(.roundedRectangle(radius: 16))
        .controlSize(.large)
        .tint(DesignSystem.Colors.tertiary)
        .allowsHitTesting(false)
        .accessibilityRemoveTraits(.isButton)
    }
}

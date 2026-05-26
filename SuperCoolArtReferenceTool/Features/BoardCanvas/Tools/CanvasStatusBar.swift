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
    var canvasColor: Color
    var body: some View {
        HStack{
            CanvasBackButton(onTap: onTap, canvasColor: canvasColor)
            CanvasBoardName(canvasName: canvasName)
        }
    }
}

struct CanvasBackButton: View {
    var onTap: () -> Void
    var canvasColor: Color

    var body: some View {
        Button(action: onTap) {
            Image(systemName: "chevron.left")
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(canvasColor.contrastingForeground)
        }
        .buttonStyle(.glass)
        .controlSize(.large)
        .accessibilityLabel("Back to home")
    }
}

struct CanvasBoardName: View {
    var canvasName: String

    var body: some View {
        Text(canvasName)
            .font(.headline)
            .foregroundStyle(DesignSystem.Colors.tertiary)
            .lineLimit(1)
            .truncationMode(.middle)
            .frame(maxWidth: 250, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .glassEffect(.regular, in: .rect(cornerRadius: 16))
    }
}

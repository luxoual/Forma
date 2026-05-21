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
                .foregroundStyle(DesignSystem.Colors.secondary)
                .padding(12)
                .frame(width: 68)
                .contentShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Back to home")
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(DesignSystem.Colors.primary)
                .shadow(color: .black.opacity(0.3), radius: 8, x: 2, y: 2)
        )
    }
}

struct CanvasBoardName: View {
    var canvasName: String
    
    var body: some View {
        Text(canvasName)
            .font(.headline)
            .foregroundStyle(DesignSystem.Colors.tertiary)
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(DesignSystem.Colors.primary)
                    .shadow(color: .black.opacity(0.3), radius: 8, x: 2, y: 2)
            )
            .lineLimit(1)
            .truncationMode(.middle)
            .frame(maxWidth: 250, alignment: .leading)
    }
}

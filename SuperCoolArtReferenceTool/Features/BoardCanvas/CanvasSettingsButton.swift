//
//  CanvasSettingsButton.swift
//  SuperCoolArtReferenceTool
//
//  Created by andy lin on 3/25/26.
//

import SwiftUI

/// Settings button for canvas options
/// Positioned at bottom-left, separate from main toolbar
/// Matches the styling and dimensions of CanvasToolbar
struct CanvasSettingsButton: View {
    var onTap: () -> Void
    
    var body: some View {
        Button(action: onTap) {
            Image(systemName: "gear")
                .font(.system(size: 24, weight: .medium))
                .foregroundStyle(DesignSystem.Colors.secondary)
                .frame(width: 44, height: 44)
        }
        .buttonStyle(.plain)
        .padding(12) // Same padding as toolbar
        .frame(width: 68) // Same width as toolbar (44pt button + 12pt padding each side)
        .background(
            RoundedRectangle(cornerRadius: 12) // Same corner radius as toolbar
                .fill(DesignSystem.Colors.primary)
                .shadow(color: .black.opacity(0.3), radius: 8, x: 2, y: 2)
        )
    }
}

#Preview {
    ZStack {
        // Simulated canvas background
        Color.gray.opacity(0.2)
            .ignoresSafeArea()
        
        VStack {
            Spacer()
            HStack {
                CanvasSettingsButton {
                    print("Settings tapped")
                }
                .padding(.leading, 16)
                .padding(.bottom, 16)
                Spacer()
            }
        }
    }
}

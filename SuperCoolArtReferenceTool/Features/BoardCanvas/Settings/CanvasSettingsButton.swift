//
//  CanvasSettingsButton.swift
//  SuperCoolArtReferenceTool
//
//  Created by andy lin on 3/25/26.
//

import SwiftUI

struct CanvasSettingsButton: View {
    var onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            Image(systemName: "gear")
                .font(.system(size: 20, weight: .semibold))
                .frame(width: 24, height: 24)
        }
        .buttonStyle(.glass)
        .controlSize(.large)
        .tint(DesignSystem.Colors.tertiary)
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

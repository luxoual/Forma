//
//  CanvasSettingsButton.swift
//  SuperCoolArtReferenceTool
//
//  Created by andy lin on 3/25/26.
//

import SwiftUI

struct CanvasSettingsButton: View {
    var canvasColor: Color
    var onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            Image(systemName: "gear")
                .font(.system(size: 22, weight: .medium))
                .foregroundStyle(canvasColor.contrastingForeground)
        }
        .buttonStyle(.glass)
        .controlSize(.large)
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
                CanvasSettingsButton(canvasColor: .white) {
                    print("Settings tapped")
                }
                .padding(.leading, 16)
                .padding(.bottom, 16)
                Spacer()
            }
        }
    }
}

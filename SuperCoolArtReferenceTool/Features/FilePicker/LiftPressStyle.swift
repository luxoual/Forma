//
//  LiftPressStyle.swift
//  SuperCoolArtReferenceTool
//

import SwiftUI

/// Press feedback that mimics the bubble/lift of a native glass button:
/// a small scale-up + upward translate on press, spring-released. Used on
/// plain rows (e.g. recent boards) where we want the tactile feel without
/// the full glass material.
struct LiftPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 1.02 : 1.0)
            .offset(y: configuration.isPressed ? -2 : 0)
            .animation(.spring(response: 0.3, dampingFraction: 0.6),
                       value: configuration.isPressed)
    }
}

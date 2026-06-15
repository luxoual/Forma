//
//  Colors.swift
//  SuperCoolArtReferenceTool
//
//  Created by andy lin on 3/5/26.
//

import SwiftUI

extension DesignSystem{
    enum Colors {
        /// Primary color - #191919 (Dark gray, almost black)
        static let primary = Color(red: 25/255, green: 25/255, blue: 25/255)
        
        /// Secondary color - #535353 (Medium gray)
        static let secondary = Color(red: 83/255, green: 83/255, blue: 83/255)
        
        /// Tertiary color - #3977F8 (Saturated blue)
        static let tertiary = Color(red: 57/255, green: 119/255, blue: 248/255)
        
        /// Text color - #FFFFFF (White)
        static let text = Color.white

        /// Destructive color - #FE8686 (matches tertiary's saturation and lightness,
        /// but with a red hue). Used for delete actions and other destructive UI.
        static let destructive = Color(red: 254/255, green: 134/255, blue: 134/255)
    }
}

// MARK: - Hex coding

extension Color {
    /// Parse an opaque `#RRGGBB` or `RRGGBB` hex string into sRGB. Returns nil on
    /// any malformed input — callers can fall back to a default. Opacity is not
    /// supported (the canvas color picker disables it).
    ///
    /// `nonisolated` because the project defaults type isolation to `MainActor`,
    /// and this init is called from `ContentView.init` (a non-isolated context).
    nonisolated init?(hex: String) {
        var s = hex
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let v = UInt32(s, radix: 16) else { return nil }
        let r = Double((v >> 16) & 0xFF) / 255
        let g = Double((v >> 8) & 0xFF) / 255
        let b = Double(v & 0xFF) / 255
        self = Color(red: r, green: g, blue: b)
    }
}

/// `#RRGGBB` for an opaque resolved color. Opacity is discarded — callers that
/// need it (none today) should encode it separately. Resolving requires an
/// `EnvironmentValues`, so this is split from the `Color` extension above:
/// the call site has the environment, this helper just formats.
func canvasColorHexString(from resolved: Color.Resolved) -> String {
    func byte(_ x: Float) -> Int { max(0, min(255, Int((x * 255).rounded()))) }
    return String(format: "#%02X%02X%02X", byte(resolved.red), byte(resolved.green), byte(resolved.blue))
}

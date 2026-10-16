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
    /// Parse a `#RRGGBB` or `#RRGGBBAA` hex string (the `#` is optional) into
    /// sRGB. The last two digits, when present, are opacity: `00` is fully
    /// see-through, `FF` is solid. Returns nil on any malformed input —
    /// callers can fall back to a default.
    ///
    /// Only frame fills write the 8-digit form today (see
    /// `canvasColorHexString(from:includeOpacity:)`). Every other color is
    /// stored as `#RRGGBB` and parses as fully opaque.
    ///
    /// `nonisolated` because the project defaults type isolation to `MainActor`,
    /// and this init is called from `ContentView.init` (a non-isolated context).
    nonisolated init?(hex: String) {
        var s = hex
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6 || s.count == 8, let v = UInt32(s, radix: 16) else { return nil }
        // Shift a 6-digit value up a byte and give it solid opacity, so both
        // forms decode through the same `RRGGBBAA` layout below.
        let rgba = s.count == 6 ? (v << 8) | 0xFF : v
        let r = Double((rgba >> 24) & 0xFF) / 255
        let g = Double((rgba >> 16) & 0xFF) / 255
        let b = Double((rgba >> 8) & 0xFF) / 255
        let a = Double(rgba & 0xFF) / 255
        self = Color(red: r, green: g, blue: b, opacity: a)
    }
}

/// Hex string for a resolved color. Resolving requires an
/// `EnvironmentValues`, so this is split from the `Color` extension above:
/// the call site has the environment, this helper just formats.
///
/// By default opacity is dropped and the result is `#RRGGBB`. With
/// `includeOpacity`, a see-through color comes back as `#RRGGBBAA`. A solid
/// color still comes back as `#RRGGBB`, so a frame the user never made
/// see-through stores exactly what it stored before opacity existed.
func canvasColorHexString(from resolved: Color.Resolved, includeOpacity: Bool = false) -> String {
    func byte(_ x: Float) -> Int { max(0, min(255, Int((x * 255).rounded()))) }
    let rgb = String(format: "#%02X%02X%02X", byte(resolved.red), byte(resolved.green), byte(resolved.blue))
    let alpha = byte(resolved.opacity)
    guard includeOpacity, alpha < 255 else { return rgb }
    return rgb + String(format: "%02X", alpha)
}

import SwiftUI

/// The last text color the user picked, as a `#RRGGBB` string.
///
/// This is the one piece of color state we keep ourselves. Everything else —
/// the picker UI, and the favorites row inside it — is the system's:
/// `UIColorPickerViewController` already carries a saved-swatch row, so we
/// don't draw our own recents. But that row is *manually curated* (the user
/// taps "+" to add to it), shared system-wide rather than scoped to this app,
/// and exposes no API to read or seed. It therefore can't answer the one
/// question we need answered: "what color should the next text element start
/// in?" Hence this variable.
///
/// Stored app-wide rather than per-board: "the color I'm writing in" is a tool
/// setting, like a brush color, not board content. Until something *has* been
/// picked there's nothing to remember, so the starting color comes from the
/// canvas instead — see `defaultHex(onCanvas:)`.
enum TextColorMemory {
    /// `@AppStorage` key. Shared by the action bar and `BoardCanvasView` so
    /// both observe the same defaults value.
    nonisolated static let storageKey = "canvas.text.lastColorHex"

    /// The two candidates for an unset default — the palette's near-black and
    /// its white. Text picks whichever the canvas can actually show.
    nonisolated static let darkHex = "#191919"
    nonisolated static let lightHex = "#FFFFFF"

    /// Default color for new text on a canvas of `background`: whichever of
    /// `darkHex` / `lightHex` contrasts better against it.
    ///
    /// Keyed to the canvas color rather than the color scheme, because the
    /// canvas color is user-settable in board settings — a board with a light
    /// canvas still wants dark text on a device in dark mode, and a board
    /// whose canvas the user painted black wants light text in either.
    nonisolated static func defaultHex(onCanvas background: Color.Resolved) -> String {
        // W3C relative luminance. 0.179 is where the contrast ratio against
        // white and the ratio against black are equal, so it's the crossover
        // point for "which of the two is more readable here".
        let luminance = 0.2126 * Double(background.linearRed)
            + 0.7152 * Double(background.linearGreen)
            + 0.0722 * Double(background.linearBlue)
        return luminance > 0.179 ? darkHex : lightHex
    }

    /// Hex the next new text element should use. Falls back to the
    /// canvas-derived default when nothing has been stored yet or the stored
    /// value is malformed, so neither a fresh install nor a corrupt defaults
    /// entry can produce text the user can't see.
    nonisolated static func currentHex(from raw: String, onCanvas background: Color.Resolved) -> String {
        normalized(raw) ?? defaultHex(onCanvas: background)
    }

    /// Value to write back after the user picks `hex`, or `raw` unchanged if
    /// `hex` is malformed.
    nonisolated static func recording(_ hex: String, into raw: String) -> String {
        normalized(hex) ?? raw
    }

    /// Uppercase `#RRGGBB`, or nil if the input isn't an opaque 6-digit hex.
    private nonisolated static func normalized(_ hex: String) -> String? {
        var s = hex.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, UInt32(s, radix: 16) != nil else { return nil }
        return "#" + s.uppercased()
    }
}

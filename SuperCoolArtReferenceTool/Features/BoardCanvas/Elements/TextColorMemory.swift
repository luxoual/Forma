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
/// setting, like a brush color, not board content.
enum TextColorMemory {
    /// `@AppStorage` key. Shared by the action bar and `BoardCanvasView` so
    /// both observe the same defaults value.
    nonisolated static let storageKey = "canvas.text.lastColorHex"

    /// Color new text starts with before anything has been picked. Matches
    /// the palette primary that text was hard-coded to before it was settable.
    nonisolated static let defaultHex = "#191919"

    /// Hex the next new text element should use. Falls back to `defaultHex`
    /// when nothing has been stored yet or the stored value is malformed, so
    /// a corrupt defaults entry can't produce invisible text.
    nonisolated static func currentHex(from raw: String) -> String {
        normalized(raw) ?? defaultHex
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

import Foundation

/// Lightweight observable that delivers imported elements from the app open
/// handler down to ContentView, which can then route them to the canvas view.
@Observable
@MainActor
final class AppOpenHandler {
    var importedElements: [CMCanvasElement]?
    /// Canvas color stored in the imported board's manifest, as `#RRGGBB`.
    /// `nil` for legacy v1 boards (or files written before the field
    /// existed) — the canvas will fall back to the system background.
    var importedCanvasColorHex: String?
}

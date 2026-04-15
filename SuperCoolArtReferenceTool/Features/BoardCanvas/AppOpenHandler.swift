import Foundation

/// Lightweight observable that delivers imported elements from the app open
/// handler down to ContentView, which can then route them to the canvas view.
@Observable
@MainActor
final class AppOpenHandler {
    var importedElements: [CMCanvasElement]? = nil
}

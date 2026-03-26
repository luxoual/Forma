import Foundation
import SwiftUI
import Combine

/// A lightweight environment object to deliver imported elements from the app open handler
/// down to ContentView, which can then route them to the canvas view.
final class AppOpenHandler: ObservableObject {
    @Published var importedElements: [CMCanvasElement]? = nil
}

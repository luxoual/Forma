import SwiftUI
import UniformTypeIdentifiers

struct CanvasDropDelegate: DropDelegate {
    let allowedTypes: [UTType]
    let onDrop: (CGPoint, [URL]) -> Void

    func validateDrop(info: DropInfo) -> Bool {
        !info.itemProviders(for: allowedTypes).isEmpty
    }

    func performDrop(info: DropInfo) -> Bool {
        let providers = info.itemProviders(for: allowedTypes)
        let location = info.location
        Task {
            let urls = await loadURLsFromProviders(providers, preferredTypes: allowedTypes)
            if !urls.isEmpty {
                onDrop(location, urls)
            }
        }
        return true
    }
}

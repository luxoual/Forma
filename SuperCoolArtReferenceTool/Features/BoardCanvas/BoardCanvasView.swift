import SwiftUI
import UniformTypeIdentifiers

struct BoardCanvasView: View {
    typealias ImportHandler = ([URL]) -> Void
    private let onInsertURLs: ImportHandler

    @State private var isTargeted = false
    @State private var isImporterPresented = false

    private let allowedTypes: [UTType] = {
        var types: [UTType] = [.image]
        types.append(.gif)
        types.append(.movie)
        return types
    }()

    init(onInsertURLs: @escaping ImportHandler = { _ in }) {
        self.onInsertURLs = onInsertURLs
    }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            // Placeholder canvas background
            Color(.systemBackground)
                .ignoresSafeArea()
        }
        .onDrop(of: allowedTypes, isTargeted: $isTargeted) { providers in
            handleDrop(providers: providers)
        }
        .overlay(alignment: .top) {
            if isTargeted {
                Text("Drop to insert…")
                    .padding(8)
                    .background(.ultraThinMaterial, in: Capsule())
                    .padding()
            }
        }
        .overlay(alignment: .topTrailing) {
            InsertFileControl { urls in
                handleImportedURLs(urls)
            }
            .padding()
            .zIndex(1000)
        }
    }

    private func handleImportedURLs(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        onInsertURLs(urls)
    }

    private func handleDrop(providers: [NSItemProvider]) -> Bool {
        guard !providers.isEmpty else { return false }
        Task {
            let urls = await loadURLs(from: providers)
            if !urls.isEmpty {
                onInsertURLs(urls)
            }
        }
        return true
    }

    private func loadURLs(from providers: [NSItemProvider]) async -> [URL] {
        await withTaskGroup(of: URL?.self) { group in
            for provider in providers {
                if let firstType = allowedTypes.first(where: { provider.hasItemConformingToTypeIdentifier($0.identifier) }) {
                    group.addTask {
                        await withCheckedContinuation { (continuation: CheckedContinuation<URL?, Never>) in
                            // Try file representation first
                            provider.loadFileRepresentation(forTypeIdentifier: firstType.identifier) { url, _ in
                                if let url = url {
                                    continuation.resume(returning: url)
                                } else {
                                    provider.loadDataRepresentation(forTypeIdentifier: firstType.identifier) { data, _ in
                                        guard let data = data else {
                                            continuation.resume(returning: nil)
                                            return
                                        }
                                        let tempDir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
                                        let ext = firstType.preferredFilenameExtension ?? "dat"
                                        let filename = UUID().uuidString + "." + ext
                                        let url = tempDir.appendingPathComponent(filename)
                                        do {
                                            try data.write(to: url, options: [.atomic])
                                            continuation.resume(returning: url)
                                        } catch {
                                            continuation.resume(returning: nil)
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }

            var results: [URL] = []
            for await url in group {
                if let url { results.append(url) }
            }
            return results
        }
    }
}

#Preview {
    BoardCanvasView { urls in
        print("BoardCanvasView imported:", urls)
    }
}


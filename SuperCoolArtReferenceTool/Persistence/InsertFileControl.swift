import SwiftUI
import UniformTypeIdentifiers

public struct InsertFileControl: View {
    public typealias ImportHandler = ([URL]) -> Void

    private let onImportURLs: ImportHandler
    @State private var isImporterPresented = false
    @State private var isDropTargeted = false

    private let allowedTypes: [UTType] = {
        var types: [UTType] = [.image]
        // Explicitly include GIF and movie; GIF conforms to image but we include it for clarity
        if let gif = UTType.gif { types.append(gif) }
        types.append(.movie)
        return types
    }()

    public init(onImportURLs: @escaping ImportHandler) {
        self.onImportURLs = onImportURLs
    }

    public var body: some View {
        Button(action: { isImporterPresented = true }) {
            HStack(spacing: 8) {
                Image(systemName: "tray.and.arrow.down")
                Text("Insert File")
            }
            .font(.headline)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.secondary.opacity(0.15)))
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(isDropTargeted ? Color.accentColor : Color.secondary.opacity(0.4), lineWidth: isDropTargeted ? 2 : 1)
            )
        }
        .buttonStyle(.plain)
        .contentShape(RoundedRectangle(cornerRadius: 10))
        .fileImporter(isPresented: $isImporterPresented, allowedContentTypes: allowedTypes, allowsMultipleSelection: true) { result in
            switch result {
            case .success(let urls):
                onImportURLs(urls)
            case .failure:
                break
            }
        }
        .onDrop(of: allowedTypes, isTargeted: $isDropTargeted) { providers in
            handleDrop(providers: providers)
        }
        .accessibilityLabel(Text("Insert File"))
        .accessibilityHint(Text("Tap to choose files or drag and drop images or GIFs here."))
    }

    private func handleDrop(providers: [NSItemProvider]) -> Bool {
        guard !providers.isEmpty else { return false }
        // Load asynchronously and call handler when done
        Task {
            let urls = await loadURLs(from: providers, preferredTypes: allowedTypes)
            if !urls.isEmpty {
                onImportURLs(urls)
            }
        }
        return true
    }
}

// MARK: - Loading helpers

private extension InsertFileControl {
    func loadURLs(from providers: [NSItemProvider], preferredTypes: [UTType]) async -> [URL] {
        await withTaskGroup(of: URL?.self) { group in
            for provider in providers {
                // For each provider, pick the first matching type
                if let firstType = preferredTypes.first(where: { provider.hasItemConformingToTypeIdentifier($0.identifier) }) {
                    group.addTask {
                        // Try file representation first (gives us a temporary file URL)
                        if let url = await provider.loadFileURL(for: firstType) { return url }
                        // Fallback to data representation; write to temp file
                        if let dataURL = await provider.loadDataAsTempFile(for: firstType) { return dataURL }
                        return nil
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

private extension NSItemProvider {
    func loadFileURL(for type: UTType) async -> URL? {
        await withCheckedContinuation { continuation in
            self.loadFileRepresentation(forTypeIdentifier: type.identifier) { url, error in
                // url is a file we can read (may be a security-scoped temp copy)
                continuation.resume(returning: url)
            }
        }
    }

    func loadDataAsTempFile(for type: UTType) async -> URL? {
        await withCheckedContinuation { continuation in
            self.loadDataRepresentation(forTypeIdentifier: type.identifier) { data, error in
                guard let data else {
                    continuation.resume(returning: nil)
                    return
                }
                let tempDir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
                let ext = type.preferredFilenameExtension ?? "dat"
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

#Preview {
    VStack(spacing: 24) {
        InsertFileControl { urls in
            print("Imported URLs:", urls)
        }
        .padding()
        Text("Drag an image/GIF/movie onto the button or tap to choose a file.")
            .foregroundStyle(.secondary)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(Color(.secondarySystemBackground))
}

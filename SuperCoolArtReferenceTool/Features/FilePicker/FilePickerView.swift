//
//  FilePickerView.swift
//  SuperCoolArtReferenceTool
//
//  Created by andy lin on 2/16/26.
//

import SwiftUI
import UniformTypeIdentifiers

struct FilePickerView: View {
    @State private var isTargeted = false
    @State private var showingImagePicker = false

    var onFilesSelected: ([URL]) -> Void

    var body: some View {
        ZStack {
            // Background
            DesignSystem.Colors.primary
                .ignoresSafeArea()
            emptyStateView
        }
    }

    // MARK: - Empty State

    private var emptyStateView: some View {
        VStack(spacing: 24) {
            // Drop zone
            VStack(spacing: 16) {
                Image(systemName: "photo.on.rectangle.angled")
                    .font(.system(size: 80))
                    .foregroundStyle(DesignSystem.Colors.secondary)

                VStack(spacing: 8) {
                    Text("Drag and drop images here")
                        .font(.title3)
                        .foregroundStyle(DesignSystem.Colors.secondary)

                    Text("or")
                        .font(.subheadline)
                        .foregroundStyle(DesignSystem.Colors.secondary.opacity(0.7))
                }
            }
            .frame(maxWidth: 400)
            .padding(60)
            .background(
                RoundedRectangle(cornerRadius: 16)
                    .strokeBorder(
                        style: StrokeStyle(
                            lineWidth: 2,
                            dash: [10, 5]
                        )
                    )
                    .foregroundStyle(isTargeted ? DesignSystem.Colors.tertiary : DesignSystem.Colors.secondary.opacity(0.5))
            )
            .animation(.easeInOut(duration: 0.2), value: isTargeted)

            // Browse button
            Button {
                showingImagePicker = true
            } label: {
                Text("Browse")
                    .fontWeight(.semibold)
                    .foregroundStyle(DesignSystem.Colors.primary)
                    .padding(.horizontal, 32)
                    .padding(.vertical, 12)
                    .background(DesignSystem.Colors.tertiary)
                    .cornerRadius(8)
            }
            .buttonStyle(.plain)
        }
        .onDrop(of: [.image], isTargeted: $isTargeted) { providers in
            Task {
                let urls = await saveDroppedImages(providers: providers)
                if !urls.isEmpty {
                    await MainActor.run {
                        onFilesSelected(urls)
                    }
                }
            }
            return true
        }
        .fileImporter(
            isPresented: $showingImagePicker,
            allowedContentTypes: [.image, .gif],
            allowsMultipleSelection: true
        ) { result in
            switch result {
            case .success(let urls):
                if !urls.isEmpty {
                    onFilesSelected(urls)
                }
            case .failure(let error):
                print("Error selecting images: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Drag and Drop

    private func saveDroppedImages(providers: [NSItemProvider]) async -> [URL] {
        var urls: [URL] = []
        for provider in providers {
            guard provider.canLoadObject(ofClass: UIImage.self) else { continue }
            if let url = await loadImageToTempFile(from: provider) {
                urls.append(url)
            }
        }
        return urls
    }

    private func loadImageToTempFile(from provider: NSItemProvider) async -> URL? {
        await withCheckedContinuation { continuation in
            provider.loadObject(ofClass: UIImage.self) { object, _ in
                guard let image = object as? UIImage,
                      let data = image.pngData() else {
                    continuation.resume(returning: nil)
                    return
                }
                let tempURL = FileManager.default.temporaryDirectory
                    .appendingPathComponent(UUID().uuidString)
                    .appendingPathExtension("png")
                do {
                    try data.write(to: tempURL)
                    continuation.resume(returning: tempURL)
                } catch {
                    continuation.resume(returning: nil)
                }
            }
        }
    }
}

#Preview {
    FilePickerView(onFilesSelected: { _ in })
}

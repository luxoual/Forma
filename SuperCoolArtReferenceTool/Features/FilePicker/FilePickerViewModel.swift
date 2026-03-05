//
//  FilePickerViewModel.swift
//  SuperCoolArtReferenceTool
//
//  Created by andy lin on 2/16/26.
//

import SwiftUI
import UniformTypeIdentifiers

@Observable
class FilePickerViewModel {
    var images: [CanvasImage] = []
    var isTargeted = false // For drag-and-drop visual feedback
    
    // Add image from file picker
    func addImage(from url: URL) {
        guard url.startAccessingSecurityScopedResource() else {
            print("Failed to access file")
            return
        }
        defer { url.stopAccessingSecurityScopedResource() }
        
        if let imageData = try? Data(contentsOf: url),
           let uiImage = UIImage(data: imageData) {
            let canvasImage = CanvasImage(image: Image(uiImage: uiImage))
            images.append(canvasImage)
        }
    }
    
    // Add images from dropped items
    func handleDrop(providers: [NSItemProvider]) async {
        for provider in providers {
            if provider.canLoadObject(ofClass: UIImage.self) {
                _ = provider.loadObject(ofClass: UIImage.self) { image, error in
                    if let uiImage = image as? UIImage {
                        Task { @MainActor in
                            let canvasImage = CanvasImage(image: Image(uiImage: uiImage))
                            self.images.append(canvasImage)
                        }
                    }
                }
            }
        }
    }
    
    func removeImage(at offsets: IndexSet) {
        images.remove(atOffsets: offsets)
    }
}

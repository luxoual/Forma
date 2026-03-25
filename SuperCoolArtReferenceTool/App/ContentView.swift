//
//  ContentView.swift
//  SuperCoolArtReferenceTool
//
//  Created by andy lin on 2/16/26.
//

import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @State private var activeTool: CanvasTool = .pointer
    @State private var showingFilePicker = false
    @State private var urlsToInsert: [URL]? = nil

    var body: some View {
        ZStack(alignment: .leading) {
            BoardCanvasView(externalInsertURLs: $urlsToInsert) { urls in
                print("Imported URLs:", urls)
            }
            
            CanvasToolbar(
                activeTool: $activeTool,
                onUndo: { /* TODO: hook up undo */ },
                onRedo: { /* TODO: hook up redo */ },
                onAddItem: { showingFilePicker = true }
            )
            .padding(.leading, 16)
        }
        .fileImporter(
            isPresented: $showingFilePicker,
            allowedContentTypes: [.image, .gif],
            allowsMultipleSelection: true
        ) { result in
            switch result {
            case .success(let urls):
                urlsToInsert = urls
            case .failure(let error):
                print("Error selecting files: \(error.localizedDescription)")
            }
        }
    }
}

#Preview {
    ContentView()
}

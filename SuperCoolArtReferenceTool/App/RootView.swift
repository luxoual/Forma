//
//  RootView.swift
//  SuperCoolArtReferenceTool
//
//  Created by andy lin on 3/31/26.
//

import SwiftUI

struct RootView: View {
    @Environment(AppOpenHandler.self) private var openHandler

    @State private var showCanvas = false
    @State private var initialURLs: [URL] = []
    @State private var initialElements: [CMCanvasElement]? = nil

    var body: some View {
        if showCanvas {
            ContentView(initialURLs: initialURLs, initialElements: initialElements)
        } else {
            FilePickerView(onFilesSelected: { urls in
                initialElements = nil
                initialURLs = urls
                showCanvas = true
            })
            .onChange(of: openHandler.importedElements) { _, value in
                if let value {
                    initialURLs = []
                    initialElements = value
                    showCanvas = true
                }
            }
        }
    }
}

#Preview {
    RootView()
        .environment(AppOpenHandler())
}

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
    @State private var initialElements: [CMCanvasElement]?
    @State private var recentsManager = RecentBoardsManager()

    var body: some View {
        if showCanvas {
            ContentView(initialURLs: initialURLs, initialElements: initialElements)
                .environment(recentsManager)
        } else {
            FilePickerView(
                onNewBoard: {
                    initialElements = nil
                    initialURLs = []
                    showCanvas = true
                },
                onBoardSelected: { elements in
                    initialURLs = []
                    initialElements = elements
                    showCanvas = true
                },
                onFilesDropped: { urls in
                    initialElements = nil
                    initialURLs = urls
                    showCanvas = true
                }
            )
            .environment(recentsManager)
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
    @Previewable @State var handler = AppOpenHandler()
    RootView()
        .environment(handler)
}

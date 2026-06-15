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
    @State private var initialBoardURL: URL?
    /// Hex (`#RRGGBB`) read from the manifest when opening a board, or `nil`
    /// for new boards / legacy v1 files. `ContentView` resolves `nil` to the
    /// system background.
    @State private var initialCanvasColorHex: String?
    @State private var recentsManager = RecentBoardsManager()

    var body: some View {
        if showCanvas {
            ContentView(
                initialURLs: initialURLs,
                initialElements: initialElements,
                initialBoardURL: initialBoardURL,
                initialCanvasColorHex: initialCanvasColorHex,
                onBack: { showCanvas = false }
            )
            .environment(recentsManager)
        } else {
            FilePickerView(
                onNewBoard: { url in
                    initialElements = nil
                    initialURLs = []
                    initialBoardURL = url
                    initialCanvasColorHex = nil
                    showCanvas = true
                },
                onBoardSelected: { elements, url, colorHex in
                    initialURLs = []
                    initialElements = elements
                    initialBoardURL = url
                    initialCanvasColorHex = colorHex
                    showCanvas = true
                },
                onFilesDropped: { urls in
                    initialElements = nil
                    initialURLs = urls
                    initialBoardURL = nil
                    initialCanvasColorHex = nil
                    showCanvas = true
                }
            )
            .environment(recentsManager)
            .onChange(of: openHandler.importedElements) { _, value in
                if let value {
                    initialURLs = []
                    initialElements = value
                    initialCanvasColorHex = openHandler.importedCanvasColorHex
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

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
    /// Hex (`#RRGGBB`) of the last text color picked on the board being
    /// opened, or `nil` for new boards / boards where nothing was picked.
    /// `BoardCanvasView` resolves `nil` by deriving a readable color from
    /// the canvas background.
    @State private var initialLastTextColorHex: String?
    @State private var recentsManager = RecentBoardsManager()

    var body: some View {
        if showCanvas {
            ContentView(
                initialURLs: initialURLs,
                initialElements: initialElements,
                initialBoardURL: initialBoardURL,
                initialCanvasColorHex: initialCanvasColorHex,
                initialLastTextColorHex: initialLastTextColorHex,
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
                    initialLastTextColorHex = nil
                    showCanvas = true
                },
                onBoardSelected: { imported, url in
                    initialURLs = []
                    initialElements = imported.elements
                    initialBoardURL = url
                    initialCanvasColorHex = imported.canvasColorHex
                    initialLastTextColorHex = imported.lastTextColorHex
                    showCanvas = true
                },
                onFilesDropped: { urls in
                    initialElements = nil
                    initialURLs = urls
                    initialBoardURL = nil
                    initialCanvasColorHex = nil
                    initialLastTextColorHex = nil
                    showCanvas = true
                }
            )
            .environment(recentsManager)
            .onChange(of: openHandler.importedElements) { _, value in
                if let value {
                    initialURLs = []
                    initialElements = value
                    initialCanvasColorHex = openHandler.importedCanvasColorHex
                    initialLastTextColorHex = openHandler.importedLastTextColorHex
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

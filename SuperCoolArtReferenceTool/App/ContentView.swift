//
//  ContentView.swift
//  SuperCoolArtReferenceTool
//
//  Created by andy lin on 2/16/26.
//

import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @Environment(AppOpenHandler.self) private var openHandler
    @Environment(RecentBoardsManager.self) private var recentsManager

    let initialURLs: [URL]
    let initialElements: [CMCanvasElement]?
    let initialBoardURL: URL?
    var onBack: () -> Void = {}

    @State private var activeTool: CanvasTool = .pointer
    @State private var showingSettings = false
    @State private var urlsToInsert: [URL]?
    
    // Settings
    @State private var showGrid = true
    @State private var toolbarSide: ToolbarSide = .left
    @State private var canvasColor: Color = .white
    
    @State private var snapshotToken: UUID?
    @State private var elementsToLoad: [CMCanvasElement]?
    @State private var showingExporter = false
    @State private var exportDocument = BoardExportDocument(elements: [])

    // Undo/redo
    @State private var commandHistory = CanvasCommandHistory()
    @State private var undoTrigger: UUID?
    @State private var redoTrigger: UUID?

    @State private var importerMode: ImporterMode?
    @State private var importerPresented = false
    /// Latched copy so the result handler can read it even after the binding clears importerMode
    @State private var lastImporterMode: ImporterMode?
    private enum ImporterMode { case images, board }
    @State private var pendingBackNavigation = false
    @State private var currentBoardURL: URL?

    var body: some View {
        ZStack {
            BoardCanvasView(
                activeTool: $activeTool,
                externalInsertURLs: $urlsToInsert,
                showGrid: $showGrid,
                canvasColor: $canvasColor,
                snapshotTrigger: $snapshotToken,
                loadElements: $elementsToLoad,
                commandHistory: commandHistory,
                undoTrigger: $undoTrigger,
                redoTrigger: $redoTrigger,
                onInsertURLs: { _ in },
                onSnapshot: { elements in
                    if pendingBackNavigation {
                        pendingBackNavigation = false
                        saveAndGoBack(elements: elements)
                    } else {
                        exportDocument = BoardExportDocument(elements: elements)
                        showingExporter = true
                    }
                }
            )
            
            CanvasOverlayLayout(
                side: toolbarSide,
                activeTool: $activeTool,
                onBack: handleBack,
                onUndo: { undoTrigger = UUID() },
                onRedo: { redoTrigger = UUID() },
                onAddItem: openImageImporter,
                onSettings: { showingSettings = true }
            )
        }
        .overlay(alignment: .topTrailing) {
            HStack(spacing: 8) {
                Button("Export") {
                    snapshotToken = UUID()
                }
                .buttonStyle(.borderedProminent)

                Button("Import") {
                    importerMode = .board
                    lastImporterMode = .board
                    print("[UI] Import Board tapped")
                }
                .buttonStyle(.bordered)
            }
            .padding(12)
        }
        .fileExporter(
            isPresented: $showingExporter,
            document: exportDocument,
            contentType: .refboard,
            defaultFilename: "Board"
        ) { result in
            switch result {
            case .success(let url):
                currentBoardURL = url
                recentsManager.record(url: url)
            case .failure(let error):
                print("Export share failed: ", error.localizedDescription)
            }
        }
        .onChange(of: importerMode) { _, newMode in
            importerPresented = (newMode != nil)
        }
        .onChange(of: importerPresented) { _, presented in
            if !presented { importerMode = nil }
        }
        .fileImporter(
            isPresented: $importerPresented,
            allowedContentTypes: (importerMode == .images) ? [.image, .gif] : [.refboard],
            allowsMultipleSelection: importerMode == .images
        ) { result in
            let currentMode = lastImporterMode
            print("[Importer] Unified fileImporter fired (mode: \(String(describing: currentMode)))")
            switch result {
            case .success(let urls):
                if currentMode == .images {
                    print("[Importer] Selected image URLs count = \(urls.count)")
                    urlsToInsert = urls
                } else if currentMode == .board {
                    guard let url = urls.first else { return }
                    do {
                        let elements = try BoardArchiver.importElements(from: url, copyAssetsToAppSupport: true)
                        recentsManager.record(url: url)
                        currentBoardURL = url
                        elementsToLoad = elements
                    } catch {
                        print("Import failed: ", error)
                    }
                }
            case .failure(let error):
                print("[Importer] Import selection failed: \(error.localizedDescription)")
            }
            importerMode = nil
        }
        .sheet(isPresented: $showingSettings) {
            CanvasSettingsView(showGrid: $showGrid, toolbarSide: $toolbarSide, canvasColor: $canvasColor)
        }
        .onAppear {
            currentBoardURL = initialBoardURL
            if let initialElements, !initialElements.isEmpty {
                elementsToLoad = initialElements
                openHandler.importedElements = nil
            } else if !initialURLs.isEmpty {
                urlsToInsert = initialURLs
            }
        }
        .onChange(of: openHandler.importedElements) { _, value in
            if let els = value {
                elementsToLoad = els
                // Clear the open handler value to avoid repeated loads
                openHandler.importedElements = nil
            }
        }
    }
    
    private func openImageImporter() {
        print("[UI] Add Item tapped")
        importerMode = .images
        lastImporterMode = .images
    }

    private func handleBack() {
        pendingBackNavigation = true
        snapshotToken = UUID()
    }

    private func saveAndGoBack(elements: [CMCanvasElement]) {
        if let url = currentBoardURL {
            do {
                let accessing = url.startAccessingSecurityScopedResource()
                defer { if accessing { url.stopAccessingSecurityScopedResource() } }
                _ = try BoardArchiver.export(elements: elements, to: url)
                recentsManager.record(url: url)
            } catch {
                print("[Save] Failed to save board: \(error.localizedDescription)")
            }
        }
        onBack()
    }
}

#Preview {
    ContentView(initialURLs: [], initialElements: nil, initialBoardURL: nil)
        .environment(AppOpenHandler())
        .environment(RecentBoardsManager())
}

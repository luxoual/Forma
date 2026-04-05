//
//  ContentView.swift
//  SuperCoolArtReferenceTool
//
//  Created by andy lin on 2/16/26.
//

import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @EnvironmentObject private var openHandler: AppOpenHandler

    let initialURLs: [URL]

    @State private var activeTool: CanvasTool = .pointer
    @State private var showingSettings = false
    @State private var urlsToInsert: [URL]? = nil
    
    // Settings
    @State private var showGrid = true
    @State private var toolbarSide: ToolbarSide = .left
    @State private var canvasColor: Color = .white
    
    @State private var snapshotToken: UUID? = nil
    @State private var elementsToLoad: [CMCanvasElement]? = nil
    @State private var showingExporter = false
    @State private var exportDocument = BoardExportDocument(elements: [])

    @State private var importerMode: ImporterMode? = nil
    private enum ImporterMode { case images, board }

    var body: some View {
        ZStack {
            BoardCanvasView(
                externalInsertURLs: $urlsToInsert,
                showGrid: $showGrid,
                canvasColor: $canvasColor,
                snapshotTrigger: $snapshotToken,
                loadElements: $elementsToLoad,
                onInsertURLs: { _ in },
                onSnapshot: { elements in
                    // When snapshot arrives, prepare a FileDocument and present the exporter
                    exportDocument = BoardExportDocument(elements: elements)
                    showingExporter = true
                }
            )
            
            // Dynamic layout based on toolbar side
            if toolbarSide == .left {
                leftSideLayout
            } else {
                rightSideLayout
            }
        }
        .overlay(alignment: .topTrailing) {
            HStack(spacing: 8) {
                Button("Export") {
                    snapshotToken = UUID()
                }
                .buttonStyle(.borderedProminent)

                Button("Import") {
                    importerMode = .board
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
            case .success:
                break
            case .failure(let error):
                print("Export share failed: ", error.localizedDescription)
            }
        }
        .fileImporter(
            isPresented: Binding(
                get: { importerMode != nil },
                set: { _ in /* keep mode until handler runs */ }
            ),
            allowedContentTypes: (importerMode == .images) ? [.image, .gif] : [.refboard, .package, .folder],
            allowsMultipleSelection: importerMode == .images
        ) { result in
            let currentMode = importerMode
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
            if !initialURLs.isEmpty {
                urlsToInsert = initialURLs
            }
        }
        .onReceive(openHandler.$importedElements) { value in
            if let els = value {
                elementsToLoad = els
                // Clear the open handler value to avoid repeated loads
                openHandler.importedElements = nil
            }
        }
    }
    
    // MARK: - Layout Variants
    
    private var leftSideLayout: some View {
        Group {
            // Main toolbar (centered vertically on left side)
            HStack {
                CanvasToolbar(
                    activeTool: $activeTool,
                    onUndo: { /* TODO: hook up undo */ },
                    onRedo: { /* TODO: hook up redo */ },
                    onAddItem: {
                        print("[UI] Add Item tapped")
                        importerMode = .images
                    }
                )
                .padding(.leading, 16)
                
                Spacer()
            }
            
            // Settings button (bottom-left)
            VStack {
                Spacer()
                HStack {
                    CanvasSettingsButton {
                        showingSettings = true
                    }
                    .padding(.leading, 16)
                    .padding(.bottom, 16)
                    
                    Spacer()
                }
            }
        }
    }
    
    private var rightSideLayout: some View {
        Group {
            // Main toolbar (centered vertically on right side)
            HStack {
                Spacer()
                
                CanvasToolbar(
                    activeTool: $activeTool,
                    onUndo: { /* TODO: hook up undo */ },
                    onRedo: { /* TODO: hook up redo */ },
                    onAddItem: {
                        print("[UI] Add Item tapped")
                        importerMode = .images
                    }
                )
                .padding(.trailing, 16)
            }
            
            // Settings button (bottom-right)
            VStack {
                Spacer()
                HStack {
                    Spacer()
                    
                    CanvasSettingsButton {
                        showingSettings = true
                    }
                    .padding(.trailing, 16)
                    .padding(.bottom, 16)
                }
            }
        }
    }
}

#Preview {
    ContentView(initialURLs: [])
        .environmentObject(AppOpenHandler())
}


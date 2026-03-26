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
    @State private var showingSettings = false
    @State private var urlsToInsert: [URL]? = nil
    
    // Settings
    @State private var showGrid = true
    @State private var toolbarSide: ToolbarSide = .left

    var body: some View {
        ZStack {
            BoardCanvasView(
                externalInsertURLs: $urlsToInsert,
                showGrid: $showGrid
            )
            
            // Dynamic layout based on toolbar side
            if toolbarSide == .left {
                leftSideLayout
            } else {
                rightSideLayout
            }
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
        .sheet(isPresented: $showingSettings) {
            CanvasSettingsView(showGrid: $showGrid, toolbarSide: $toolbarSide)
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
                    onAddItem: { showingFilePicker = true }
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
                    onAddItem: { showingFilePicker = true }
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
    ContentView()
}

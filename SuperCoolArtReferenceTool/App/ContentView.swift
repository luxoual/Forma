//
//  ContentView.swift
//  SuperCoolArtReferenceTool
//
//  Created by andy lin on 2/16/26.
//

import SwiftUI
import UniformTypeIdentifiers
import os

struct ContentView: View {
    @Environment(AppOpenHandler.self) private var openHandler
    @Environment(RecentBoardsManager.self) private var recentsManager
    @Environment(\.scenePhase) private var scenePhase

    let initialURLs: [URL]
    let initialElements: [CMCanvasElement]?
    let initialBoardURL: URL?
    var onBack: () -> Void = {}

    @State private var activeTool: CanvasTool = .pointer
    @State private var showingSettings = false
    @State private var urlsToInsert: [URL]?
    
    // Settings
    @State private var showGrid = true
    @State private var canvasColor: Color = .white
    
    @State private var snapshotToken: UUID?
    @State private var elementsToLoad: [CMCanvasElement]?

    // Undo/redo
    @State private var commandHistory = CanvasCommandHistory()
    @State private var undoTrigger: UUID?
    @State private var redoTrigger: UUID?
    @State private var markCleanTrigger: UUID?

    @State private var importerPresented = false
    @State private var pendingBackNavigation = false
    @State private var pendingBackgroundSave = false
    @State private var currentBoardURL: URL?
    @State private var showSaveError = false
    @State private var saveErrorMessage = ""
    @State private var showBoardError = false
    @State private var boardErrorMessage = ""

    var body: some View {
        NavigationStack {
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
                markCleanTrigger: $markCleanTrigger,
                onInsertURLs: { _ in },
                onSnapshot: { elements, wasDirty in
                    if pendingBackNavigation {
                        pendingBackNavigation = false
                        saveAndGoBack(elements: elements, wasDirty: wasDirty)
                    } else if pendingBackgroundSave {
                        pendingBackgroundSave = false
                        saveInPlace(elements: elements, wasDirty: wasDirty)
                    }
                }
            )
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { canvasToolbar }
        }
        .fileImporter(
            isPresented: $importerPresented,
            allowedContentTypes: [.image, .gif],
            allowsMultipleSelection: true
        ) { result in
            Logger.importer.info("fileImporter fired")
            switch result {
            case .success(let urls):
                Logger.importer.info("Selected image URLs count = \(urls.count, privacy: .public)")
                urlsToInsert = urls
            case .failure(let error):
                boardErrorMessage = error.localizedDescription
                showBoardError = true
            }
        }
        .sheet(isPresented: $showingSettings) {
            CanvasSettingsView(showGrid: $showGrid, canvasColor: $canvasColor)
        }
        .alert("Save Failed", isPresented: $showSaveError) {
            Button("Discard & Leave", role: .destructive) { onBack() }
            Button("Stay", role: .cancel) { }
        } message: {
            Text(saveErrorMessage)
        }
        .alert("Board Error", isPresented: $showBoardError) {
        } message: {
            Text(boardErrorMessage)
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
        .onChange(of: scenePhase) { oldPhase, newPhase in
            Logger.scenePhase.info("phase: \(String(describing: oldPhase), privacy: .public) → \(String(describing: newPhase), privacy: .public)")
            // Autosave on `.inactive`. We can't use `.background` because force-quit from the
            // app switcher sends SIGKILL before `.background` fires — the lifecycle goes
            // `.active → .inactive → killed`, skipping `.background`. `.inactive` does fire on
            // Control Center / Notification Center pulls too, but the dirty flag makes those
            // a cheap no-op, and the incremental export keeps real saves fast enough to finish
            // before the user can swipe the app card away.
            if newPhase == .inactive, currentBoardURL != nil, !pendingBackNavigation {
                pendingBackgroundSave = true
                snapshotToken = UUID()
            }
        }
    }
    
    private var boardName: String {
        currentBoardURL?.deletingPathExtension().lastPathComponent ?? "Untitled Board"
    }

    /// The canvas nav-bar toolbar.
    ///
    /// - Back chevron (leading).
    /// - Board name in `.principal`, wrapped in its own `.glassEffect()`
    ///   capsule so it stays legible regardless of canvas color showing
    ///   through the translucent nav bar.
    /// - Tool selection as a segmented `Picker` — iOS 26's segmented control
    ///   has the native morphing/bubble selection indicator (the animation
    ///   you see in Camera-mode pickers), so no manual matched-geometry.
    /// - History and add as separate items, split by `ToolbarSpacer` so they
    ///   render as their own glass capsules.
    /// - Every button uses `Label("Title", systemImage: …)` (not bare
    ///   `Image + accessibilityLabel`) so the system overflow menu can
    ///   populate its dropdown from the titles when the bar collapses.
    @ToolbarContentBuilder
    private var canvasToolbar: some ToolbarContent {
        // Back chevron + board name share one leading ToolbarItemGroup pill
        // — same pattern as the tools group on the right. The boardName is a
        // disabled plain Button (no inner `.buttonStyle(.glass)`), so the
        // group's outer pill is the only glass surface, no nesting.
        ToolbarItemGroup(placement: .topBarLeading) {
            Button(action: handleBack) {
                Label("Back to home", systemImage: "chevron.left")
            }

            Button { } label: {
                Text(boardName)
                    .font(.headline)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: 220)
            }
            .tint(DesignSystem.Colors.tertiary)
            .allowsHitTesting(false)
            .accessibilityRemoveTraits(.isButton)
        }

        // Tools as discrete Buttons in a single ToolbarItemGroup — one glass
        // capsule, three buttons inside, same shape/feel as the history group.
        // Active tool reads via tertiary `.tint` (passing nil for inactive
        // keeps the system default).
        ToolbarItemGroup(placement: .topBarTrailing) {
            Button { activeTool = .pointer } label: {
                Label("Pointer", systemImage: "arrow.up.left")
            }
            .tint(activeTool == .pointer ? DesignSystem.Colors.tertiary : nil)

            Button { activeTool = .group } label: {
                Label("Group", systemImage: "rectangle.dashed")
            }
            .tint(activeTool == .group ? DesignSystem.Colors.tertiary : nil)

            Button { activeTool = .text } label: {
                Label("Text", systemImage: "textformat")
            }
            .tint(activeTool == .text ? DesignSystem.Colors.tertiary : nil)
        }

        ToolbarSpacer(.fixed, placement: .topBarTrailing)

        ToolbarItemGroup(placement: .topBarTrailing) {
            Button { undoTrigger = UUID() } label: {
                Label("Undo", systemImage: "arrow.uturn.backward")
            }
            Button { redoTrigger = UUID() } label: {
                Label("Redo", systemImage: "arrow.uturn.forward")
            }
        }

        ToolbarSpacer(.fixed, placement: .topBarTrailing)

        ToolbarItem(placement: .topBarTrailing) {
            Button(action: openImageImporter) {
                Label("Add", systemImage: "plus")
            }
        }

        ToolbarItem(placement: .topBarTrailing) {
            Button { showingSettings = true } label: {
                Label("Settings", systemImage: "gear")
            }
        }
    }

    private func openImageImporter() {
        Logger.importer.notice("Add Item tapped")
        importerPresented = true
    }

    private func handleBack() {
        pendingBackNavigation = true
        snapshotToken = UUID()
    }

    /// Autosave runs synchronously on MainActor so the write completes before the user can
    /// force-quit. The incremental `BoardArchiver.export` is fast enough — a clean-board save
    /// is a manifest-only rewrite (~5 ms); adding one image copies a single file (~50 ms).
    /// Off-main would be smoother for active use, but nothing calls this during active use —
    /// `.inactive` means the user is already out of the canvas view.
    private func saveInPlace(elements: [CMCanvasElement], wasDirty: Bool) {
        guard wasDirty, let url = currentBoardURL else { return }
        let startedAt = Date()
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        do {
            _ = try BoardArchiver.export(elements: elements, to: url)
            let ms = Int(Date().timeIntervalSince(startedAt) * 1000)
            Logger.save.logSaveSuccess(elements: elements.count, url: url, durationMs: ms)
            markCleanTrigger = UUID()
        } catch {
            Logger.save.logSaveFailure(url: url, error: error)
        }
    }

    private func saveAndGoBack(elements: [CMCanvasElement], wasDirty: Bool) {
        guard wasDirty, let url = currentBoardURL else {
            onBack()
            return
        }
        Task {
            let failure: Error? = await Task.detached(priority: .userInitiated) {
                let accessing = url.startAccessingSecurityScopedResource()
                defer { if accessing { url.stopAccessingSecurityScopedResource() } }
                do {
                    _ = try BoardArchiver.export(elements: elements, to: url)
                    return nil as Error?
                } catch {
                    return error
                }
            }.value
            if let failure {
                saveErrorMessage = "Could not save board: \(failure.localizedDescription)"
                showSaveError = true
            } else {
                markCleanTrigger = UUID()
                onBack()
            }
        }
    }
}

#Preview {
    ContentView(initialURLs: [], initialElements: nil, initialBoardURL: nil)
        .environment(AppOpenHandler())
        .environment(RecentBoardsManager())
}

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
    /// Used to resolve `canvasColor` to concrete RGB at save time so the hex
    /// we write into the manifest matches what the user sees on screen
    /// (even if the picked color was an adaptive system color).
    @Environment(\.self) private var environment

    let initialURLs: [URL]
    let initialElements: [CMCanvasElement]?
    let initialBoardURL: URL?
    /// `#RRGGBB` read from the board's manifest, or `nil` for new boards
    /// and legacy v1 files. `nil` resolves to the platform's system
    /// background (white in light mode, near-black in dark mode), so the
    /// canvas adapts to the user's preference until they pick something
    /// explicit in Settings.
    let initialCanvasColorHex: String?
    /// `#RRGGBB` of the last text color picked on this board, or `nil` when
    /// the board predates the field or nothing has been picked. Kept per
    /// board rather than app-wide: a dark board and a light board want
    /// different text, and one shouldn't overwrite the other's choice.
    let initialLastTextColorHex: String?
    var onBack: () -> Void = {}

    @State private var activeTool: CanvasTool = .pointer
    @State private var showingSettings = false
    @State private var urlsToInsert: [URL]?

    // Settings
    @State private var showGrid = true
    // Initial value comes from the saved manifest hex when present, else the
    // system background. We use `_canvasColor` form in `init` so the @State
    // wrapper is initialized from a constructor param rather than a literal.
    @State private var canvasColor: Color
    
    @State private var snapshotToken: UUID?
    @State private var elementsToLoad: [CMCanvasElement]?

    // Undo/redo/home
    @State private var commandHistory = CanvasCommandHistory()
    @State private var undoTrigger: UUID?
    @State private var redoTrigger: UUID?
    @State private var homeTrigger: UUID?
    @State private var markCleanTrigger: UUID?

    @State private var importerPresented = false
    @State private var pendingBackNavigation = false
    @State private var pendingBackgroundSave = false
    @State private var currentBoardURL: URL?
    @State private var showSaveError = false
    @State private var saveErrorMessage = ""
    @State private var showBoardError = false
    @State private var boardErrorMessage = ""
    /// True once the user picks a non-initial canvas color. `BoardCanvasView`'s
    /// dirty flag only tracks the element store, so a color-only change wouldn't
    /// otherwise trigger autosave — `wasDirty` would come back false and
    /// `saveInPlace` would bail. Cleared in lockstep with `markCleanTrigger`
    /// after a successful save.
    @State private var canvasColorDirty = false
    /// The hex that should be written to the manifest on the next save. Seeded
    /// from `initialCanvasColorHex` and only mutated when the user actually
    /// picks a color, so a board with no saved preference (`nil`) keeps that
    /// state across element-edit autosaves — the canvas continues to follow
    /// the system background instead of getting a baked-in color the first
    /// time the user moves anything.
    @State private var savedCanvasColorHex: String?

    /// Last text color picked on this board, written to the manifest on save.
    /// Bound into `BoardCanvasView`, which reads it to seed new text and
    /// writes it back whenever the user picks. `nil` until the first pick.
    @State private var lastTextColorHex: String?
    /// Same role as `canvasColorDirty`: a color-only change doesn't touch the
    /// element store, so `wasDirty` would come back false and `saveInPlace`
    /// would bail without persisting the pick. Cleared alongside
    /// `markCleanTrigger` after a successful save.
    @State private var lastTextColorDirty = false

    /// Custom init so `canvasColor` can default to either the manifest's saved
    /// hex (when reopening a board) or the system background (new boards,
    /// legacy v1 files). The remaining stored / @State properties keep their
    /// declaration-site defaults.
    init(
        initialURLs: [URL],
        initialElements: [CMCanvasElement]?,
        initialBoardURL: URL?,
        initialCanvasColorHex: String? = nil,
        initialLastTextColorHex: String? = nil,
        onBack: @escaping () -> Void = {}
    ) {
        self.initialURLs = initialURLs
        self.initialElements = initialElements
        self.initialBoardURL = initialBoardURL
        self.initialCanvasColorHex = initialCanvasColorHex
        self.initialLastTextColorHex = initialLastTextColorHex
        self.onBack = onBack
        let initial = initialCanvasColorHex.flatMap(Color.init(hex:))
            ?? Color(uiColor: .systemBackground)
        _canvasColor = State(initialValue: initial)
        _savedCanvasColorHex = State(initialValue: initialCanvasColorHex)
        _lastTextColorHex = State(initialValue: initialLastTextColorHex)
    }

    var body: some View {
        NavigationStack {
            BoardCanvasView(
                activeTool: $activeTool,
                externalInsertURLs: $urlsToInsert,
                showGrid: $showGrid,
                canvasColor: $canvasColor,
                lastTextColorHex: $lastTextColorHex,
                snapshotTrigger: $snapshotToken,
                loadElements: $elementsToLoad,
                commandHistory: commandHistory,
                undoTrigger: $undoTrigger,
                redoTrigger: $redoTrigger,
                homeTrigger: $homeTrigger,
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
            .toolbar {
                CanvasNavigationToolbar(
                    boardName: boardName,
                    activeTool: $activeTool,
                    onBack: handleBack,
                    onUndo: { undoTrigger = UUID() },
                    onRedo: { redoTrigger = UUID() },
                    onHome: { homeTrigger = UUID() },
                    onAddItem: openImageImporter,
                    onSettings: { showingSettings = true }
                )
            }
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
        // `.onChange` skips the value `canvasColor` was initialized to in
        // `init`, so this only fires on real user picks (or programmatic
        // changes after first render). Resolve the picked Color to concrete
        // RGB right here — that's the value we'll write to the manifest, and
        // doing it once at pick-time (vs every save) keeps "nil == no
        // preference" stable across element-edit autosaves on boards the
        // user hasn't touched the color on.
        .onChange(of: canvasColor) { _, newValue in
            savedCanvasColorHex = canvasColorHexString(from: newValue.resolve(in: environment))
            canvasColorDirty = true
        }
        // Already a concrete hex by the time the canvas writes it back, so
        // unlike `canvasColor` there's nothing to resolve here — this exists
        // purely to mark the board dirty, since picking a text color may not
        // touch the element store at all (e.g. picking with nothing selected
        // is a no-op on elements but still changes what new text will use).
        .onChange(of: lastTextColorHex) { _, _ in
            lastTextColorDirty = true
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
        // The board needs persisting if the element store changed or the user
        // picked a new canvas / text color since open.
        guard wasDirty || canvasColorDirty || lastTextColorDirty,
              let url = currentBoardURL else { return }
        let startedAt = Date()
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        do {
            _ = try BoardArchiver.export(
                elements: elements,
                canvasColorHex: savedCanvasColorHex,
                lastTextColorHex: lastTextColorHex,
                to: url
            )
            let ms = Int(Date().timeIntervalSince(startedAt) * 1000)
            Logger.save.logSaveSuccess(elements: elements.count, url: url, durationMs: ms)
            markCleanTrigger = UUID()
            canvasColorDirty = false
            lastTextColorDirty = false
        } catch {
            Logger.save.logSaveFailure(url: url, error: error)
        }
    }

    private func saveAndGoBack(elements: [CMCanvasElement], wasDirty: Bool) {
        guard wasDirty || canvasColorDirty || lastTextColorDirty,
              let url = currentBoardURL else {
            onBack()
            return
        }
        // Both are plain `String?`, already Sendable — no env resolution
        // needed at the actor boundary.
        let colorHex = savedCanvasColorHex
        let textColorHex = lastTextColorHex
        Task {
            let failure: Error? = await Task.detached(priority: .userInitiated) {
                let accessing = url.startAccessingSecurityScopedResource()
                defer { if accessing { url.stopAccessingSecurityScopedResource() } }
                do {
                    _ = try BoardArchiver.export(
                        elements: elements,
                        canvasColorHex: colorHex,
                        lastTextColorHex: textColorHex,
                        to: url
                    )
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
                canvasColorDirty = false
                lastTextColorDirty = false
                onBack()
            }
        }
    }
}

#Preview {
    ContentView(initialURLs: [], initialElements: nil, initialBoardURL: nil, initialCanvasColorHex: nil)
        .environment(AppOpenHandler())
        .environment(RecentBoardsManager())
}

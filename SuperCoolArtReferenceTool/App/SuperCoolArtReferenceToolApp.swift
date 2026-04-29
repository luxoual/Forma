//
//  SuperCoolArtReferenceToolApp.swift
//  SuperCoolArtReferenceTool
//
//  Created by andy lin on 2/16/26.
//

import SwiftUI
import os

@main
struct SuperCoolArtReferenceToolApp: App {
    @State private var openHandler = AppOpenHandler()
    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(openHandler)
                .onOpenURL { url in
                    Logger.app.notice("onOpenURL received: \(url.lastPathComponent, privacy: .public) (provider: \(fileProviderDescription(for: url), privacy: .public))")
                    Task {
                        guard url.pathExtension.lowercased() == "refboard" else { return }
                        do {
                            let elements = try BoardArchiver.importElements(from: url, copyAssetsToAppSupport: true)
                            await MainActor.run {
                                openHandler.importedElements = elements
                            }
                        } catch {
                            Logger.app.error("Failed to import .refboard: \(error.localizedDescription, privacy: .public)")
                        }
                    }
                }
        }
    }
}

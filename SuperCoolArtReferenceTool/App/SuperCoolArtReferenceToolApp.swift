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
                    Logger.app.logURLReceipt(url: url, kind: "onOpenURL")
                    Task {
                        guard url.pathExtension.lowercased() == "refboard" else { return }
                        do {
                            let elements = try BoardArchiver.importElements(from: url, copyAssetsToAppSupport: true)
                            await MainActor.run {
                                openHandler.importedElements = elements
                            }
                        } catch {
                            Logger.app.logFailure("Failed to import .refboard", error: error)
                        }
                    }
                }
        }
    }
}

//
//  SuperCoolArtReferenceToolApp.swift
//  SuperCoolArtReferenceTool
//
//  Created by andy lin on 2/16/26.
//

import SwiftUI

@main
struct SuperCoolArtReferenceToolApp: App {
    @StateObject private var openHandler = AppOpenHandler()
    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(openHandler)
                .onOpenURL { url in
                    Task {
                        guard url.pathExtension.lowercased() == "refboard" else { return }
                        do {
                            let elements = try BoardArchiver.importElements(from: url, copyAssetsToAppSupport: true)
                            await MainActor.run {
                                openHandler.importedElements = elements
                            }
                        } catch {
                            print("Failed to import .refboard: ", error)
                        }
                    }
                }
        }
    }
}

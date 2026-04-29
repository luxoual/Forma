//
//  Loggers.swift
//  SuperCoolArtReferenceTool
//
//  Created by andy lin on 4/28/26.
//

import Foundation
import os

// Tracks whatever bundle id the current build was signed with so per-dev signing
// (no shared developer certificate) doesn't break `log stream --predicate 'subsystem == ...'`.
// Falls back to the canonical id only if Info.plist somehow lacks one.
private let subsystem = Bundle.main.bundleIdentifier ?? "AxI.SuperCoolArtReferenceTool1"

extension Logger {
    static let app = Logger(subsystem: subsystem, category: "App")
    static let save = Logger(subsystem: subsystem, category: "Save")
    static let recents = Logger(subsystem: subsystem, category: "RecentBoards")
    static let archiver = Logger(subsystem: subsystem, category: "Archiver")
    static let importer = Logger(subsystem: subsystem, category: "Importer")
    static let scenePhase = Logger(subsystem: subsystem, category: "ScenePhase")
}

extension OSSignposter {
    static let archiver = OSSignposter(subsystem: subsystem, category: "Archiver")
}

/// Identifies which file provider backs a given URL — iCloud Drive, on-device storage,
/// or a third-party Files extension (Working Copy, Dropbox, etc.). Useful in diagnostic
/// logs so we can distinguish behavior across providers without correlating raw paths.
func fileProviderDescription(for url: URL) -> String {
    let path = url.path

    if path.contains("com~apple~CloudDocs") {
        return "iCloud Drive"
    }

    if let range = path.range(of: "/CloudStorage/") {
        let tail = path[range.upperBound...]
        if let slash = tail.firstIndex(of: "/") {
            return "FileProvider:\(tail[..<slash])"
        }
        return "FileProvider"
    }

    if let range = path.range(of: "/Mobile Documents/iCloud~") {
        let tail = path[range.upperBound...]
        if let slash = tail.firstIndex(of: "/") {
            return "iCloudContainer:\(tail[..<slash])"
        }
        return "iCloudContainer"
    }

    if path.contains("/Containers/Data/Application/") {
        return "AppContainer"
    }

    if path.hasPrefix("/Users/") {
        return "Simulator"
    }

    return "Other"
}

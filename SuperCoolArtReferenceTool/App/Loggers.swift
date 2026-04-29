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
    nonisolated static let app = Logger(subsystem: subsystem, category: "App")
    nonisolated static let save = Logger(subsystem: subsystem, category: "Save")
    nonisolated static let recents = Logger(subsystem: subsystem, category: "RecentBoards")
    nonisolated static let archiver = Logger(subsystem: subsystem, category: "Archiver")
    nonisolated static let importer = Logger(subsystem: subsystem, category: "Importer")
    nonisolated static let scenePhase = Logger(subsystem: subsystem, category: "ScenePhase")
}

extension OSSignposter {
    nonisolated static let archiver = OSSignposter(subsystem: subsystem, category: "Archiver")
}

// MARK: - Privacy-aware log helpers
//
// These helpers wrap the common log shapes so the privacy decision (DEBUG → .public for
// `log stream` debugging; release → .private(mask: .hash) so lines stay correlatable
// without leaking) lives in one place. Adding a new persistence-related log? Add a
// helper here rather than calling `Logger.<category>.info(...)` directly, so the privacy
// rule stays uniform across the codebase. `OSLogPrivacy` can't be extended with custom
// values — the OSLog macro requires built-in static members at compile time — so we route
// through these wrappers instead.

extension Logger {
    /// Autosave success. Filename privacy varies by build; element count, duration, and
    /// provider class are always public (non-sensitive).
    nonisolated func logSaveSuccess(elements: Int, url: URL, durationMs: Int) {
        let provider = fileProviderDescription(for: url)
        #if DEBUG
        self.info("Autosave wrote \(elements, privacy: .public) elements to \(url.lastPathComponent, privacy: .public) in \(durationMs, privacy: .public)ms (provider: \(provider, privacy: .public))")
        #else
        self.info("Autosave wrote \(elements, privacy: .public) elements to \(url.lastPathComponent, privacy: .private(mask: .hash)) in \(durationMs, privacy: .public)ms (provider: \(provider, privacy: .public))")
        #endif
    }

    /// Save failure. Surfaces `LocalizedError.failureReason` so `ArchiverError`'s
    /// associated values (bad ZIP entry path, underlying error) reach logs.
    nonisolated func logSaveFailure(url: URL, error: Error) {
        let provider = fileProviderDescription(for: url)
        let suffix = failureReasonSuffix(for: error)
        #if DEBUG
        self.error("Autosave failed for \(url.lastPathComponent, privacy: .public) (provider: \(provider, privacy: .public)): \(error.localizedDescription, privacy: .public)\(suffix, privacy: .public)")
        #else
        self.error("Autosave failed for \(url.lastPathComponent, privacy: .private(mask: .hash)) (provider: \(provider, privacy: .public)): \(error.localizedDescription, privacy: .private(mask: .hash))\(suffix, privacy: .private(mask: .hash))")
        #endif
    }

    /// URL receipt — for app-open / fileImporter entry points where we want to know the
    /// URL arrived at all (separate from any subsequent failure log).
    nonisolated func logURLReceipt(url: URL, kind: String) {
        let provider = fileProviderDescription(for: url)
        #if DEBUG
        self.notice("\(kind, privacy: .public) received: \(url.lastPathComponent, privacy: .public) (provider: \(provider, privacy: .public))")
        #else
        self.notice("\(kind, privacy: .public) received: \(url.lastPathComponent, privacy: .private(mask: .hash)) (provider: \(provider, privacy: .public))")
        #endif
    }

    /// Generic error log without a URL — surfaces `LocalizedError.failureReason`.
    nonisolated func logFailure(_ context: String, error: Error) {
        let suffix = failureReasonSuffix(for: error)
        #if DEBUG
        self.error("\(context, privacy: .public): \(error.localizedDescription, privacy: .public)\(suffix, privacy: .public)")
        #else
        self.error("\(context, privacy: .public): \(error.localizedDescription, privacy: .private(mask: .hash))\(suffix, privacy: .private(mask: .hash))")
        #endif
    }

    /// Archive-open failure — pairs a sensitive filename with the ZIP-tail probe result
    /// (always public, since the probe output is bounded developer-controlled text).
    nonisolated func logArchiveOpenFailed(url: URL, probe: String) {
        #if DEBUG
        self.error("Archive open failed for \(url.lastPathComponent, privacy: .public). \(probe, privacy: .public)")
        #else
        self.error("Archive open failed for \(url.lastPathComponent, privacy: .private(mask: .hash)). \(probe, privacy: .public)")
        #endif
    }
}

/// Extracts `LocalizedError.failureReason` as a `" — \(reason)"` suffix to fold into
/// existing Logger format strings. Returns empty when the error doesn't conform to
/// `LocalizedError` or has no reason — pairs with `BoardArchiver.ArchiverError`
/// whose associated values surface bad ZIP entry paths and underlying errors.
nonisolated func failureReasonSuffix(for error: Error) -> String {
    (error as? LocalizedError)?.failureReason.map { " — \($0)" } ?? ""
}

/// Identifies which broad storage class backs a given URL. Release builds return
/// only the broad class; DEBUG builds extend `FileProvider` / `iCloudContainer`
/// with the provider's bundle suffix (`FileProvider:WorkingCopy-XYZ`) so we can
/// attribute provider-specific bugs without leaking that data into release logs.
nonisolated func fileProviderDescription(for url: URL) -> String {
    let path = url.path

    if path.contains("com~apple~CloudDocs") {
        return "iCloud Drive"
    }

    if path.contains("/CloudStorage/") {
        #if DEBUG
        if let range = path.range(of: "/CloudStorage/") {
            let tail = path[range.upperBound...]
            if let slash = tail.firstIndex(of: "/") {
                return "FileProvider:\(tail[..<slash])"
            }
        }
        #endif
        return "FileProvider"
    }

    if path.contains("/Mobile Documents/iCloud~") {
        #if DEBUG
        if let range = path.range(of: "/Mobile Documents/iCloud~") {
            let tail = path[range.upperBound...]
            if let slash = tail.firstIndex(of: "/") {
                return "iCloudContainer:\(tail[..<slash])"
            }
        }
        #endif
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

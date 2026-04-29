//
//  BoardArchiver.swift
//  SuperCoolArtReferenceTool
//
//  Created by Xcode Assistant on 3/26/26.
//

import Foundation
import ZIPFoundation
import simd
import os

/// Handles importing and exporting reference board data as single-file `.refboard` ZIPs
/// that contain a package layout (manifest + assets).
/// Currently supports a JSON manifest (`manifest.json`) and image-based elements, with optional
/// copying of referenced assets into the app's Application Support directory.
enum BoardArchiver {
    /// Import elements from a `.refboard` URL. Supports both legacy package folders and
    /// the new single-file ZIP container.
    /// - Parameters:
    ///   - url: Source file URL (likely a security-scoped resource when coming from `.onOpenURL`).
    ///   - copyAssetsToAppSupport: When `true`, copy any referenced assets into Application Support.
    /// - Returns: An array of `CMCanvasElement` decoded from the package's `manifest.json`. The array may be empty if the manifest contains no elements.
    static func importElements(from url: URL, copyAssetsToAppSupport: Bool) throws -> [CMCanvasElement] {
        guard url.pathExtension.lowercased() == "refboard" else {
            throw ImportError.unsupportedFileExtension
        }

        let signposter = OSSignposter.archiver
        let signpostID = signposter.makeSignpostID()
        let intervalState = signposter.beginInterval("import", id: signpostID, "provider: \(fileProviderDescription(for: url))")
        defer { signposter.endInterval("import", intervalState) }

        let accessGranted = url.startAccessingSecurityScopedResource()
        defer { if accessGranted { url.stopAccessingSecurityScopedResource() } }

        // Check if it's a directory package or a single-file ZIP
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else {
            throw ImportError.corruptedFile(failingEntryPath: nil)
        }
        if isDir.boolValue {
            return try importFromPackage(url: url, copyAssetsToAppSupport: copyAssetsToAppSupport)
        }
        return try importFromZip(url: url, copyAssetsToAppSupport: copyAssetsToAppSupport)
    }

    private static func importFromZip(url: URL, copyAssetsToAppSupport: Bool) throws -> [CMCanvasElement] {
        let fm = FileManager.default
        let tempDir = fm.temporaryDirectory
            .appendingPathComponent("RefboardImport-\(UUID().uuidString)", isDirectory: true)
        try? fm.removeItem(at: tempDir)
        try fm.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tempDir) }

        try unzipItem(at: url, to: tempDir)

        let manifestAtRoot = tempDir.appendingPathComponent("manifest.json")
        let packageURL: URL
        if fm.fileExists(atPath: manifestAtRoot.path) {
            packageURL = tempDir
        } else if let firstDir = firstDirectory(in: tempDir) {
            packageURL = firstDir
        } else {
            throw ImportError.corruptedFile(failingEntryPath: nil)
        }

        return try importFromPackage(url: packageURL, copyAssetsToAppSupport: copyAssetsToAppSupport)
    }

    private static func importFromPackage(url: URL, copyAssetsToAppSupport: Bool) throws -> [CMCanvasElement] {
        // Ensure it's a directory package
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue else {
            throw ImportError.corruptedFile(failingEntryPath: nil)
        }

        // Load and decode the manifest
        let manifestURL = url.appendingPathComponent("manifest.json")
        let data = try Data(contentsOf: manifestURL)
        let manifest = try JSONDecoder().decode(BoardManifest.self, from: data)

        let fm = FileManager.default
        var results: [CMCanvasElement] = []

        // Destination for copied assets (if requested)
        let importedDir: URL? = {
            guard copyAssetsToAppSupport else { return nil }
            let appSupport = try? fm.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            let dir = appSupport?.appendingPathComponent("ImportedBoards", isDirectory: true)
            if let dir { try? fm.createDirectory(at: dir, withIntermediateDirectories: true) }
            return dir
        }()

        for m in manifest.elements {
            switch m.payload {
            case .image(let relativePath, let size):
                guard let assetInPackage = safeAssetURL(packageURL: url, relativePath: relativePath) else {
                    continue
                }
                let finalURL: URL
                if let importedDir {
                    let ext = assetInPackage.pathExtension.isEmpty ? "dat" : assetInPackage.pathExtension
                    let dest = importedDir.appendingPathComponent(m.header.id.uuidString).appendingPathExtension(ext)
                    // Prefer direct copy; fall back to Data read/write
                    do {
                        try? fm.removeItem(at: dest)
                        try fm.copyItem(at: assetInPackage, to: dest)
                        finalURL = dest
                    } catch {
                        if let data = try? Data(contentsOf: assetInPackage) {
                            try data.write(to: dest, options: [.atomic])
                            finalURL = dest
                        } else {
                            // Skip if asset can't be copied
                            continue
                        }
                    }
                } else {
                    finalURL = assetInPackage
                }
                let element = CMCanvasElement(header: m.header, payload: .image(url: finalURL, size: size))
                results.append(element)
            }
        }
        return results
    }

    private static func safeAssetURL(packageURL: URL, relativePath: String) -> URL? {
        guard !relativePath.isEmpty else { return nil }
        if relativePath.hasPrefix("/") { return nil }
        if relativePath.contains(":") { return nil }
        let components = relativePath.split(separator: "/")
        if components.contains("..") { return nil }
        guard components.first == "assets" else { return nil }

        let assetsRoot = packageURL.appendingPathComponent("assets", isDirectory: true).resolvingSymlinksInPath()
        let candidate = packageURL.appendingPathComponent(relativePath).resolvingSymlinksInPath()
        let rootPath = assetsRoot.path.hasSuffix("/") ? assetsRoot.path : assetsRoot.path + "/"
        if !candidate.path.hasPrefix(rootPath) { return nil }
        return candidate
    }
    
    /// Export elements to a single-file `.refboard` ZIP at the given destination URL.
    ///
    /// Mutates the archive in place when the destination already exists: only assets for
    /// newly-added element UUIDs are written, removed elements' assets are dropped, and the
    /// manifest is rewritten. Unchanged asset bytes are never re-read, re-compressed, or
    /// re-written — the common "move/resize/add-one-image" autosave is near-free even on
    /// boards with hundreds of assets.
    ///
    /// Image assets use `.none` compression (already compressed; deflate is pure CPU waste).
    /// The manifest itself uses deflate since it's small JSON.
    ///
    /// `nonisolated` so autosave can run this on a utility-priority detached task without
    /// hopping to the main actor.
    nonisolated static func export(elements: [CMCanvasElement], to destination: URL) throws -> URL {
        let signposter = OSSignposter.archiver
        let signpostID = signposter.makeSignpostID()
        let intervalState = signposter.beginInterval("export", id: signpostID, "provider: \(fileProviderDescription(for: destination)), elements: \(elements.count)")
        defer { signposter.endInterval("export", intervalState) }

        let fm = FileManager.default
        try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)

        let destinationExisted = fm.fileExists(atPath: destination.path)
        let accessMode: Archive.AccessMode = destinationExisted ? .update : .create
        let archive: Archive
        if let opened = Archive(url: destination, accessMode: accessMode) {
            archive = opened
        } else if destinationExisted {
            // `.update` failed — file is corrupted (likely from a prior crash). Delete is
            // throwing so permission/lock errors surface instead of triggering infinite
            // recursion. One-shot retry as `.create`; bail if that still fails.
            try fm.removeItem(at: destination)
            guard let fresh = Archive(url: destination, accessMode: .create) else {
                throw ImportError.ioFailure(underlying: nil)
            }
            archive = fresh
        } else {
            throw ImportError.ioFailure(underlying: nil)
        }

        // Compute the desired state: manifest elements + set of asset paths that should exist.
        var manifestElements: [ManifestElement] = []
        manifestElements.reserveCapacity(elements.count)
        var desiredAssetPaths: Set<String> = []
        var plannedCopies: [(entryPath: String, sourceURL: URL)] = []

        for el in elements {
            switch el.payload {
            case .image(let url, let size):
                let ext = url.pathExtension.isEmpty ? "png" : url.pathExtension
                let assetPath = "assets/\(el.id.uuidString).\(ext)"
                desiredAssetPaths.insert(assetPath)
                if archive[assetPath] == nil {
                    plannedCopies.append((assetPath, url))
                }
                manifestElements.append(
                    ManifestElement(header: el.header, payload: .image(relativePath: assetPath, size: size))
                )
            default:
                continue
            }
        }

        // Remove asset entries no longer referenced. Collect first — `archive.remove` mutates
        // the central directory and iterating it while removing is undefined.
        let orphanedAssets = archive.filter { entry in
            entry.path.hasPrefix("assets/") && !desiredAssetPaths.contains(entry.path)
        }
        for entry in orphanedAssets {
            try archive.remove(entry)
        }

        // Add new asset entries. Use `.none` — the image bytes are already compressed.
        for copy in plannedCopies {
            try archive.addEntry(with: copy.entryPath, fileURL: copy.sourceURL, compressionMethod: .none)
        }

        // Rewrite the manifest entry.
        if let existing = archive["manifest.json"] {
            try archive.remove(existing)
        }
        let manifestData = try JSONEncoder().encode(BoardManifest(version: 1, elements: manifestElements))
        try archive.addEntry(
            with: "manifest.json",
            type: .file,
            uncompressedSize: Int64(manifestData.count),
            compressionMethod: .deflate,
            provider: { position, size in
                let start = Int(position)
                let end = min(manifestData.count, start + Int(size))
                return manifestData.subdata(in: start..<end)
            }
        )

        return destination
    }

    private static func unzipItem(at sourceURL: URL, to destinationURL: URL) throws {
        guard let archive = Archive(url: sourceURL, accessMode: .read) else {
            let probe = probeZipTail(sourceURL)
            Logger.archiver.error("Archive open failed for \(sourceURL.lastPathComponent, privacy: .public). \(probe, privacy: .public)")
            throw ImportError.ioFailure(underlying: nil)
        }

        let fm = FileManager.default
        let destinationRoot = destinationURL.standardizedFileURL
        for entry in archive {
            guard let destURL = sanitizedArchiveEntryURL(entry.path, destinationRoot: destinationRoot) else {
                throw ImportError.corruptedFile(failingEntryPath: entry.path)
            }
            if entry.type == .directory {
                try fm.createDirectory(at: destURL, withIntermediateDirectories: true)
                continue
            }
            if entry.type != .file {
                throw ImportError.corruptedFile(failingEntryPath: entry.path)
            }
            try fm.createDirectory(at: destURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            _ = try archive.extract(entry, to: destURL)
        }
    }

    /// Distinguishes "killed mid-write" (no End-of-Central-Directory signature in the
    /// trailing bytes) from "structurally valid but unreadable" so log lines can point
    /// at the right cause.
    private static func probeZipTail(_ url: URL) -> String {
        let fm = FileManager.default
        guard let attrs = try? fm.attributesOfItem(atPath: url.path),
              let size = attrs[.size] as? UInt64 else {
            return "ZIP probe: cannot stat file"
        }
        guard size > 0 else { return "ZIP probe: empty file" }
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            return "ZIP probe: cannot open (size=\(size))"
        }
        defer { try? handle.close() }
        let probeSize: UInt64 = min(64 * 1024, size)
        do {
            try handle.seek(toOffset: size - probeSize)
        } catch {
            return "ZIP probe: cannot seek (size=\(size))"
        }
        guard let tail = try? handle.read(upToCount: Int(probeSize)) else {
            return "ZIP probe: cannot read (size=\(size))"
        }
        // EOCD signature: 0x06054b50 little-endian == PK\x05\x06
        let eocdSignature = Data([0x50, 0x4b, 0x05, 0x06])
        if tail.range(of: eocdSignature) != nil {
            return "ZIP probe: EOCD found (size=\(size)) — file structurally valid but couldn't open"
        }
        return "ZIP probe: NO EOCD found (size=\(size)) — file likely truncated mid-write"
    }

    private static func sanitizedArchiveEntryURL(_ entryPath: String, destinationRoot: URL) -> URL? {
        guard !entryPath.isEmpty else { return nil }
        guard !entryPath.hasPrefix("/") else { return nil }
        guard !entryPath.contains("\\") else { return nil }

        let candidate = destinationRoot.appendingPathComponent(entryPath).standardizedFileURL
        let rootPath = destinationRoot.path.hasSuffix("/") ? destinationRoot.path : destinationRoot.path + "/"
        guard candidate.path.hasPrefix(rootPath) else { return nil }
        return candidate
    }

    private static func firstDirectory(in folder: URL) -> URL? {
        let fm = FileManager.default
        let contents = try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])
        return contents?.first(where: { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true })
    }

    // MARK: - Package Manifest Types

    private struct BoardManifest: Codable {
        var version: Int
        var elements: [ManifestElement]
    }

    private struct ManifestElement: Codable {
        var header: CMElementHeader
        var payload: ManifestPayload
    }

    private enum ManifestPayload: Codable {
        case image(relativePath: String, size: SIMD2<Double>)

        private enum CodingKeys: String, CodingKey { case type, relativePath, size }
        private enum PayloadType: String, Codable { case image }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            let type = try container.decode(PayloadType.self, forKey: .type)
            switch type {
            case .image:
                let path = try container.decode(String.self, forKey: .relativePath)
                let size = try container.decode(SIMD2<Double>.self, forKey: .size)
                self = .image(relativePath: path, size: size)
            }
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            switch self {
            case .image(let path, let size):
                try container.encode(PayloadType.image, forKey: .type)
                try container.encode(path, forKey: .relativePath)
                try container.encode(size, forKey: .size)
            }
        }
    }

    enum ImportError: LocalizedError {
        case unsupportedFileExtension
        case corruptedFile(failingEntryPath: String?)
        case ioFailure(underlying: Error?)

        /// Plain-language; surfaces in user-facing alerts.
        var errorDescription: String? {
            switch self {
            case .unsupportedFileExtension:
                return "Only .refboard files can be opened."
            case .corruptedFile:
                return "This board file is incomplete or damaged. It may have been interrupted while saving."
            case .ioFailure:
                return "The board file couldn't be accessed. Check that it's available and try again."
            }
        }

        /// Developer detail for logs — not shown in the alert text.
        var failureReason: String? {
            switch self {
            case .unsupportedFileExtension:
                return nil
            case .corruptedFile(let path):
                return path.map { "Bad ZIP entry path: \($0)" }
            case .ioFailure(let underlying):
                return underlying.map { "Underlying error: \($0.localizedDescription)" }
            }
        }
    }
}

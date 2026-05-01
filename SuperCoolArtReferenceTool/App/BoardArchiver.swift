//
//  BoardArchiver.swift
//  SuperCoolArtReferenceTool
//
//  Created by Xcode Assistant on 3/26/26.
//

import Foundation
import ZIPFoundation
import simd

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

        let accessGranted = url.startAccessingSecurityScopedResource()
        defer { if accessGranted { url.stopAccessingSecurityScopedResource() } }

        // Check if it's a directory package or a single-file ZIP
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else {
            throw ImportError.corruptedFile
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
            throw ImportError.corruptedFile
        }

        return try importFromPackage(url: packageURL, copyAssetsToAppSupport: copyAssetsToAppSupport)
    }

    private static func importFromPackage(url: URL, copyAssetsToAppSupport: Bool) throws -> [CMCanvasElement] {
        // Ensure it's a directory package
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue else {
            throw ImportError.corruptedFile
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
            case .text(let content, let fontName, let fontSize, let color, let wrapWidth):
                // Text payloads round-trip directly — no asset file to
                // resolve, just rebuild the CMCanvasElement.
                let element = CMCanvasElement(
                    header: m.header,
                    payload: .text(
                        content: content, fontName: fontName,
                        fontSize: fontSize, color: color, wrapWidth: wrapWidth
                    )
                )
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
                throw ImportError.ioFailure
            }
            archive = fresh
        } else {
            throw ImportError.ioFailure
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
            case .text(let content, let fontName, let fontSize, let color, let wrapWidth):
                // Text payload has no asset file — the content lives
                // entirely in the manifest. Just record it.
                manifestElements.append(
                    ManifestElement(
                        header: el.header,
                        payload: .text(
                            content: content, fontName: fontName,
                            fontSize: fontSize, color: color, wrapWidth: wrapWidth
                        )
                    )
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
            throw ImportError.ioFailure
        }

        let fm = FileManager.default
        let destinationRoot = destinationURL.standardizedFileURL
        for entry in archive {
            guard let destURL = sanitizedArchiveEntryURL(entry.path, destinationRoot: destinationRoot) else {
                throw ImportError.corruptedFile
            }
            if entry.type == .directory {
                try fm.createDirectory(at: destURL, withIntermediateDirectories: true)
                continue
            }
            if entry.type != .file {
                throw ImportError.corruptedFile
            }
            try fm.createDirectory(at: destURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            _ = try archive.extract(entry, to: destURL)
        }
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
        /// Text payload mirrors `CMCanvasElementPayload.text` 1:1 so the
        /// manifest round-trip is lossless. No asset file lives in the
        /// archive for text — content is fully captured in the manifest.
        /// `wrapWidth` is optional and uses `decodeIfPresent` /
        /// `encodeIfPresent` for forward-compat with files written before
        /// the wrap-width field existed.
        case text(content: String, fontName: String, fontSize: Double, color: String, wrapWidth: Double?)

        private enum CodingKeys: String, CodingKey {
            case type
            // image
            case relativePath, size
            // text
            case content, fontName, fontSize, color, wrapWidth
        }
        private enum PayloadType: String, Codable { case image, text }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            let type = try container.decode(PayloadType.self, forKey: .type)
            switch type {
            case .image:
                let path = try container.decode(String.self, forKey: .relativePath)
                let size = try container.decode(SIMD2<Double>.self, forKey: .size)
                self = .image(relativePath: path, size: size)
            case .text:
                let content = try container.decode(String.self, forKey: .content)
                let fontName = try container.decode(String.self, forKey: .fontName)
                let fontSize = try container.decode(Double.self, forKey: .fontSize)
                let color = try container.decode(String.self, forKey: .color)
                let wrapWidth = try container.decodeIfPresent(Double.self, forKey: .wrapWidth)
                self = .text(content: content, fontName: fontName, fontSize: fontSize, color: color, wrapWidth: wrapWidth)
            }
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            switch self {
            case .image(let path, let size):
                try container.encode(PayloadType.image, forKey: .type)
                try container.encode(path, forKey: .relativePath)
                try container.encode(size, forKey: .size)
            case .text(let content, let fontName, let fontSize, let color, let wrapWidth):
                try container.encode(PayloadType.text, forKey: .type)
                try container.encode(content, forKey: .content)
                try container.encode(fontName, forKey: .fontName)
                try container.encode(fontSize, forKey: .fontSize)
                try container.encode(color, forKey: .color)
                try container.encodeIfPresent(wrapWidth, forKey: .wrapWidth)
            }
        }
    }

    enum ImportError: Error {
        case unsupportedFileExtension
        case corruptedFile
        case ioFailure
    }
}

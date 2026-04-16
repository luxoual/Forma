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
            case .text(let content, let fontName, let fontSize, let color):
                let element = CMCanvasElement(
                    header: m.header,
                    payload: .text(content: content, fontName: fontName, fontSize: fontSize, color: color)
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
    /// Returns the final URL written (which may be adjusted if needed).
    static func export(elements: [CMCanvasElement], to destination: URL) throws -> URL {
        let fm = FileManager.default

        // Create a temporary package directory
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("refboard")
        try? fm.removeItem(at: temp)
        try fm.createDirectory(at: temp, withIntermediateDirectories: true)
        let assetsDir = temp.appendingPathComponent("assets", isDirectory: true)
        try fm.createDirectory(at: assetsDir, withIntermediateDirectories: true)

        var manifestElements: [ManifestElement] = []

        for el in elements {
            switch el.payload {
            case .image(let url, let size):
                let ext = url.pathExtension.isEmpty ? "png" : url.pathExtension
                let assetName = "\(el.id.uuidString).\(ext)"
                let destAssetURL = assetsDir.appendingPathComponent(assetName)
                // Prefer direct copy; fall back to Data read/write
                do {
                    try? fm.removeItem(at: destAssetURL)
                    try fm.copyItem(at: url, to: destAssetURL)
                } catch {
                    if let data = try? Data(contentsOf: url) {
                        try data.write(to: destAssetURL, options: [.atomic])
                    } else {
                        // Skip this element if asset can't be written
                        continue
                    }
                }
                let payload = ManifestPayload.image(relativePath: "assets/\(assetName)", size: size)
                manifestElements.append(ManifestElement(header: el.header, payload: payload))
            case .text(let content, let fontName, let fontSize, let color):
                let payload = ManifestPayload.text(
                    content: content,
                    fontName: fontName,
                    fontSize: fontSize,
                    color: color
                )
                manifestElements.append(ManifestElement(header: el.header, payload: payload))
            default:
                continue
            }
        }

        // Write manifest.json
        let manifest = BoardManifest(version: 1, elements: manifestElements)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let manifestData = try encoder.encode(manifest)
        try manifestData.write(to: temp.appendingPathComponent("manifest.json"), options: [.atomic])

        // Zip the package into the destination file
        try? fm.removeItem(at: destination)
        try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try zipItem(at: temp, to: destination)
        try? fm.removeItem(at: temp)
        return destination
    }

    private static func zipItem(at sourceURL: URL, to destinationURL: URL) throws {
        guard let archive = Archive(url: destinationURL, accessMode: .create) else {
            throw ImportError.ioFailure
        }

        let fm = FileManager.default
        let sourceRoot = sourceURL.standardizedFileURL
        let sourceRootPath = sourceRoot.path.hasSuffix("/") ? sourceRoot.path : sourceRoot.path + "/"
        let enumerator = fm.enumerator(at: sourceURL, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])
        while let item = enumerator?.nextObject() as? URL {
            let values = try item.resourceValues(forKeys: [.isDirectoryKey])
            if values.isDirectory == true {
                continue
            }
            let itemPath = item.standardizedFileURL.path
            guard itemPath.hasPrefix(sourceRootPath) else {
                throw ImportError.ioFailure
            }
            let relativePath = String(itemPath.dropFirst(sourceRootPath.count))
            try archive.addEntry(with: relativePath, fileURL: item, compressionMethod: .deflate)
        }
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
        case text(content: String, fontName: String, fontSize: Double, color: String)

        private enum CodingKeys: String, CodingKey { case type, relativePath, size, content, fontName, fontSize, color }
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
                self = .text(content: content, fontName: fontName, fontSize: fontSize, color: color)
            }
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            switch self {
            case .image(let path, let size):
                try container.encode(PayloadType.image, forKey: .type)
                try container.encode(path, forKey: .relativePath)
                try container.encode(size, forKey: .size)
            case .text(let content, let fontName, let fontSize, let color):
                try container.encode(PayloadType.text, forKey: .type)
                try container.encode(content, forKey: .content)
                try container.encode(fontName, forKey: .fontName)
                try container.encode(fontSize, forKey: .fontSize)
                try container.encode(color, forKey: .color)
            }
        }
    }

    enum ImportError: Error {
        case unsupportedFileExtension
        case corruptedFile
        case ioFailure
    }
}

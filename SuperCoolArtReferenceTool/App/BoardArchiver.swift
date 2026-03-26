//
//  BoardArchiver.swift
//  SuperCoolArtReferenceTool
//
//  Created by Xcode Assistant on 3/26/26.
//

import Foundation
import simd

/// Handles importing/exporting reference board data.
/// This is a minimal stub to satisfy compilation for `.importElements(from:copyAssetsToAppSupport:)`.
/// Implement real parsing logic as needed.
enum BoardArchiver {
    /// Import elements from a `.refboard` file URL.
    /// - Parameters:
    ///   - url: Source file URL (likely a security-scoped resource when coming from `.onOpenURL`).
    ///   - copyAssetsToAppSupport: When `true`, copy any referenced assets into Application Support.
    /// - Returns: An array of `CMCanvasElement` parsed from the file. Currently returns an empty array.
    static func importElements(from url: URL, copyAssetsToAppSupport: Bool) throws -> [CMCanvasElement] {
        guard url.pathExtension.lowercased() == "refboard" else {
            throw ImportError.unsupportedFileExtension
        }

        // Ensure it's a directory package and begin security-scoped access if needed
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue else {
            throw ImportError.corruptedFile
        }
        let accessGranted = url.startAccessingSecurityScopedResource()
        defer { if accessGranted { url.stopAccessingSecurityScopedResource() } }

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
                let assetInPackage = url.appendingPathComponent(relativePath)
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
    
    /// Export elements to a `.refboard` package at the given destination URL.
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
            default:
                // Skip non-image payloads for this MVP
                continue
            }
        }

        // Write manifest.json
        let manifest = BoardManifest(version: 1, elements: manifestElements)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let manifestData = try encoder.encode(manifest)
        try manifestData.write(to: temp.appendingPathComponent("manifest.json"), options: [.atomic])

        // Replace destination with the temp package
        try? fm.removeItem(at: destination)
        try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.moveItem(at: temp, to: destination)
        return destination
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

    enum ImportError: Error {
        case unsupportedFileExtension
        case corruptedFile
        case ioFailure
    }
}


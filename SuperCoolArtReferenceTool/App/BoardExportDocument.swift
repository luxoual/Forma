import Foundation
import SwiftUI
import UniformTypeIdentifiers

struct BoardExportDocument: FileDocument {
    // Export-only for now; do not advertise readability.
    static var readableContentTypes: [UTType] { [] }
    static var writableContentTypes: [UTType] { [.refboard] }

    let elements: [CMCanvasElement]
    /// Name the save sheet suggests, without the `.refboard` extension.
    let filename: String

    /// Starting name for a new board, before any "(1)", "(2)" suffix.
    static let newBoardName = "New Board"

    init(elements: [CMCanvasElement], filename: String = BoardExportDocument.newBoardName) {
        self.elements = elements
        self.filename = filename
    }

    init(configuration: ReadConfiguration) throws {
        throw NSError(domain: "BoardExportDocument", code: 0, userInfo: [NSLocalizedDescriptionKey: "Read not supported"])
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        let fm = FileManager.default
        // The save sheet suggests whatever name the temp file has, so the
        // temp file is named after the board itself. A fresh UUID folder
        // around it keeps two exports from colliding.
        let tempDir = fm.temporaryDirectory
            .appendingPathComponent("BoardExport-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: tempDir, withIntermediateDirectories: true)
        // The wrapper reads the bytes into memory, so the folder can go as
        // soon as we return, and also if the export throws partway.
        defer { try? fm.removeItem(at: tempDir) }
        let temp = tempDir
            .appendingPathComponent(filename)
            .appendingPathExtension("refboard")

        try? fm.removeItem(at: temp)
        // Fresh exports have no color preferences yet — write `nil` for both
        // so the manifest omits the fields. On first open the canvas falls
        // back to `ContentView.defaultCanvasColor`, and new text to whichever of
        // near-black / white that background can show.
        let packageURL = try BoardArchiver.export(
            elements: elements,
            canvasColorHex: nil,
            lastTextColorHex: nil,
            to: temp
        )
        return try FileWrapper(url: packageURL, options: .immediate)
    }
}

extension UTType {
    static let refboard =
        UTType(filenameExtension: "refboard", conformingTo: .data)
        ?? UTType(exportedAs: "AxI.SuperCoolArtReferenceTool.refboard", conformingTo: .data)
}

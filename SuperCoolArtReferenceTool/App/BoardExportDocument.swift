import Foundation
import UniformTypeIdentifiers

struct BoardExportDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.refboard] }
    static var writableContentTypes: [UTType] { [.refboard] }

    let elements: [CMCanvasElement]

    init(elements: [CMCanvasElement]) {
        self.elements = elements
    }

    init(configuration: ReadConfiguration) throws {
        throw NSError(domain: "BoardExportDocument", code: 0, userInfo: [NSLocalizedDescriptionKey: "Read not supported"])
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        let fm = FileManager.default
        let temp = fm.temporaryDirectory
            .appendingPathComponent("BoardExport-\(UUID().uuidString)")
            .appendingPathExtension("refboard")

        try? fm.removeItem(at: temp)
        let packageURL = try BoardArchiver.export(elements: elements, to: temp)
        let wrapper = try FileWrapper(url: packageURL, options: .immediate)
        wrapper.preferredFilename = "Board.refboard"
        try? fm.removeItem(at: packageURL)
        return wrapper
    }
}

extension UTType {
    static let refboard = UTType(filenameExtension: "refboard")!
}

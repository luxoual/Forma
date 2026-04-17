import Foundation

struct RecentBoardEntry: Codable, Identifiable {
    var id: String { name + lastOpened.timeIntervalSince1970.description }
    let name: String
    let bookmarkData: Data
    var lastOpened: Date

    func resolveURL() -> URL? {
        var isStale = false
        guard let url = try? URL(
            resolvingBookmarkData: bookmarkData,
            bookmarkDataIsStale: &isStale
        ) else { return nil }
        return url
    }
}

@Observable
@MainActor
final class RecentBoardsManager {
    private(set) var entries: [RecentBoardEntry] = []

    private let maxStored = 10
    private let storageURL = URL.applicationSupportDirectory.appending(path: "recent_boards.json")

    init() {
        load()
        pruneInvalid()
    }

    func validEntries(limit: Int = 3) -> [RecentBoardEntry] {
        Array(entries.prefix(limit))
    }

    func record(url: URL) {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }

        guard let bookmark = try? url.bookmarkData(
            options: [],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        ) else { return }

        let name = url.deletingPathExtension().lastPathComponent

        if let idx = entries.firstIndex(where: { $0.name == name && $0.resolveURL() == url }) {
            entries[idx].lastOpened = .now
        } else {
            entries.insert(
                RecentBoardEntry(name: name, bookmarkData: bookmark, lastOpened: .now),
                at: 0
            )
        }
        entries.sort { $0.lastOpened > $1.lastOpened }
        if entries.count > maxStored {
            entries = Array(entries.prefix(maxStored))
        }
        save()
    }

    private func load() {
        guard FileManager.default.fileExists(atPath: storageURL.path) else { return }
        do {
            let data = try Data(contentsOf: storageURL)
            entries = try JSONDecoder().decode([RecentBoardEntry].self, from: data)
            entries.sort { $0.lastOpened > $1.lastOpened }
        } catch {
            print("[RecentBoards] Failed to load: \(error.localizedDescription)")
            entries = []
        }
    }

    private func save() {
        do {
            let data = try JSONEncoder().encode(entries)
            let dir = storageURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try data.write(to: storageURL, options: .atomic)
        } catch {
            print("[RecentBoards] Failed to save: \(error.localizedDescription)")
        }
    }

    private func pruneInvalid() {
        let before = entries.count
        entries.removeAll { $0.resolveURL() == nil }
        if entries.count != before {
            save()
        }
    }
}

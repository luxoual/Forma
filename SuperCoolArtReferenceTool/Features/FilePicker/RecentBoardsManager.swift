import Foundation

struct RecentBoardEntry: Codable, Identifiable {
    var id: String { filePath }
    let name: String
    let filePath: String
    var bookmarkData: Data
    var lastOpened: Date

    /// Resolves the bookmark to a URL. If the bookmark is stale, returns a refreshed `Data` blob
    /// that the caller is responsible for persisting back to storage. Returns `nil` if the
    /// bookmark can't be resolved or the file no longer exists on disk.
    func resolveURL() -> (url: URL, refreshedBookmark: Data?)? {
        var isStale = false
        guard let url = try? URL(
            resolvingBookmarkData: bookmarkData,
            bookmarkDataIsStale: &isStale
        ) else { return nil }

        // iCloud "delete" moves the file into a hidden `.Trash` folder, and security-scoped
        // bookmarks follow it. Treat trashed files as deleted so stale entries get pruned.
        if url.path.contains("/.Trash/") { return nil }

        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        guard (try? url.checkResourceIsReachable()) == true else { return nil }

        guard isStale else { return (url, nil) }
        let fresh = try? url.bookmarkData(
            options: .suitableForBookmarkFile,
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
        return (url, fresh)
    }
}

@Observable
@MainActor
final class RecentBoardsManager {
    private(set) var entries: [RecentBoardEntry] = []

    private let maxStored = 10
    private let storageURL = URL.applicationSupportDirectory.appending(path: "recent_boards.json")

    init() {
        entries = Self.loadFromDisk(url: storageURL)
        pruneInvalid()
    }

    func validEntries(limit: Int = 5) -> [RecentBoardEntry] {
        Array(entries.prefix(limit))
    }

    func record(url: URL) {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }

        let path = url.standardizedFileURL.path
        // Never record files that live in iCloud's trash.
        if path.contains("/.Trash/") { return }

        guard let bookmark = try? url.bookmarkData(
            options: .suitableForBookmarkFile,
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        ) else { return }

        let name = url.deletingPathExtension().lastPathComponent

        if let idx = entries.firstIndex(where: { $0.filePath == path }) {
            entries[idx] = RecentBoardEntry(
                name: name,
                filePath: path,
                bookmarkData: bookmark,
                lastOpened: .now
            )
        } else {
            entries.insert(
                RecentBoardEntry(name: name, filePath: path, bookmarkData: bookmark, lastOpened: .now),
                at: 0
            )
        }
        entries.sort { $0.lastOpened > $1.lastOpened }
        if entries.count > maxStored {
            entries = Array(entries.prefix(maxStored))
        }

        let snapshot = entries
        let saveURL = storageURL
        Task.detached { Self.saveToDisk(snapshot, url: saveURL) }
    }

    private func pruneInvalid() {
        var didChange = false
        entries = entries.compactMap { entry in
            guard let resolved = entry.resolveURL() else {
                didChange = true
                return nil
            }
            if let refreshed = resolved.refreshedBookmark {
                didChange = true
                var updated = entry
                updated.bookmarkData = refreshed
                return updated
            }
            return entry
        }
        if didChange {
            let snapshot = entries
            let saveURL = storageURL
            Task.detached { Self.saveToDisk(snapshot, url: saveURL) }
        }
    }

    private nonisolated static func loadFromDisk(url: URL) -> [RecentBoardEntry] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        do {
            let data = try Data(contentsOf: url)
            var entries = try JSONDecoder().decode([RecentBoardEntry].self, from: data)
            entries.sort { $0.lastOpened > $1.lastOpened }
            return entries
        } catch {
            print("[RecentBoards] Failed to load: \(error.localizedDescription)")
            return []
        }
    }

    private nonisolated static func saveToDisk(_ entries: [RecentBoardEntry], url: URL) {
        do {
            let data = try JSONEncoder().encode(entries)
            let dir = url.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
        } catch {
            print("[RecentBoards] Failed to save: \(error.localizedDescription)")
        }
    }
}

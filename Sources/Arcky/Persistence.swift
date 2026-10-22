import Foundation

/// Everything saved between launches (Arc keeps the equivalent in StorableSidebar.json).
struct PersistedState: Codable {
    var spaces: [Space]
    /// The default profile's favorites; the only favorites before profiles existed.
    var favorites: [BrowserTab]
    var profiles: [Profile]?
    var favoritesByProfile: [UUID: [BrowserTab]]?
    var boosts: [Boost]?
    var activeSpaceID: UUID
    var selectedTabBySpace: [UUID: UUID]
    var archive: [HistoryEntry]
    var history: [HistoryEntry]
    var autoArchive: AutoArchiveInterval?
    var splits: [TabSplit]?
}

enum Persistence {
    static var fileURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appending(path: "Arcky/state.json")
    }

    static func load() -> PersistedState? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        do {
            return try JSONDecoder().decode(PersistedState.self, from: data)
        } catch {
            NSLog("Arcky: could not read saved state: \(error)")
            return nil
        }
    }

    static func save(_ state: PersistedState) {
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(state).write(to: fileURL, options: .atomic)
        } catch {
            NSLog("Arcky: could not save state: \(error)")
        }
    }
}

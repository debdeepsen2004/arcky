import AppKit
import Foundation
import Observation

// Sync between Macs through a shared folder (iCloud Drive by default).
//
// Each Mac writes only its own file, `devices/<deviceID>.json`, holding a snapshot of what
// syncs: spaces with their pinned items, favorites, profiles, Boosts, Notes and Easels.
// Today tabs stay on each Mac, as in Arc. To merge, a Mac compares every other Mac's
// snapshot with the version it saw last time and applies what changed (additions, edits,
// deletions). A local edit that hasn't been published yet wins over a remote one.
// Notes and Easels merge by their modified date; Easel images are copied both ways.

// MARK: - Snapshot model

/// A pinned tab as synced: where it lives, not where it has been browsed to.
struct SyncTab: Codable, Hashable {
    var id: UUID
    var url: URL?
    var title: String
    var customTitle: String?

    // Page titles change as you browse, so they don't count as edits.
    static func == (a: SyncTab, b: SyncTab) -> Bool {
        a.id == b.id && a.url == b.url && a.customTitle == b.customTitle
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
        hasher.combine(url)
        hasher.combine(customTitle)
    }
}

struct SyncFolder: Codable, Hashable {
    var id: UUID
    var name: String
    var live: LiveSource?
    /// Empty for live folders: each Mac fetches their items itself.
    var children: [SyncNode]
}

indirect enum SyncNode: Codable, Hashable {
    case tab(SyncTab)
    case folder(SyncFolder)
}

struct SyncSpace: Codable, Hashable {
    var id: UUID
    var name: String
    var emoji: String
    var hue: Double
    var style: SpaceStyle?
    var profileID: UUID?
    var pinned: [SyncNode]
}

struct SyncSnapshot: Codable {
    var deviceID: String
    var deviceName: String
    var date: Date
    var spaceOrder: [UUID]
    var spaces: [UUID: SyncSpace]
    var favorites: [UUID: [SyncTab]]
    var profiles: [UUID: Profile]
    var boosts: [UUID: Boost]
    var notes: [UUID: Note]
    var easels: [UUID: Easel]

    /// Equal apart from who wrote it and when.
    func sameContent(as other: SyncSnapshot) -> Bool {
        spaceOrder == other.spaceOrder && spaces == other.spaces && favorites == other.favorites
            && profiles == other.profiles && boosts == other.boosts && notes == other.notes && easels == other.easels
    }
}

/// What this Mac remembers between syncs.
private struct SyncState: Codable {
    /// The last snapshot this Mac published.
    var published: SyncSnapshot?
    /// Each other Mac's snapshot as last merged.
    var lastSeen: [String: SyncSnapshot] = [:]
}

// MARK: - Engine

@MainActor @Observable
final class SyncEngine {
    static let shared = SyncEngine()

    struct Device: Identifiable {
        var id: String
        var name: String
        var date: Date
    }

    var enabled: Bool {
        didSet {
            UserDefaults.standard.set(enabled, forKey: "syncEnabled")
            if enabled { syncNow() }
        }
    }
    var folder: URL {
        didSet { UserDefaults.standard.set(folder.path(percentEncoded: false), forKey: "syncFolderPath") }
    }
    var lastSync: Date?
    var lastError: String?
    var otherDevices: [Device] = []
    var syncing = false

    @ObservationIgnored private var state = SyncState()
    @ObservationIgnored private var timer: Task<Void, Never>?
    @ObservationIgnored private var pending: Task<Void, Never>?

    let deviceID: String = {
        if let id = UserDefaults.standard.string(forKey: "syncDeviceID") { return id }
        let id = UUID().uuidString
        UserDefaults.standard.set(id, forKey: "syncDeviceID")
        return id
    }()
    let deviceName = Host.current().localizedName ?? "Mac"

    static var iCloudDriveFolder: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library/Mobile Documents/com~apple~CloudDocs/Arcky Sync")
    }

    private static var stateFile: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "Arcky/sync-state.json")
    }

    private var devicesFolder: URL { folder.appending(path: "devices") }
    private var imagesFolder: URL { folder.appending(path: "images") }

    private init() {
        enabled = UserDefaults.standard.bool(forKey: "syncEnabled")
        if let path = UserDefaults.standard.string(forKey: "syncFolderPath") {
            folder = URL(fileURLWithPath: path)
        } else {
            folder = Self.iCloudDriveFolder
        }
        if let data = try? Data(contentsOf: Self.stateFile),
           let saved = try? JSONDecoder().decode(SyncState.self, from: data) {
            state = saved
        }
    }

    func start() {
        timer = Task { [weak self] in
            while !Task.isCancelled {
                self?.syncNow()
                try? await Task.sleep(for: .seconds(30))
            }
        }
    }

    /// Syncs a few seconds after local changes settle.
    func scheduleSync() {
        guard enabled else { return }
        pending?.cancel()
        pending = Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            self?.syncNow()
        }
    }

    func syncNow() {
        guard enabled, !syncing else { return }
        syncing = true
        defer { syncing = false }
        do {
            try FileManager.default.createDirectory(at: devicesFolder, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: imagesFolder, withIntermediateDirectories: true)
            let remotes = try readRemoteSnapshots()

            var local = makeSnapshot()
            for remote in remotes {
                local = merge(remote, into: local, lastSeen: state.lastSeen[remote.deviceID])
                state.lastSeen[remote.deviceID] = remote
            }
            apply(local)
            syncImages()

            let published = makeSnapshot()
            if state.published.map({ !$0.sameContent(as: published) }) ?? true {
                try JSONEncoder().encode(published).write(to: devicesFolder.appending(path: "\(deviceID).json"), options: .atomic)
            }
            state.published = published
            saveState()

            otherDevices = remotes.map { Device(id: $0.deviceID, name: $0.deviceName, date: $0.date) }
            lastSync = Date()
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }

    private func readRemoteSnapshots() throws -> [SyncSnapshot] {
        let files = try FileManager.default.contentsOfDirectory(at: devicesFolder, includingPropertiesForKeys: nil)
        return files
            .filter { $0.pathExtension == "json" && $0.deletingPathExtension().lastPathComponent != deviceID }
            .compactMap { try? JSONDecoder().decode(SyncSnapshot.self, from: Data(contentsOf: $0)) }
            .sorted { $0.date < $1.date }
    }

    private func saveState() {
        do {
            try JSONEncoder().encode(state).write(to: Self.stateFile, options: .atomic)
        } catch {
            NSLog("Arcky: could not save sync state: \(error)")
        }
    }

    // MARK: Merging

    /// Applies what `remote` changed since `lastSeen` to `local`. Entities this Mac changed
    /// since it last published keep the local version.
    private func merge(_ remote: SyncSnapshot, into local: SyncSnapshot, lastSeen: SyncSnapshot?) -> SyncSnapshot {
        let published = state.published
        var merged = local
        merged.spaces = mergeEntities(remote.spaces, lastSeen: lastSeen?.spaces, local: local.spaces, published: published?.spaces)
        merged.favorites = mergeEntities(remote.favorites, lastSeen: lastSeen?.favorites, local: local.favorites, published: published?.favorites)
        merged.boosts = mergeEntities(remote.boosts, lastSeen: lastSeen?.boosts, local: local.boosts, published: published?.boosts)
        // Profiles are only added or renamed: deleting one erases its website data, so that
        // stays a deliberate local action.
        for (id, profile) in remote.profiles where lastSeen?.profiles[id] != profile {
            if local.profiles[id] == published?.profiles[id] || local.profiles[id] == nil {
                merged.profiles[id] = profile
            }
        }
        // A new order from the other Mac is adopted; spaces only this Mac has stay at the end.
        if remote.spaceOrder != lastSeen?.spaceOrder, local.spaceOrder == published?.spaceOrder || published == nil {
            let known = remote.spaceOrder.filter { merged.spaces[$0] != nil }
            merged.spaceOrder = known + merged.spaceOrder.filter { !known.contains($0) }
        }
        merged.spaceOrder = merged.spaceOrder.filter { merged.spaces[$0] != nil }
            + merged.spaces.keys.filter { !merged.spaceOrder.contains($0) }.sorted { $0.uuidString < $1.uuidString }
        // Documents: the newest edit wins.
        for (id, note) in remote.notes where note.modified > (merged.notes[id]?.modified ?? .distantPast) {
            merged.notes[id] = note
        }
        for (id, easel) in remote.easels where easel.modified > (merged.easels[id]?.modified ?? .distantPast) {
            merged.easels[id] = easel
        }
        return merged
    }

    /// Three-way merge of one kind of entity, keyed by ID.
    private func mergeEntities<Value: Equatable>(
        _ remote: [UUID: Value], lastSeen: [UUID: Value]?, local: [UUID: Value], published: [UUID: Value]?
    ) -> [UUID: Value] {
        var result = local
        func locallyUnchanged(_ id: UUID) -> Bool {
            // Before this Mac's first publish, anything it has is its own and stays.
            guard let published else { return local[id] == nil }
            return local[id] == published[id]
        }
        // Added or changed on the other Mac.
        for (id, value) in remote where lastSeen?[id] != value {
            if lastSeen == nil, local[id] != nil { continue } // first contact: keep both sides' own items
            if locallyUnchanged(id) || local[id] == nil { result[id] = value }
        }
        // Deleted on the other Mac.
        for id in (lastSeen ?? [:]).keys where remote[id] == nil {
            if locallyUnchanged(id) { result[id] = nil }
        }
        return result
    }

    // MARK: Snapshot ↔ store

    private func makeSnapshot() -> SyncSnapshot {
        let store = BrowserStore.shared
        let documents = DocumentStore.shared
        var spaces: [UUID: SyncSpace] = [:]
        for space in store.spaces {
            spaces[space.id] = SyncSpace(
                id: space.id, name: space.name, emoji: space.emoji, hue: space.hue, style: space.style,
                profileID: space.profileID, pinned: space.pinned.map(Self.syncNode)
            )
        }
        return SyncSnapshot(
            deviceID: deviceID,
            deviceName: deviceName,
            date: Date(),
            spaceOrder: store.spaces.map(\.id),
            spaces: spaces,
            favorites: store.favoritesByProfile.mapValues { $0.map(Self.syncTab) },
            profiles: Dictionary(uniqueKeysWithValues: store.profiles.map { ($0.id, $0) }),
            boosts: Dictionary(uniqueKeysWithValues: store.boosts.map { ($0.id, $0) }),
            notes: documents.notes,
            easels: documents.easels
        )
    }

    private static func syncTab(_ tab: BrowserTab) -> SyncTab {
        SyncTab(id: tab.id, url: tab.homeURL ?? tab.url, title: tab.title, customTitle: tab.customTitle)
    }

    private static func syncNode(_ node: SidebarNode) -> SyncNode {
        switch node {
        case .tab(let tab):
            return .tab(syncTab(tab))
        case .folder(let folder):
            return .folder(SyncFolder(id: folder.id, name: folder.name, live: folder.live,
                                      children: folder.live == nil ? folder.children.map(syncNode) : []))
        }
    }

    /// Writes merged results back into the store and document store, changing only what differs.
    private func apply(_ snapshot: SyncSnapshot) {
        let store = BrowserStore.shared
        let current = makeSnapshot()
        guard !current.sameContent(as: snapshot) else { return }

        for (id, profile) in snapshot.profiles where current.profiles[id] != profile {
            store.applySyncedProfile(profile)
        }
        for (id, space) in snapshot.spaces where current.spaces[id] != space {
            store.applySyncedSpace(space)
        }
        for id in current.spaces.keys where snapshot.spaces[id] == nil {
            store.deleteSpace(id)
        }
        if store.spaces.map(\.id) != snapshot.spaceOrder {
            store.orderSpaces(snapshot.spaceOrder)
        }
        for (profileID, tabs) in snapshot.favorites where current.favorites[profileID] != tabs {
            store.applySyncedFavorites(tabs, profileID: profileID)
        }
        if current.boosts != snapshot.boosts {
            store.applySyncedBoosts(Array(snapshot.boosts.values))
        }

        let documents = DocumentStore.shared
        for (id, note) in snapshot.notes where documents.notes[id] != note {
            documents.replaceNote(id, with: note)
            store.syncDocumentTitle(.note(id), title: note.title)
        }
        for (id, easel) in snapshot.easels where documents.easels[id] != easel {
            documents.replaceEasel(id, with: easel)
            store.syncDocumentTitle(.easel(id), title: easel.title)
        }
    }

    /// Copies Easel images the other side doesn't have yet. Image files never change once written.
    private func syncImages() {
        let fm = FileManager.default
        let local = DocumentStore.imagesFolder
        try? fm.createDirectory(at: local, withIntermediateDirectories: true)
        let localFiles = Set((try? fm.contentsOfDirectory(atPath: local.path(percentEncoded: false))) ?? [])
        let remoteFiles = Set((try? fm.contentsOfDirectory(atPath: imagesFolder.path(percentEncoded: false))) ?? [])
        for name in localFiles.subtracting(remoteFiles) where name.hasSuffix(".png") {
            try? fm.copyItem(at: local.appending(path: name), to: imagesFolder.appending(path: name))
        }
        for name in remoteFiles.subtracting(localFiles) where name.hasSuffix(".png") {
            try? fm.copyItem(at: imagesFolder.appending(path: name), to: local.appending(path: name))
        }
    }
}

// MARK: - Applying synced changes

extension BrowserStore {
    func applySyncedProfile(_ profile: Profile) {
        if let i = profiles.firstIndex(where: { $0.id == profile.id }) {
            profiles[i] = profile
        } else {
            profiles.append(profile)
            favoritesByProfile[profile.id] = favoritesByProfile[profile.id] ?? []
        }
        scheduleSave()
    }

    /// Adds or updates a space's name, look, profile and pinned items. Its Today tabs (which
    /// don't sync) and open pages are kept.
    func applySyncedSpace(_ synced: SyncSpace) {
        let existing = spaces.first { $0.id == synced.id }
        let oldTabs = Dictionary((existing?.pinned.flatMap(\.allTabs) ?? []).map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var oldFolders: [UUID: Folder] = [:]
        func collectFolders(_ nodes: [SidebarNode]) {
            for case .folder(let folder) in nodes {
                oldFolders[folder.id] = folder
                collectFolders(folder.children)
            }
        }
        collectFolders(existing?.pinned ?? [])

        func node(_ syncNode: SyncNode) -> SidebarNode {
            switch syncNode {
            case .tab(let syncTab):
                return .tab(Self.tab(from: syncTab, existing: oldTabs[syncTab.id]))
            case .folder(let syncFolder):
                var folder = oldFolders[syncFolder.id] ?? Folder(name: syncFolder.name, isOpen: true)
                folder.id = syncFolder.id
                folder.name = syncFolder.name
                folder.live = syncFolder.live
                // A live folder keeps the items this Mac fetched.
                if syncFolder.live == nil { folder.children = syncFolder.children.map(node) }
                return .folder(folder)
            }
        }

        var space = existing ?? Space(name: synced.name, emoji: synced.emoji, hue: synced.hue)
        space.id = synced.id
        space.name = synced.name
        space.emoji = synced.emoji
        space.hue = synced.hue
        space.style = synced.style
        space.profileID = synced.profileID
        space.pinned = synced.pinned.map(node)

        // Pinned tabs that went away are unloaded.
        let kept = Set(space.pinned.flatMap(\.allTabs).map(\.id))
        for id in oldTabs.keys where !kept.contains(id) {
            pool.discard(id)
            if selectedTabBySpace[synced.id] == id { selectedTabBySpace[synced.id] = nil }
        }

        if let i = spaces.firstIndex(where: { $0.id == synced.id }) {
            spaces[i] = space
        } else {
            spaces.append(space)
        }
        for folder in liveFolders where folder.children.isEmpty {
            LiveFolderService.shared.refresh(folder.id)
        }
        scheduleSave()
    }

    func orderSpaces(_ order: [UUID]) {
        spaces.sort { (order.firstIndex(of: $0.id) ?? .max) < (order.firstIndex(of: $1.id) ?? .max) }
        scheduleSave()
    }

    func applySyncedFavorites(_ synced: [SyncTab], profileID: UUID) {
        let old = Dictionary((favoritesByProfile[profileID] ?? []).map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        favoritesByProfile[profileID] = synced.map { Self.tab(from: $0, existing: old[$0.id]) }
        for id in old.keys where !synced.contains(where: { $0.id == id }) { pool.discard(id) }
        scheduleSave()
    }

    func applySyncedBoosts(_ synced: [Boost]) {
        boosts = synced.sorted { $0.domain < $1.domain }
        pool.installBoosts(boosts)
        scheduleSave()
    }

    /// A pinned tab from sync, keeping this Mac's browsing state if it already had it.
    private static func tab(from synced: SyncTab, existing: BrowserTab?) -> BrowserTab {
        var tab = existing ?? BrowserTab(url: synced.url, title: synced.title)
        tab.id = synced.id
        tab.homeURL = synced.url
        tab.customTitle = synced.customTitle
        if existing == nil { tab.url = synced.url }
        return tab
    }
}

extension DocumentStore {
    func replaceNote(_ id: UUID, with note: Note) {
        notes[id] = note
        saveNow()
    }

    func replaceEasel(_ id: UUID, with easel: Easel) {
        easels[id] = easel
        saveNow()
    }
}
